# Proposal: Dispatch-host lifecycle — the executor self-marks reapable on completion (#30)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

When the designer hands a locked brief to a fresh zero-context executor (the `design-experiment` →
`run-experiment` handoff), that executor runs **inside its own dispatch host**: a tmux session in a dedicated
working directory, so its conversation transcript stays isolated and the shared tree stays clean. When the
experiment finishes, the executor tears down the *GPU compute* and clears its *self-wake* — but it does
**nothing about the host it ran in**. The tmux session keeps running idle and the launch directory persists
until a human notices and reaps it by hand. So every dispatched run leaves a stray idle session plus a
launch dir behind, and an operator has to remember to clean each one up — exactly the litter issue #30 was
filed to stop.

Two things have changed since #30 was filed (2026-06-17) that reshape the fix. First, the launch-dir
*mechanism* #30 proposed — a plain throwaway folder under `~/.aar-dispatch/<exp>-<runid>/` — has effectively
been built, and built *better*: the instance dispatcher gives each one-shot executor its **own git worktree**
on a `run/<exp>` branch instead of a bare folder. That keeps the same transcript-isolation property #30
wanted (a unique cwd → a unique transcript slug → no history mixing) **and** adds two things a plain folder
can't: the executor commits and pushes its records to the branch (so the launch dir is no longer the only
copy of anything), and the shared checkout stays clean on `main`. Second, the close discipline that should
own host teardown — `run-experiment`'s Close step — was written for the GPU era and never grew a clause for
the dispatch host. So the real, un-built residual of #30 is *not* "create ephemeral launch dirs"; it is
**"close the dispatch host's lifecycle on completion."** This proposal is the design pass that records the
supersession and specifies that residual.

## Approach

Make the executor, at the very end of its own Close, **self-mark its dispatch host reapable** rather than
leave it running — but stop short of self-deletion. Concretely, once a run reaches any terminal state and the
executor has already verified GPU teardown, pushed its `RESULTS.md`, and cleared its self-wake, it performs
one final host-close: it records a **host-lifecycle** status where the dispatcher can read it, confirms its
branch is committed and pushed (so nothing in the launch dir is the only copy), and then stops its own idle
tmux session via a dedicated **non-destructive** dispatcher path. The marker is deliberately scoped to the
*host* lifecycle only — `host_state=closing|closed` — and carries **no experiment-outcome semantics**:
*whether the experiment concluded / was blocked / was abandoned* is the canonical-terminal-experiment-state
question owned by the #130 design (`blocked` / `invalid` / `abandoned` / `null-conclusion`), and the host
marker neither duplicates nor pre-empts it. A host can be `closed` regardless of how the science turned out;
the experiment outcome lives in `RESULTS.md` and #130's state, not in this marker. This is deliberately
**not** `--reap`: the existing `--reap`/`--reap-all` *delete* the worktree (`git worktree remove`), which is
the operator/TTL deletion step and must never be what a finishing executor calls. The design adds a separate
`dispatch-claude.sh --host-close <exp>` (a.k.a. `--mark-terminal`) that **writes the host-state marker and
hands the session kill to a detached closer, but leaves the worktree and its pushed branch on disk**. So the dispatcher ends up
owning two distinct verbs: the new non-destructive host-close (executor-invoked, on completion) and the
existing destructive reap (operator/TTL-invoked, after review). This design supplies the missing *trigger*
(the completion event) and a small machine-readable **host-state marker** (`closing` → `closed`) the
dispatcher and an operator can both read to know a host is finished and safe to remove.

**Who kills the session — a detached controller-side closer, not the executor itself.** The executor runs
*inside* the very tmux session that must be killed, so it cannot be the thing that kills it and then verifies
the result: the moment it `tmux kill-session`s its own session, its own process (and any post-kill verify it
was running) dies with it. So `--host-close` is not a synchronous in-session kill; it is a **handoff to a
detached controller-side closer** — the same pattern the scaffold already uses for the self-wake / idle-cost
backstop (a non-LLM controller-side supervisor that outlives the agent). Mechanically: the executor's
`--host-close` writes a `host_state=closing` marker (so the intent survives even if the executor's last turn
is cut short), then **spawns a detached closer process outside its own session and returns**; that closer —
not the executor — does the bounded wait, kills the tmux session, prunes, and writes the final
`host_state=closed` marker. The kill thus happens from a process that survives it.

**Ordering against #54's relaunch supervisor — `desired-active=false` immediately before the kill, in the same
durable step** (Finding-driven, load-bearing). #54 ships a model-free relaunch supervisor that *resurrects* a
session it observes gone while its run-supervision record is still `desired-active`. So a naive "kill the
session" would race that supervisor and **resurrect a legitimately finished run**. `--host-close` therefore
*consumes #54's existing `close` operation* — but the clear must be **immediately before** the kill and bound
to it in one durable step, not done early (see the close-ordering paragraph below: clearing it early opens a
crash window where the run is neither recoverable nor being closed). So the closer **clears `desired-active`
and kills the session atomically**, satisfying #54's mandate ("clear `desired-active` BEFORE the supervisor
could observe its session gone") without the early-clear hazard. This is the same record from the paragraph
above (#54's run-supervision record is the handle's home *and* the resurrection-control state), so host-close
is one coherent extension of #54, not a second parallel lifecycle: durably-launch closer → [closer: clear
desired-active + kill session] → prune → `closed`.

This makes the attestation split clean and honest. The executor's *audited* attestation (in `CHECKLIST.md`,
before the close audit) is only **readiness** — it can close its host (handle + generation resolved, finalizer
armed) — not that it has. The host-close *events* it then performs as its last act (`closing` marker, closer
launch) and everything the closer does afterward (`desired-active` clear, kill, `closed` marker) are recorded
in the **control-plane finalizer record**, not a post-session commit. The **post-kill** confirmation (session
gone, generation-keyed `closed` marker) belongs to the detached closer and to any operator/dispatcher read of
that record afterward — never "I watched my own session die." This matches the close self-audit rule (verify
state by inspection, not memory) without asking the executor to commit or inspect anything after its session is
gone.

**The close ordering — the executor only *launches* the closer; the closer owns `desired-active`-clear + kill
atomically** (Finding-driven; two real ordering hazards forced this precise sequence). Two constraints pin it.
First, **there are TWO gates at two altitudes — an audited *readiness* gate AND a post-audit *finalizer* gate —
and they must not be conflated.** `run-experiment`'s contract is "commit `CHECKLIST.md` at close → the
cross-family close audit verifies it," and that audit runs *before* the self-wake clears, while host-close is
the *very last* Close action *after* the audit. So **nothing about the host-close itself — not even "closer
launched" — has happened yet when the audit runs**: launching the closer is the action that kills the audited
session, so it cannot also be audited evidence. Forcing any host-close *event* into the audited CHECKLIST is
circular. The split therefore divides on the audit boundary:
- **Audited CHECKLIST `[BLOCK]` gate (in the brief, verified by the close audit):** asserts only **pre-audit
  readiness** — the `dispatch_host` declaration is resolved, the `dispatch_host_close` handle + generation/run-id
  are resolved, and the finalizer command is *valid and armed* (or `dispatch_host=none` → N.A.). This is a
  static fact knowable while the session is alive and *before* the audit, with nothing yet killed — so it sits
  legitimately inside the existing audited-checklist contract with no change to that contract's meaning. It
  proves the executor is *ready and able* to close its host, not that it already did.
- **Post-audit finalizer gate (control-plane, owned by the dispatcher/closer — NOT an audited commit):** *all*
  the host-close *events* — `closing` marker written, closer durably launched, `desired-active` cleared,
  session killed, generation-keyed `closed` marker written — happen *after* the audit, as the executor's last
  act plus the detached closer's work. None is a CHECKLIST commit the executor makes; the external finalizer
  satisfies them and the dispatcher/operator reads the result from the control-plane record.

So nothing asks the executor to commit-or-audit a host-close event: the audited gate is *readiness* (pre-audit,
nothing killed); the finalizer is the whole *initiated → closed* lifecycle (post-audit, owned outside the brief).
(This implies a small `run-experiment`/template note distinguishing audited checklist gates from post-audit
finalizer gates — captured in the product child below.)

Second, **the run must stay recoverable until the closer is durably in charge** — so `desired-active` is *not*
cleared early. If the executor cleared `desired-active` at the top of Close and then crashed before the closer
was durably launched, #54 would (correctly) refuse to relaunch a not-desired-active run while no closer exists
to kill the host — an orphaned, unsupervised, un-closed session. So the ordering is: **(1) executor, while
fully recoverable:** write the `closing` marker (a *recoverable* state — #54 still treats the run as
desired-active and would relaunch a crash here) and durably launch the detached closer; that is the executor's
last attestable act. **(2) detached closer, atomically:** clear `desired-active` *and immediately* kill the
session as one durable step (the #54-mandated "clear before the supervisor observes the session gone", now
genuinely immediate), then prune and write the durable generation-keyed `closed` marker outside the session.
The `desired-active`-clear and the kill live together in the closer, so there is no window where the run is
neither recoverable nor being closed. The executor never commits anything after its session is gone; the
post-kill truth lives in the closer's control-plane record.

**Where the marker lives, and its schema** (Finding-driven). The marker must live **outside the git
worktree** — in the dispatcher's own control-plane state dir — *not* a file inside the worktree. This is
load-bearing because the worktree is exactly what the existing `--reap` clean+pushed guard polices: a marker
written *inside* it would dirty the tree (or sit unpushed) and the guard would then refuse the very reap the
marker is meant to authorize. A control-plane marker is read/written by the dispatcher and the detached closer
without ever touching the worktree's git state, so it composes with the clean+pushed guard instead of fighting
it.

**The marker is keyed by dispatch *generation*, not bare slug** (Finding-driven, correctness-critical). The
dispatcher reuses the slug across dispatches of the same experiment (`name=run-$slug`, `wt=$WSROOT/$slug`,
`branch=run/$slug`), so a slug-only marker would let a **stale `closed` marker from a prior dispatch make a
later live re-dispatch of the same exp look reapable** — exactly the live-run-reap hazard the marker exists to
prevent. So the marker is keyed by a **dispatch generation / run id** unique per spawn (e.g. slug + a spawn
nonce or the worktree's creation identity). Two enforcement points follow: (1) **spawn initializes a
`host_state=running` marker for the new generation** (so a fresh dispatch immediately overwrites/supersedes any
stale prior-generation marker rather than inheriting it); (2) **destructive paths verify the marker generation
matches the current session/worktree** before acting — a `closed` marker whose generation doesn't match the
worktree on disk is treated as stale and does *not* authorize a reap. The marker schema is therefore:
`host_state` (`running` | `closing` | `closed` | `failed`), a **`generation`/run-id**, a start `timestamp`, a
`deadline`, and the closer's `pid` + `log` path — enough for an external reader to tell a live run, a
still-running close, and a stuck one apart, and to reject a generation mismatch.

**The closer is a bounded background wait — give it a deadline and a failure state** (Finding-driven; AGENTS.md
"Bounded background waits"). A detached closer with no deadline is exactly the unbounded-park footgun that rule
exists to forbid, and it's worse here because the executor has *already cleared its self-wake* by the time the
closer runs — so nothing the executor owns is watching it. So the closer carries a `deadline`; if it exceeds it
(the kill/prune hung), it writes `host_state=failed` with the reason, and `--list` plus any TTL sweep
**surface a stale `closing` (deadline passed, still not `closed`) and a `failed` as a visible operator-actionable
state**, never silently. `failed`/stale-`closing` hosts are *not* auto-reaped (they're the ones a human must
look at); the marker turns a stuck close into a flagged item rather than an invisible orphaned session.

To make the host-state marker actually *load-bearing* — the signal that a host is safe to remove — the
dispatcher's destructive and listing paths must consult it, not just the existing clean+pushed guard.
`--host-close` makes the marker the single source of host liveness; in turn `--list` shows **`running` vs
`closing` vs `closed` vs `failed` vs `legacy-unmarked`** (so an operator sees at a glance what is reap-eligible
and what is stuck), `--reap-all` and any TTL sweep target **only `closed`-marked hosts whose generation matches
the worktree on disk** (a running executor's worktree, a `closing`/`failed` one, or a stale-generation `closed`
is never swept), and `--reap <exp>` without a matching `closed` marker **warns / refuses unless `--force`** (so
an operator can't accidentally reap a live, stuck, or re-dispatched run, while keeping `--force` as the rescue
hatch). The clean+pushed guard stays as the *destructive* safety floor; the marker is the *liveness* gate
layered above it.

**Migration for pre-marker worktrees** (Finding-driven). Dispatch worktrees that already exist when
`--host-close` ships have *no* marker, and a naive "no `closed` marker ⇒ refuse unless `--force`" would turn
today's working clean+pushed `--reap` into forced cleanup for every legacy dispatch — a silent regression of
the existing safe path. So an unmarked dispatch is classified **`legacy-unmarked`** (no marker file at all, as
opposed to a present `closing`/`failed`), and for `legacy-unmarked` hosts `--reap`/`--reap-all` **preserve the
existing clean+pushed-only behavior** (no `--force` required). New dispatches always get a marker, so
`legacy-unmarked` is a shrinking one-time class, not a permanent fork; a host that has ever been through
`--host-close` is never `legacy-unmarked`.

For this to work for a *zero-context* executor — which reads ONLY the brief + scaffold + the machine-consumed
records this contract already has it consult — the host-close handle must be **surfaced on a record the
executor already reads, not buried instance-side and not passed as tmux seed text** (seed text isn't part of
the brief+scaffold a zero-context executor is contracted to read, and relying on it reintroduces exactly the
implicit-context fragility dispatch exists to kill). The handle names: the exact command to run at Close, the
host-state marker's path and schema, the readiness evidence the audited gate checks (handle + generation
resolved, finalizer armed), and an explicit host-presence declaration (the closed `dispatch_host` enum below). The next paragraph fixes *which* record — and it is not the
frozen brief.

**Who writes the handle, and where — #54's run-supervision record, NOT the reviewed brief** (Finding-driven,
load-bearing — it is the seam that makes #30 compose with #54 and #130 instead of fighting them). The handle
is launch metadata — a property of *how this executor was launched*, known only to the dispatcher. Two
constraints fix its home. First, **#130 freezes the entire brief commit** (`DESIGN.md` + `START.md` +
`CHECKLIST.md`) as the reviewed clearance artifact: any later change forces re-clearance. So a
dispatcher-filled handle *slot in `CHECKLIST.md`* is out — filling it at launch would mutate a reviewed,
frozen artifact. Second, **#54 already builds the right home**: a machine-consumed **run-supervision record**
(`create/update/stop/close/is-desired-active`, with a defined product-level path + schema) that is explicitly
*not* part of the brief and that the dispatcher/launcher already reads and writes. The `dispatch_host_close`
handle (the concrete `--host-close` command + marker path) is therefore **a field on #54's run-supervision
record, written by the dispatch step at spawn** — exactly the layer #54 already designates for machine-consumed
launch/relaunch state. The executor reads it from there (the record is already a thing a zero-context executor
in this contract consults, via #54's API), so it is *not* a new fourth unread artifact and *not* a
post-clearance mutation of the frozen brief. `CHECKLIST.md` carries only the **static, reviewed `[BLOCK]`
gate** (shipped by the designer, frozen with the brief, never mutated) whose evidence is *read from* the
run-supervision record at Close. The *contract* (an obligation + a record field) lives in the product; the
*values* are filled by the dispatcher/substrate into #54's record. And because the CHECKLIST template is the
scaffold's canonical forcing function for Close gates, the *gate* (not the handle value) is anchored there: a
universal `[BLOCK]` checklist gate requiring **host-close readiness** evidence read from the run-supervision
record (the post-audit finalizer owns the actual close), so the host-close can't be silently skipped the way
buried prose gets skipped.

**The gate is capability-gated by a closed `dispatch_host` enum — never substrate-blind, never silently
skippable by a broken launcher** (Finding-driven). The `[BLOCK]` gate reads a **`dispatch_host` field** the
substrate's dispatcher records. The field is a **closed enum of exactly two declared values plus the
absent/unset case** — and absent is *not* silently N.A.:
- **`persistent`** (carries the `dispatch_host_close` handle) → the substrate declares a persistent dispatch
  host and supplies the handle → the gate is a real `[BLOCK]`: the executor must show **readiness** (handle +
  generation resolved, finalizer armed) and then, as its post-audit last act, run host-close.
- **`none`** (carries a required `reason` string) → the substrate explicitly declares *no* persistent dispatch
  host → the gate resolves **N.A.** on that declared reason. The `reason` field is what distinguishes a
  permanent no-host substrate (`reason: "codex thread/watcher exits on its own"`) from a *transitional*
  declaration (`reason: "claude host-close not yet shipped — see #30 child 2"`): both are `dispatch_host=none`
  (so the enum stays genuinely closed — there is no secret fourth `none-yet` value), and the human-readable
  `reason` carries the migration intent and owner.
- **unset / absent, once a substrate has *claimed* persistent-host dispatch** → **FAIL (launcher bug)**, not
  N.A.: a persistent-host substrate whose dispatcher forgot to write the field is a broken launcher that would
  leak idle sessions forever, so the gate fails closed and surfaces it.

This preserves ordering-safety without the silent-skip hole: in the transitional window before
`dispatch-claude.sh --host-close` ships, the Claude dispatcher records `dispatch_host=none` with the
transitional `reason` (an explicit, auditable declaration with a migration note) → declared N.A., not the
ambiguous "absent ⇒ N.A." a launcher bug is indistinguishable from. The day `--host-close` ships, the
dispatcher flips the field to `persistent` (+ handle) and the same gate becomes a real `[BLOCK]`, no product
change.

The load-bearing decision is **"auto-mark reapable, not auto-`rm -rf` on completion."** A finished executor is
not a *reviewed* executor: the worktree may hold the failed logs, partial artifacts, or exact debug state a
human needs to understand a bad run, and "the run exited" is not "the result was seen." So deletion stays
operator-triggered (the existing `--reap`), or at most TTL-gated behind the dispatcher's existing strong
guards (clean tree, branch pushed at HEAD). What the completion event *does* do is stop the bleeding: hand the
idle-session kill to the detached closer and write the host-state marker, so the host stops consuming a session slot and
announces itself as reap-eligible, while its evidence stays on disk and on the branch until a human clears it.
This is strictly safer than #30's original "kill tmux + `rm -rf`," which would nuke an unreviewed worktree the
moment the executor stopped.

The split between the **product** and the **instance** is the second load-bearing decision. The product repo
(`automated-researcher`) gets the **substrate-neutral dispatch-host lifecycle contract** — a clause in
`run-experiment`'s Close step, a matching line in the `design-experiment` dispatch contract, a `[BLOCK]` gate
in the `CHECKLIST` template (static and reviewed-with-the-brief) whose evidence is **read from #54's
run-supervision record**, and the `dispatch_host` declaration + `dispatch_host_close` handle as **fields on
#54's run-supervision record** (not a post-clearance edit of any frozen brief file) — stating that the
dispatch host (the session/launch dir the executor ran in), like the GPU and the self-wake, must be brought to
a terminal state at Close: the executor runs the host-close command from the record, which clears
`desired-active` (so #54's supervisor won't resurrect it), writes the host-state marker, and hands the
idle-session kill to a detached deadline-bounded closer; *deletion* is a separate operator/TTL step that never
fires on unreviewed work; and durable results live in the committed/pushed record, never only in the launch
dir. The concrete Claude/tmux/worktree machinery — the `--host-close` verb, the marker's exact path and
format, the `~/ws/run/<slug>` worktree layout — stays **instance-side** in `dispatch-claude.sh` /
`new-claude.sh`, because Codex's dispatch host is a different shape (a fresh thread/watcher, no tmux, no
worktree, so it declares `dispatch_host=none` and the gate resolves a *declared* N.A.) and must satisfy the
same contract its own way. The product prescribes the *obligation* and the *record-field interface*; each
substrate supplies the *mechanism* and the field's *values*.

## Alternatives considered

- **Build #30 verbatim — a plain `~/.aar-dispatch/<exp>-<runid>/` folder with kill+`rm -rf` on completion.**
  Rejected: the worktree dispatcher already supersedes the folder (same isolation, plus pushed-backup and a
  clean shared tree), so re-introducing a bare folder is a regression; and immediate `rm -rf` on exit deletes
  unreviewed evidence. The right design keeps the worktree and replaces "delete on exit" with "mark reapable
  on exit."
- **Auto-`rm -rf` (or auto-`--reap`) the instant the executor exits.** Rejected as the default — it conflates
  "finished" with "reviewed" and can destroy the exact failed-run state a human needs. Auto-deletion is only
  acceptable TTL-gated behind the clean+pushed guards, as a later optional convenience, never the on-exit
  default.
- **Leave host teardown fully manual (status quo).** Rejected: it litters an idle tmux session + a launch dir
  per run and depends on a human remembering to reap each one — the original #30 complaint. The cheap, safe
  half (kill the idle session + write the marker) should be automatic; only the destructive half stays manual.
- **Put the tmux/worktree mechanics in the product repo.** Rejected: it would hard-code a Claude-specific,
  tmux-specific, `~/ws/run`-specific shape into a substrate-neutral product and break the Codex dispatch host,
  which has no tmux or worktree. The product owns the contract; the instance owns the machinery.
- **Carry the `dispatch_host_close` handle as a dispatcher-filled slot in `CHECKLIST.md`.** Considered (it
  reuses the existing read-contract member and the waker-id precedent), but **rejected because #130 freezes the
  whole brief commit — `CHECKLIST.md` included — as the reviewed clearance artifact**, so filling the slot at
  launch would mutate a frozen, reviewed file and force re-clearance. The handle instead lives on **#54's
  run-supervision record**, which is purpose-built machine-consumed launch/relaunch state *outside* the brief.
  `CHECKLIST.md` keeps only the static reviewed `[BLOCK]` gate that *reads* that record.
- **A standalone host-lifecycle marker that ignores #54's run-supervision record.** Rejected: #54's supervisor
  resurrects a session it sees gone while the run is still `desired-active`, so an independent host-kill would
  race it and revive a finished run. Host-close must *consume* #54's `close` (clear `desired-active` before the
  kill); one coherent lifecycle, not two parallel ones.
- **Treat an absent handle as N.A. (two-state gate).** Rejected: it lets a *broken* persistent-host launcher
  that simply forgot to write the handle skip the close obligation forever, indistinguishably from a substrate
  that legitimately has no host. The gate keys off a closed `dispatch_host` enum (`persistent`+handle / `none`+reason / unset⇒FAIL).

## Blast radius

- **Product (`automated-researcher`), docs at the implementation stage — but a runtime-protocol behavior
  change:** a Close-step clause in `run-experiment`'s SKILL.md, a matching line in the `design-experiment`
  dispatch contract, and a static `[BLOCK]` host-close gate in the `CHECKLIST` template whose evidence is read
  from **#54's run-supervision record** (where the `dispatch_host` declaration + `dispatch_host_close` handle
  live as fields — *not* a mutated `CHECKLIST.md` slot). Because this changes the `experiment-lifecycle`
  runtime protocol (a new Close obligation + a new required checklist gate), the product child **bumps
  `plugins/experiment-lifecycle/.claude-plugin/plugin.json` and adds a `CHANGELOG.md` entry** per the AGENTS.md
  "version bump on every behavior change" rule — it is not a no-op doc edit. No CI logic moves; the
  install/discovery surface is unchanged beyond the manifest version. This design PR itself is
  `proposals/*.md` only.
- **Cross-design dependency + the helper/schema extension (the load-bearing coupling):** the handle's home and
  the `desired-active`-before-kill ordering both ride on **#54's run-supervision record** (its
  `create/update/stop/close/is-desired-active` API + record path/schema + tests). So the product child here
  **depends on #54's child-1 shipping that record API first**, and is itself a concrete extension of it: it
  **adds the `dispatch_host` (closed enum + `reason`) and `dispatch_host_close` fields to #54's record schema,
  extends #54's helper API + tests to read/write them, and requires instance dispatchers to go through that
  helper** (not re-derive the record shape). The gate-evidence wording references #54's
  `is-desired-active`/`close` rather than inventing a second record. (A real ordering + DRY constraint surfaced
  in design review — recorded so the `ready` children carry it.)
- **Instance (this box), where the mechanism lives:** `dispatch-claude.sh` gains the non-destructive
  `--host-close` verb (clear `desired-active` via #54's API → write `closing` marker → spawn a
  *deadline-bounded* detached closer that kills the session, writes `closed`, prunes — or writes `failed` on
  timeout — reusing the existing clean+pushed guards), the **generation-keyed host-state marker stored in the
  dispatcher control-plane state dir, outside the worktree** (so it never dirties the tree the reap guard
  polices), **and marker-aware listing/deletion** — `--list` distinguishes
  `running`/`closing`/`closed`/`failed`/`legacy-unmarked`, `--reap-all`/TTL target only generation-matched
  `closed` hosts, and `--reap <exp>` warns/refuses without a matching `closed` marker unless `--force`.
  **The operator point-of-need docs must move with the mechanism:** the `manage-aar` skill (and any box
  guidance) still describe the *old* `~/.aar-dispatch` folder model and are already stale vs the worktree
  dispatcher, so the instance child updates them so `--list`, the host states, and the marker-aware reap
  semantics are discoverable exactly where an operator reaches for cleanup. `new-claude.sh` is unaffected
  beyond what the executor calls at Close. `run-experiment`'s executor gains a final host-close action. These
  land as the `ready` children, not in this
  design PR.
- **Risk profile:** low. The destructive operation (`--reap`/`rm -rf`) is unchanged and stays behind its
  existing guards and an explicit operator/TTL trigger; the new automatic behavior is only *killing an idle
  session* and *writing a control-plane status file outside the worktree*, both reversible and non-destructive
  (the worktree and its pushed branch survive). A stuck closer fails *visibly* (`failed`/stale-`closing`
  surfaced by `--list`), not silently, so the worst case is a flagged orphan session a human reaps by hand —
  never lost data and never an auto-deleted unreviewed run. The persistent `~/claude-N` fleet workers are
  explicitly out of scope — they are long-lived and never reaped by this path.

## Rollout + rollback

- **Sequencing:** this is a two-phase design PR (doc-only). It has a hard upstream dependency: **#54's child-1
  run-supervision record API must land first**, because the handle lives on that record and the close ordering
  consumes its `close`/`is-desired-active`. On merge #30 spawns `ready` children: (1) the product contract —
  the `run-experiment` Close clause (incl. the **audited-checklist-gate vs post-audit-finalizer-gate**
  distinction), the `design-experiment` dispatch-contract line, the `CHECKLIST`-template static `[BLOCK]`
  "host-close readiness" gate (evidence read from #54's record; the actual close is the post-audit finalizer),
  **the extension of #54's record
  schema + helper API + tests with the `dispatch_host` closed-enum (+`reason`) and `dispatch_host_close`
  fields**, **plus the experiment-lifecycle version bump + CHANGELOG entry**; (2) the instance non-destructive `dispatch-claude.sh --host-close <exp>` verb (clear
  `desired-active` via #54's API → write `closing` marker → spawn a deadline-bounded detached closer that kills
  the session + writes `closed` + prunes, or `failed` on timeout; **generation-keyed** marker stored in the
  control-plane state dir outside the worktree; spawn initializes a `running` marker; reusing the existing
  clean+pushed guards; `legacy-unmarked` preserves old reap), the dispatch step writing the handle +
  `dispatch_host` declaration onto #54's record at spawn, the **marker-aware (generation-matched)
  `--list`/`--reap`/`--reap-all` semantics**, and the **`manage-aar`/box-guidance doc update** so the new states
  + cleanup are discoverable at the point of need; (3) the `run-experiment` executor's final
  host-close action that invokes (2) at Close.

  **Ordering correction (Finding-driven — the gate is NOT safe before any launcher change).** Because
  the gate FAILs on an `unset` declaration once a substrate is in scope, and the *current* dispatcher writes no
  `dispatch_host` declaration at all, child (1)'s gate must **not** land alone — it would make every unmarked
  Claude dispatch FAIL immediately. So a tiny **prerequisite (1a)** ships *with or before* the gate: the
  dispatcher writes an explicit `dispatch_host=none` declaration with the transitional `reason` onto #54's
  record at spawn (a few lines, no `--host-close` logic). That makes the gate resolve a *declared* N.A. for Claude in the
  transitional window — never `unset`⇒FAIL — without yet requiring the full host-close mechanism. The gate then
  turns into a real `[BLOCK]` for the Claude substrate only once (2)+(3) ship `--host-close` and the dispatcher
  flips its declaration to `persistent` (+ handle). So the safe landing order is: **#54 record API → (1a)
  declaration write + (1) gate → (2)+(3) host-close mechanism + flip to `persistent`.** A Codex substrate that
  truly has no persistent host declares `dispatch_host=none` and is permanently N.A.
- **Rollback:** the product change is a doc clause — revert the squash commit through the normal lifecycle.
  The instance completion path is opt-in by construction, **but rollback must flip the declaration, not just
  drop the call** (Finding-driven): once the dispatcher declares `persistent` (+ handle), the `[BLOCK]` gate
  *requires* the host-close call, so merely "stop calling it" would fail closed. So disabling the mechanism
  means **flipping the dispatcher's `dispatch_host` declaration back to the transitional/disabled state**
  (`dispatch_host=none` with a disabled `reason`), which returns the gate to a declared N.A. — or, for a full product rollback, reverting the
  checklist-gate clause itself. **A disabled declaration also reclassifies already-markered hosts:** any host
  carrying a `running`/`closing` marker when the mechanism is disabled is treated like `legacy-unmarked` for
  reap — clean+pushed cleanup, no `--force` needed — so flipping the declaration doesn't strand
  mid-flight-markered hosts behind the marker-aware refusal path. (For a full product rollback, marker
  creation + the marker-aware `--list`/reap semantics revert together as one instance change.) Either way the
  world reverts to today's manual-reap behavior with no data at risk, because deletion was never automatic. The
  standing escape hatch is unchanged: `dispatch-claude.sh
  --reap <exp>` / `--reap-all` for manual cleanup, `--list` to see what's outstanding.
