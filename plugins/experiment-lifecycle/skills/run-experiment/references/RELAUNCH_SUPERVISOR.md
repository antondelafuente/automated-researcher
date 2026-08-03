# The model-free relaunch supervisor — decision contract (substrate-neutral)

This is the **supervisor's half** of the #54 crash-resilience design (`proposals/54-crash-resilience-supervisor.md`,
child 3 — the reliable first cut). The **agent's half** — what an executor must do to *be* resumable — lives in
`SKILL.md` ("The resume contract"). The two halves meet at one record: the run-supervision record
(`scripts/run_supervision_record.sh`). This document states, in **substrate-neutral product terms**, what a
model-free relaunch supervisor does — so any instance that wires one reads from the same contract instead of
re-deriving the dangerous parts.

The supervisor is a dumb loop on an always-on host that makes **zero model calls** — that is the whole point: it
must survive the same Anthropic API outage that just killed the agent. It never asks a model "does this agent
look stuck?"; every decision below is a file read.

## What it is responsible for (and what it is NOT)

It relaunches a run whose failure is detectable **without a model and without false positives**. This first cut
covers exactly the two failure signatures that are unambiguous today:

1. **Process exit / crash the in-pane respawn loop can't catch.** An instance's in-pane loop already relaunches a
   `claude` that *exits* non-zero. The supervisor extends that to the cases the in-pane loop can't see: the whole
   session/pane gone, or the box-level wrapper itself dead.
2. **An agent-declared needs-relaunch request.** The agent (or a `StopFailure`-style hook — #54 child 4) sets a
   positive "recover me" flag on the run-supervision record for the can't-resume-in-place cases (a usage-policy
   block that ends the thread, a corrupted session). This is a *positive* model-free signal, not an inference.

It is **NOT** responsible for **silent-wedge detection** — an agent that is *alive but hung*, with no exit and no
request. A reliable model-free "the agent is healthily inside a long model turn" signal does not exist yet, and a
wrong probe restarts healthy quiet work (strictly worse than the gap). That harder half is the separate
`needs-shaping` follow-up (#54 child 5), deliberately **out of scope here** — a future reader should not mistake
"no wedge handling" for a bug to patch with a heuristic.

It is also **NOT** the pod reaper. Pod *deletion* is `gpu-job`'s domain (the pod lease + the box-level reap sweep,
#54 child 2 / B.1). This supervisor only relaunches *runs*; it reads the run-supervision record's linked
`lease_pod_ids` purely to know which pods a relaunched run owns, never to delete one.

## Supervise desired-state, not "any missing session"

The load-bearing safety rule: a session that was intentionally `/quit` or manually killed, or a run that has
*finished*, must **never** be resurrected. So the supervisor acts only on a run that is **desired-active, not
stopped, and not closed** — exactly the record's `is-desired-active` predicate. Outside that set, a gone session
is a **no-op**.

The predicate is **fail-closed**: a missing or corrupt record reads as *not* desired-active. An unknown run is
never relaunched. The agent-side contract is what makes a genuine run *appear* in this set (it writes the record
at run start); a finished/stopped run is cleared *before* the supervisor could observe its session gone (the
close-side ordering gate in `SKILL.md` Step 5), so the supervisor never races a legitimate teardown into a
resurrection.

## The decision tree

For each run the supervisor knows about (every record under the supervision root), in one model-free pass:

```
if not is-desired-active(run):            # /quit, killed, finished, unknown, or corrupt record
    skip                                  #   -> NEVER relaunch

else if session_is_alive(run):            # instance probe over the recorded session_handle
    if is-relaunch-requested(run):        #   alive but the agent asked to be recovered
        relaunch(run)                     #   (e.g. a policy block it can't itself resume past)
    else:
        skip                              #   healthy -> leave it alone

else:                                     # desired-active but the session is gone (crash/exit)
    relaunch(run)
```

`relaunch(run)` itself is — note it **clears any pending relaunch request on EVERY successful branch**, not
only the alive-but-requested call site, so a crashed run that *also* carried a `request-relaunch` can't have
that request survive its own relaunch and re-trigger on the next pass (the contract is symmetric;
`clear-relaunch` is idempotent, so on a crash relaunch that had no pending request it is a harmless no-op):

```
relaunch(run):
    acquire single-writer lock for run    # never double-relaunch; never race the in-pane loop
    if crash-storm cap for run tripped: give up (log)   # keep the in-pane loop's existing cap
    if resume_same_session(run) succeeds: clear-relaunch(run); done  # PREFERRED: resume in place
    else: launch_successor(handoff_path(run)); clear-relaunch(run)   # fresh successor at the standing handoff
    release lock
```

### resume_same_session vs launch_successor

- **`resume_same_session()` is preferred** — resume the *same* conversation in place. (An instance maps this to
  its in-place resume path; on a Claude-Code instance that is `--continue`, the path the in-pane loop already
  owns.) It recovers the full conversation, so it is the right choice whenever the session is recoverable.
- **`launch_successor(handoff_path)`** — start a *fresh* successor pointed at the standing handoff — is the
  fallback for when same-session resume is **impossible**: a corrupted session JSONL, or a usage-policy block that
  poisoned the thread. The fresh successor has only the disk, which is why the agent-side contract requires the
  standing handoff and checkpoint-to-disk to be *current at all times*, not written at the end.
- **`handoff_path` is bound explicitly** — read from the run-supervision record (`handoff_path` field) — never
  assumed to be `<workdir>/TEMP.md`. The artifact dir and the launcher's workdir need not coincide, so the path
  travels in the record, not by convention.

## The `run-id` → session binding (`session_handle`)

The supervisor needs to know *which* process/session a desired-active `run-id` corresponds to, both to probe
`session_is_alive` and to target `resume_same_session`. That binding is the record's **`session_handle`** — an
**instance-owned** value the product never parses (a tmux session name, a systemd unit, a wrapper
pid-file path — whatever the instance's launcher owns). The agent records it at run start (`create --session-handle
…`) and the supervisor reads it back (`session-handle <run-id>`). Not parsing it is what lets this contract stay
substrate-neutral while still giving the supervisor a concrete handle to act on.

**Uninterpreted is not the same as free-choice** (automated-researcher#673). Every consumer of this field —
`session_is_alive`, `session_janitor.sh`'s live-session list, `reap_session.sh`'s self-only teardown seam — compares
the recorded value against a session identity the INSTANCE derives for itself, so the handle has exactly one correct
value per session and the agent cannot verify a guess until the comparison happens (at close, when the record is
already terminal and unfixable). The product therefore derives it rather than asking: `start` binds what the
instance's own self-identity seam (`EXPERIMENT_SESSION_HANDLE_CMD`, one line, non-zero exit when the caller is not
in a session it recognizes) prints, whenever `--session-handle` is omitted. Derivation is `start`-only — a
`checkpoint` may be written by the supervisor or another peer, which cannot claim the run's identity — and an
unset/failing seam binds nothing (the pre-existing no-handle no-op), never a guessed value.

## Idempotence, single-writer, crash-storm cap

- **Single-writer kill/resume lock per run** so the supervisor never double-relaunches a run and never races the
  instance's in-pane respawn loop (which may already be handling the same exit).
- **Idempotent.** A second pass over a run already being relaunched (lock held, or a request already cleared) is a
  no-op. The needs-relaunch request is **cleared by the supervisor after it acts** (`clear-relaunch`), so one
  request is honored once — and `request-relaunch` is auto-cleared by `stop`/`close`, so a request can never
  outlive a deliberate end of the run.
- **Crash-storm cap.** Keep the in-pane loop's existing cap (e.g. give up after N relaunches within a short
  window) so a run that crashes immediately on every relaunch can't spin the supervisor forever.

## The record API the supervisor consumes

All of the above is mediated by `scripts/run_supervision_record.sh` — one product implementation owning the
atomic-write + monotonic-state + fail-closed semantics (so no consumer re-derives them):

| operation | who calls it | meaning |
|---|---|---|
| `start <run-id> [--handoff P] [--session-handle H]` (`create` compatibility name) | agent, at run start | mark desired-active; bind handoff + session handle (handle DERIVED from the instance's self-identity seam when `--session-handle` is omitted — #673) |
| `checkpoint <run-id> [--handoff P] [--lease-pod ID]… [--session-handle H]` (`update` compatibility name) | agent, at checkpoints | refresh handoff / link pods / rebind handle |
| `request-relaunch <run-id> [--handoff P] [--reason T]` | agent or a `StopFailure`-style hook | positive "recover me" signal (fail-closed on a terminal/missing record). **Requires a bound `handoff_path`** — pass `--handoff P` to bind it atomically, or it must already be on the record — since this is the can't-resume-in-place signal whose fallback (`launch_successor`) needs the handoff to point the fresh successor at. Fails closed if no handoff is bound after the request. |
| `is-desired-active <run-id>` | **supervisor** | exit 0 = relaunch-eligible; else 1 (fail-closed) |
| `is-relaunch-requested <run-id>` | **supervisor** | exit 0 = an active run asked to be recovered; else 1 (fail-closed) |
| `session-handle <run-id>` | **supervisor** | print the opaque instance handle (exit 1 if unset) |
| `status <run-id>` | agent/checklist | compact read-only evidence summary (fail-closed on missing/corrupt record) |
| `clear-relaunch <run-id>` | **supervisor** | clear the request after acting (idempotent) |
| `stop <run-id>` | a deliberate `/quit`/kill | terminal: never relaunch (also clears any pending request) |
| `close <run-id>` | the close finalizer | terminal: run finished (also clears any pending request) |

## What is INSTANCE, not product (do not put it here)

Per the #54 blast radius and the releasability rule, the product names the *operations*; the instance names the
*commands*. These stay in the consuming instance (e.g. under `~/.config/`), with a same-day pointer back to this
reference:

- the concrete mapping `resume_same_session → --continue`, `launch_successor → relaunch-session.sh <name> <dir>
  handoff` (adapted to take the bound `handoff_path`);
- `session_is_alive` (how to probe the `session_handle` — a tmux liveness check, a systemd `is-active`, a
  pid-file probe — using a positive mtime/heartbeat signal, never `pkill -f` self-matching);
- the concrete self-identity expression behind `EXPERIMENT_SESSION_HANDLE_CMD` (for a tmux instance, printing the
  bare current session name) — and, critically, the SAME expression its teardown seams compare against, since that
  agreement is the whole point of deriving the handle instead of letting the agent choose one (#673);
- the systemd timer or `setsid` bash loop that runs the pass, its cadence, the crash-storm cap constants, the
  RunPod key, session names, and paths;
- the **dry-run rollout window** (#54 "Rollout"): log the relaunches the supervisor *would* perform, reconciled
  against the ledger + the run-supervision records, before it relaunches for real — a buggy supervisor that
  resurrects a finished run is the one new failure mode this introduces.
