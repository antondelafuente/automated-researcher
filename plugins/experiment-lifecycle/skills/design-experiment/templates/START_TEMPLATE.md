# START.md — <EXP_NAME>  (<one-line what this run does>)

You are a **fresh-context executor** on a disposable compute environment (<backend / GPU, e.g. a cloud GPU pod>).
Zero prior context — **this file plus `DESIGN.md` in this same directory is your whole brief.** Work
autonomously, do NOT ask questions. A supervising agent watches your progress; talk to it with clear status lines.

<!-- DESIGNER: cite DESIGN.md, don't restate it (automated-researcher#817). This file carries what is
     OPERATIONALLY its own — paths, exact commands, env, the executor disposition, the artifact list — and
     REFERENCES DESIGN.md by section heading for everything the design already states (arms, instrument pins,
     the canonical metric, fan-out, comparability, Presentation): "arms + pins per `DESIGN.md` § What's
     measured". A restated pin is a second copy that can diverge from the one the design-audit cleared. The
     executor has DESIGN.md open right here, so self-sufficiency is unaffected — but every `DESIGN.md §`
     citation you write must resolve to a real heading; check them in the self-sufficiency pass. -->

**Read `DESIGN.md` (same directory) first — it is the science this brief executes.** Where a section below
cites `DESIGN.md § <heading>`, that citation is the authoritative statement; this file does not repeat it.

> **Executor disposition (verbatim — this is what makes the handoff work):** Run this experiment to completion — do
> not end your turn until you hit a real blocker or you're done; stopping after planning is the failure mode.
> Mechanical/reversible gap → pick a sensible default, record it, keep going. Load-bearing gap (changes
> method/cost/meaning) → notify the designer-of-record and work AROUND it; only a gap that blocks the whole run stops
> you, and then you notify + arm your self-wake — NEVER park silently. **Your questions go to the designer-of-record,
> not the researcher** — they answer them, and escalate only what changes the cleared budget or what is being
> measured; a question whose answer is checkable from the records or the live state is not a question, so verify it
> yourself instead of routing it anywhere. That routing governs every escalation in this brief however the individual
> line is worded — anything telling you to notify, gate on, or get clearance from "the human" or "the researcher"
> means the designer-of-record unless it is a budget or meaning change. (An instance line requiring a *human's*
> authorization for credentials, access, or destructive operations beyond this run's own compute is a trust gate, not
> question routing — honor it as written.) The design is locked: execute per `DESIGN.md`,
> collect the data it specifies and report it (the numbers / plot); do not redesign and do not pre-register a verdict —
> interpretation is the researcher's separate step. Never dispatch `Agent(subagent_type: "fork")` for a narrow research
> question — the fork inherits this whole disposition and can silently take on the executor role itself; do narrow
> research inline or via a read-only, non-fork subagent instead (see `run-experiment`'s executor-disposition section
> for the incident and the full guardrail).

## Designer-of-record — WHERE your questions go (an address, not a description)
- **Designer-of-record:** <who — the designing agent/role>, harness session name **`<designer_session>`**.
  <!-- Written by the LAUNCHING session at launch, not by the designer at design time (the launcher may be a
       different session, even a different family): `launch-experiment`'s
       `launch_record.sh bind-designer <this file> <name>` fills it from that session's OWN harness session
       name (Claude Code: the name `ListAgents` shows for it) — never an assumed tmux/fleet name, and never a
       hand-edit. Left as the placeholder until then. -->
- **Bind it on the run-supervision record at `start`:** `--designer-session <designer_session>` (the launching
  session's `verify-bootstrap` refuses to call the launch complete until this matches).
- **This line is the SEED; the record is the address of record.** The designer re-binds `designer_session` with
  `checkpoint --designer-session <new name>` when the role moves mid-run (a handoff, a relaunch under a new
  name) — this brief is not reissued, so it goes stale on purpose. Resolve the live address immediately before
  **every** notify: `run_supervision_record.sh designer-session <run-id>`, and address what it prints.
- **How to reach them:** record the question durably first — `run_supervision_record.sh ask-question <run-id>
  --text "…"` — then resolve the address as above and push one notify to it with your substrate's
  session-addressed message primitive (Claude Code: `SendMessage <resolved name>`). **Never `tmux send-keys`
  a session name:** under a Remote-Control host one tmux name fronts many spawned zero-context sessions, so the
  keystroke lands in whichever sibling holds the keyboard — on 2026-08-30 that sibling read the record, ruled as
  designer-of-record and consumed the question before the supervising session ever saw it.
- **Resolved value = `record-only`, or no such primitive here → do not improvise a push.** The record IS
  the channel: the designer polls `has-question`. Keep working on everything the gap doesn't block either way —
  the push is a notification, never something you idle on.

## Your one job
<One sentence: build/train/eval X, upload, report. What new data point this produces.>
Arms, metric, comparability pins: `DESIGN.md § <heading>` — do not restate them here.

## The idea (so you can sanity-check your own work)
<2–4 sentences on what a correct result looks like OPERATIONALLY, so you can catch your own bugs —
e.g. "if any single arm wins >90% the selection is degenerate". The purpose itself lives in
`DESIGN.md § <heading>`; cite it rather than paraphrasing it.>

## Inputs. ⚠️ FILE NAMES CAN BE MISLEADING — verify by content, not name:
- <label>: `<storage path / URI>`  (<discriminator: avg length, label rate, etc.>)
- <label>: `<storage path / URI>`
- Scripts: `<where the executor pulls the worked-example drivers from>` (pull them; don't write from scratch).
- Base model / artifacts: `<HF repo@<commit-sha>, or the artifact-store staged path>` — never a bare local path
  (a base living only on disposable storage becomes unrecoverable the moment that volume is gone, #106), and
  never a mutable ref (a branch/tag like `@main` can move to different weights before the next rerun — pin the
  commit SHA itself). <Any cache/env setup needed before download.>

## Environment
- <The readiness signal to wait for before training/eval, and how the env is provisioned.>
- <Named venvs / containers / toolchains and what each is for.>
- <The repo / code location.>  Work dir: `<scratch dir>` (touch only this).
- <The check that the right compute is present — else print `<NAME> BLOCKED: wrong env` and stop.>

## Steps
1. Wait for the readiness signal; verify compute.
2. Pull inputs → the work dir.
3. <Generation / selection / preprocessing, with the EXACT script + flags.>
4. <Train / transform, with the matched recipe — every hyperparameter pinned. Verify the output artifact exists.>
5. <Eval — the EXACT eval definition + flags (this is load-bearing for comparability). Don't kill a slow long tail.>
6. <Any second eval axis, with its grader + config + required API keys.>
7. **Upload:** `<copy work dir → durable storage>` (artifact + summaries + a SUMMARY.md).

## Reporting (completion = the durable artifacts, not a chat message)
- Status lines as you go: `>>> env ready`, `>>> data pulled`, `>>> train done loss=…`, `>>> eval1 done <m>=…`, …,
  `>>> uploaded`.
- Reference points / known anchors for sanity: <e.g. base metric ≈ X; other expected values>.
- When summaries are uploaded, print exactly: **`<NAME> DONE <metric1>=<n> <metric2>=<n> …`**.
- If stuck >15 min, print **`<NAME> BLOCKED: <one-line reason>`** and stop — don't spin.

## Resilience (be resumable by a model-free supervisor — maintain continuously, not at close)
- Checkpoint run state to DISK, not only the conversation: pod ids, what's collected, the DESIGN data-collection
  spec lives in the artifact dir / this file / the ledger (a fresh successor only has the disk).
- Keep a standing successor handoff at `<TEMP.md path>` (pointers only — pod ids, artifact paths, look-again
  deadline, next action; never trigger-prone prose); refresh it at every checkpoint.
- Write the run-supervision record at run start and keep it current:
  `run_supervision_record.sh start <run-id> --handoff <TEMP.md path> --worktree <this worktree's path>
  --designer-session <designer_session>`,
  then `checkpoint … --handoff <TEMP.md path> --lease-pod <id>` at each checkpoint. `--designer-session` is the
  designer address from the section at the top of this brief — bind it verbatim; it is what your question
  notifies are aimed at, and the designer's dispatch-completion check verifies it matches. The session handle that
  `start` binds is the supervisor's `run-id` → session binding (how it knows WHICH process this run is, to probe
  liveness, resume in place, and reap at close); its shape is **instance-owned** — a tmux session name, a systemd
  unit, a pid-file path — but it is NOT yours to invent: `start` derives it from the instance's own self-identity
  seam so the recorded value is exactly what the teardown seams compare against (a hand-written near-miss like
  `tmux:<name>` silently defeats both the close-time reap and the janitor backstop, and cannot be corrected once
  the record is closed — `automated-researcher#673`). So **omit `--session-handle`** unless this instance's
  dispatch/launcher injects a concrete handle here (or pre-creates / `update`s the record with it), in which case
  pass exactly that value and never a literal placeholder. `--worktree` is set by the executor itself, from
  **inside its own worktree**, at start — it is the
  run-id<->worktree binding `reap_worktree.sh` checks at close, so a clean-closed run-id can only ever reap the
  worktree IT bound, never a peer's. Use `run_supervision_record.sh status <run-id>` as checklist evidence. At close it's a POST-AUDIT finalizer:
  `close <run-id>` (finished) / `stop <run-id>` (deliberate quit) — never cleared early. (See the run-experiment
  resume contract + the CHECKLIST open/close gates.)

## Instance profile (snapshot)
<!-- generated by `scripts/aar_profile_snapshot.sh snapshot` — do not hand-write. Run it on this file
     before the design-stage commit (design-experiment SKILL.md Step 3); the log-experiment design-stage
     gate verifies this block is present and not stale before the design PR can merge (#469). -->

```toml
# not yet resolved — run: scripts/aar_profile_snapshot.sh snapshot <this-file>
```

## Constraints
- Touch only your work dir (+ read the repo, shared envs, inputs).
- Throwaway environment. Match the reference recipe exactly EXCEPT the variable under test; get the numbers; upload; report.

<!-- This is the substrate-neutral skeleton. An instance fills the placeholders from its own frozen recipes
     (backend, env topology, model, exact eval definitions) — those are instance content, not part of the product. -->
