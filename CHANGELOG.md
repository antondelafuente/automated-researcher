- experiment-lifecycle 0.3.33 (2026-07-11): document the `disown`-defeats-trailing-`wait` sample-fanout footgun
  in `run-experiment` SKILL.md, alongside the two existing kill-rule footguns in the same Step 3 section
  (#415). Incident: a sample-fanout driver launched each sampling job with `nohup ... & disown`, then closed
  with a bare `wait` intended to block until every job finished before writing a "DONE" marker. `disown`
  removes the job from the shell's own job table, so the bare `wait` returned as soon as the launch loop
  itself finished — NOT when the jobs actually completed — and the "DONE" marker fired while 11 of 19
  subjects were still mid-sample (caught only because the executor independently verified PIDs/row counts).
  The new guidance states the rule plainly: `disown` and ANY `wait` on the same jobs are mutually exclusive,
  bare or by PID — bash cannot wait on a disowned PID at all, so collecting PIDs does not rescue a disowned
  `wait`. Pick by whether the driver itself needs to block: don't disown when the driver's own `wait` is how
  it blocks until the jobs finish; disown for survivability past the driver and replace `wait` with a `kill -0`
  liveness poll loop on the collected PIDs instead. The concrete `sample_fanout_cab1.sh`/cpc1 driver scripts
  this incident traces to are instance-owned (not present in this repo per the Releasability rule); this
  change carries the generic, product-owned lesson.
- experiment-lifecycle 0.3.32 (2026-07-11): make the detached-driver "skip cells whose output exists"
  resume check SUCCESS-aware, not presence-only (#357). Incident: `ld1_driver.py`'s resume check treated
  ANY row present in the output as permanently done regardless of whether the read actually succeeded, so
  a row that hit `final_label=null` / `final_source="excluded_parse_failure"` was never retried on later
  driver invocations — it sat silently wrong until a downstream aggregate happened to disagree (a
  73/8884-row, 0.8% discrepancy caught only by comparing `n_lie_rows` vs `n_direction_read` at close). The
  same failure class was already fixed in `judge_b0_tdc1.py`'s `cell_todo()` (strip any non-"ok"
  `parse_status` row from "done" every pass) but the direction-reader template never got the analogous
  fix, and it's reused verbatim across experiments. `run-experiment` SKILL.md's Step 3 driver guidance now
  spells out that the done-check must strip any row lacking a valid success marker (a real label/score,
  not `null` / an `excluded_*`/error status) from the "done" set before computing what's left `todo`, so a
  failed read gets requeued instead of sitting silently wrong.
- experiment-lifecycle 0.3.31 (2026-07-11): clarify that "concurrency is free" is a REMOTE/provider-side
  billing statement only, and add a reusable throttled-launch helper for LOCAL driver concurrency (#402).
  Incident: a 40-way Tinker LoRA train fan-out followed run-experiment's "concurrency is free" guidance and
  launched all 40 `train_ccp.py` drivers at once; each driver holds ~1.5-2GB RAM on the CONTROLLER box while
  building/holding its rendered datums even though the actual training runs on Tinker's servers, so the
  naive full fan-out hit the controller's local RAM ceiling well before any remote concurrency cap and
  silently OOM-killed 21/40 processes with zero log output. `run-experiment` SKILL.md's Execution discipline
  section gains a bullet distinguishing remote/provider-side billing concurrency from LOCAL controller-box
  concurrency, and a new `local_job_queue.sh` (+ smoke) in the skill's `scripts/` gives executors a
  reusable, memory-aware throttled-launch queue (bounded by the shell's own job table via `jobs -rp`, not
  `pgrep`, so a wrapping session/driver whose own command line names the same job pattern can never
  self-match and stall the queue) instead of re-deriving the fix from scratch each time.
- experiment-lifecycle 0.3.30 (2026-07-10): define ledger terminal status as OPERATIONAL run health, never a
  scientific verdict (#376). Incident: an executor closed two correctly-executed Helena evaluations with
  ledger `failed` because an instrument-calibration gate and a parse-coverage gate did not pass — a planned,
  correctly-executed no-go, not a broken execution — and the dashboard truthfully rendered two good runs as
  broken ones. `run-experiment` SKILL.md's ledger-write step (Step 4) now defines three product-owned abstract
  outcomes — completed-as-designed (includes a correctly executed planned no-go / validity-gate stop),
  technical-failure (a genuine execution failure or experiment bug), deliberate-abandon (`killed`, unchanged)
  — and requires the instance's ledger recipe (still narrative prose, no schema change) to map these onto its
  concrete terminal strings; an executor fails closed if that mapping is undiscoverable or contradictory,
  never guessing. `[BLOCK] FAIL` in `CHECKLIST.md` is explicitly named as a validity-trail term, distinct from
  ledger `technical-failure` — the two can legitimately co-occur with either ledger outcome. The
  `CHECKLIST_TEMPLATE.md` legend + ledger `[BLOCK]` gate gain matching cross-references. No numerical
  hypothesis threshold introduced; the data-vs-verdict philosophy is unchanged. The consuming-instance
  compatibility/backfill (correcting this box's two mislabeled Helena ledger rows, append-only) is tracked
  separately at `antondelafuente/research-lab#211`.
- experiment-lifecycle 0.3.29 (2026-07-10): give `visualize-results` its own editorial publish-destination
  recipe, `[recipes.visualization_publish]`, instead of reusing `[recipes.viewer]` (#369). Instance mismatch
  found before rollout: `run-experiment`'s close-time publish leg (#347) lands operational experiment pages
  under the configured dashboard viewer, while `visualize-results` (#365/#366) lands researcher-driven
  editorial pages under a genuinely separate site on instance #1 — reusing `[recipes.viewer]` for the latter
  would have silently routed editorial publish to the wrong destination. `visualize-results --publish` now
  resolves `[recipes.visualization_publish]` (a new, independently-typed, optional recipe key, same shape as
  every other recipe); preview mode is unchanged, still resolving only `[recipes.visualization_preview]`;
  neither mode reads `[recipes.viewer]` anymore. `run-experiment` and `[recipes.viewer]` are untouched. Both
  canonical aar-profile `SCHEMA.md` copies, the skill's own recipe reference, and the fake-HOME smoke are
  updated; the smoke gains a distinct-destinations regression proving `visualization_publish` and `viewer`
  never cross-resolve even when both are configured. Rollback of this change is NOT a bare code revert (it
  would resurrect the reintroduced-bug code path); it requires a coordinated revert of `visualize-results`'s
  publish capability alongside the resolver.
- experiment-lifecycle 0.3.27 / verify-claims 0.7.15 (2026-07-10): the executor builds + publishes the
  experiment's viewer page at close, from committed iterable source (#347, extends #313). Field experience:
  "experiment closed" never meant "page live" — every close waited on a manual designer pass, hand-built page
  source accumulated untracked in a shared checkout (seven experiments backfilled by research-lab PRs
  #184/#185; two have manifests but no page source anywhere). Three parts. (1) `design-experiment`'s
  Presentation spec is pinned render-ready: per figure, plot type / arms / metric+axes / per-cell data source
  — a stranger could render it unattended; no-verdict posture unchanged. (2) `verify-claims`
  `audit_experiment --design` dimension 8 gains RENDER-READINESS alongside persistence — a figure spec the
  executor couldn't render without asking the designer is an under-specification finding. (3)
  `run-experiment`'s close publish leg flips from designer-at-publish-time to executor-at-close, behind the
  existing profile seam: a typed, pinned `[recipes.viewer]` recipe pointer (schema example-key addition, no
  MAJOR bump), snapshotted into `START.md` like every recipe — the executor never resolves live config. The
  recipe doc has a required-contents contract (viewer repo + gated landing path, page lib + prior-page
  pattern, assemble/render/bundle/gallery commands, source destination); missing contents = load-bearing flag
  → manifest-only. `CHECKLIST_TEMPLATE.md` gains a matching UNIVERSAL gate with a deliberately MECHANICAL bar
  (figures per spec, source committed, page landed via the gated path) — page prose stays a first-pass draft
  the researcher polishes, and post-close framing tweaks stay one-script edits because the source is
  committed. No `[recipes.viewer]` in the snapshot → manifest-only close, exactly the prior behavior.
- experiment-lifecycle 0.3.26 (2026-07-05): designer-side supervision goes two-layer — event-driven monitor +
  long merged heartbeat instead of `/loop 20m` per executor (#342). The old dispatcher-watchdog contract ran
  a 20-min model loop inside the designer session; at ~500k tokens of accumulated designer context and a
  5-min prompt-cache TTL every tick was cache-cold (~$300 of a ~$337 measured session was cache traffic, two
  concurrent executors doubled it). `design-experiment` SKILL.md now splits supervision by failure mode: the
  executor's own independent self-wake owns IDLE detection (benign waits, dead in-session monitors,
  no-progress-while-billing, GPU-utilization judgment); the designer owns only SESSION-WEDGE (the executor's
  session API-stuck mid-turn — the one failure its own wake can't cure) via an event-driven shell monitor
  per pane (DONE/BLOCKED/pane-gone; zero model turns while healthy) + ONE merged 45–60 min pane-read
  heartbeat (advancing-vs-frozen judgment, `send-keys` nudge), optionally dispatched to a separate small
  session when designer context is known-large. The #323 utilization-series obligations (series not point
  read, judge in context of the current step, restart-over-wait on sustained flatline) relocate to
  `run-experiment` Execution discipline, sampled on the executor's own self-wake ticks — nothing deleted,
  ownership moved. Plus a context-hygiene line: designers route bulk reads through subagents/forks during
  supervision phases. Codex-designer gap (#223) and the one-supervision-level invariant unchanged.
- experiment-lifecycle 0.3.25 (2026-07-04): prevent retroactive launch ledger events from reopening closed
  runs (#338). Incident: `carrier-divergence-2` reached `done` with `RESULTS.md` written, then the executor
  backfilled a missing launch event with a `running` ledger write during close self-audit; because the
  ledger fold is last-non-null-field-wins, the folded state flipped back to `running` and the dashboard
  showed a finished run as still running. `run-experiment` SKILL.md's Step 5 self-audit now requires the
  ledger's folded/latest status to be TERMINAL (not just that a launch event exists somewhere in history)
  and explicitly forbids backfilling `running`/`launched`/`deploying` after a terminal event — missing
  launch metadata becomes a non-status note or a fresh terminal-status event instead. The
  `CHECKLIST_TEMPLATE.md` UNIVERSAL gates gain a matching `[BLOCK]` gate so the mechanical close checklist
  enforces it, not just skill prose. Hardening `ledger.py` itself and an optional dashboard-side warn are
  instance-owned follow-ups (the ledger recipe lives in the consuming instance, not this repo) — out of
  scope here.
- AGENTS.md / experiment-lifecycle 0.3.24 / feedback-loop 0.1.5 (2026-07-03): absorb four researcher-interaction
  dispositions from the instance constitution into the product (#327) — the instance file kept only per-box
  values (this box, this customer), not conventions any deployment's agents need, and a Codex-substrate agent
  never sees one Claude instance's memories. AGENTS.md gains a "Researcher-interaction defaults" section
  carrying the canonical one-line definition of each, pointing at the skill that already carries the mechanics:
  (1) labor is free — estimates quote three currencies only (dollars, external wall-clock,
  researcher-attention-minutes), implementation effort never defers a proposal, independent work launches as
  one parallel wave; `design-experiment` SKILL.md gets a matching posture bullet (generalizing #322's
  enumerate-don't-justify logic one level up, to independent experiments) and ties its Cost estimate bullet to
  the same three currencies. (2) conclusions vs postdictions — verified already fully carried end to end by
  `design-experiment` / `run-experiment` / `verify-claims`; AGENTS.md gets the definition line only, no new
  mechanics. (3) validity/comparability as the main failure mode — same: already the standing disposition
  behind every `verify-claims` audit; definition line only. (4) user/maintainer separation + the feedback
  loop — `file-feedback` and `triage-feedback` SKILL.md already had the "user" framing but not the "separated
  in time, never both hats at once" statement or the "don't refactor mid-run" / "single-writer" lines; both
  gained the missing framing (no duplication of what was already there). No procedure changes, no schema
  changes.
- experiment-lifecycle 0.3.22 (2026-07-03): runtime throughput defaults — API concurrency starts high, watchdog
  tracks GPU utilization over time (#323, companion to #322). Motivating incidents: a neutral-corpus generation
  crawled at ~50 rows/min for hours against an over-conservative client, and E1 judging at 2-3 workers made
  judging the eval bottleneck (~15 min/student) when ~50 workers cost nothing. (1) `run-experiment` SKILL.md's
  Execution discipline gets a new bullet: any API loop (LLM judge, corpus generation, batch scoring) starts at
  ~50 concurrent requests, not 2-3, with exponential backoff on 429/timeout and re-ramp after recovery —
  discovering the provider's real limit is the backoff's job, not the initial guess's; ~50 is the starting
  point, not a hard cap, and a documented tighter execution-profile quota still governs. (2) `design-experiment`
  SKILL.md's #292 dispatcher-watchdog paragraph is extended: during a long-running GPU-bound step, sample
  `nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv` several times across the ~20-min window
  (over the pod's SSH endpoint via the existing `pod_lease.sh find-by-pod`/`show` lookup, independent of the
  executor's tmux pane), keep the series across the watchdog's own loop iterations (not the executor's
  run-supervision record, which is strictly relaunch-scoped state), and judge it in context of the executor's
  current step — 0% during "waiting on judge API" is fine, 0% for 40+ min during "training/generating" is a
  flatline. Restart-over-wait bias: with checkpointed resumable state, a flatlined job is cheap to restart and
  expensive to wait out — don't kill on one bad sample, do recommend restart on a sustained flatline against a
  GPU-bound step. Text-only; no new tooling. (#323)
- experiment-lifecycle 0.3.21 / verify-claims 0.7.14 (2026-07-03): replace the #311/#312 serial-edge
  JUSTIFICATION framing with parallelism ENUMERATION (#322) — justification-mode invited circular
  rationalization, observed same-day in restriction-sweep-1 ("single shared GPU is the resource limit"
  justified a serial edge whose single GPU was itself a discretionary one-pod choice made a line earlier;
  design-audit's schedule-efficiency dimension passed it because both author and auditor were defending/
  checking the plan as drawn instead of generating the parallel alternative). `design-experiment` SKILL.md's
  schedule-sketching step now asks for enumeration (each step's max sensible fan-out, priced) instead of a
  justification for each serial edge, with this researcher's concrete defaults stated as norms: 5-10 pods is
  the NORMAL fan-out for parallelizable GPU work (not an escalation needing permission), API concurrency
  starts at ~50, and per-wallclock cost is linear in pod count so pod-count conservatism buys nothing — the
  only real caps are setup/warmup fraction (~20-30% of the unit of work), GPU stock/quota or a real,
  documented API/provider rate limit, and a true data dependency or validation gate.
  `audit_experiment.sh --design` dimension 7 (schedule efficiency) is reframed to match: enumerate the
  parallelizable steps and their max sensible fan-out, and check the design sits at
  max fan-out per step or the researcher explicitly declined it; a resource limit that is itself a
  discretionary design choice (e.g. "only one pod") is NOT a valid reason to serialize. The per-compute vs
  per-wallclock billing distinction from #311 is kept unchanged — it correctly caught the 2026-07-03
  hereditary-ccp-platform incident and isn't part of what broke. `run-experiment`'s runtime concurrency/
  watchdog text is untouched here — that's companion issue #323. (#322)
- verify-claims 0.7.12 (2026-07-03): add SCHEDULE EFFICIENCY as design-audit dimension 7 (#311), and make the
  dispatcher-side executor watchdog a first-class fact of the lifecycle. `audit_experiment.sh --design`'s
  prompt now checks whether the schedule justifies every serial edge (a validation gate / true data dependency
  / shared-resource limit) and whether its cost reasoning distinguishes per-compute billing (Tinker-style — N
  parallel runs cost the same as N serial) from per-wallclock billing (a rented pod) — the check that would
  have failed the 2026-07-03 hereditary-ccp-platform incident (serial Tinker training called "the cheap
  default" on a false per-wallclock premise, caught only by the researcher in conversation after the design
  had already cleared this audit; wall-clock ETA dropped ~2-4 days to ~1 day at zero cost delta). SKILL.md's
  mode summary and the script header now cite the same incident. Prompt-only change to `audit_experiment.sh`;
  no script logic changed. (#292, #311; paired experiment-lifecycle bump below carries the design/runbook side.)
- experiment-lifecycle 0.3.18 (2026-07-03): make the dispatcher-side executor watchdog a standard step of
  `design-experiment`'s dispatch flow (#292), and add efficiency-mindedness to the design/runbook stages
  (#311). (1) The moment a designer dispatches an executor, it now arms one watchdog loop per executor
  (~20 min cadence) — a Claude Code designer uses its built-in `/loop` (cross-referencing #223 as the
  still-open Codex-equivalent gap rather than inventing one); each iteration reads the executor's live state
  (e.g. `tmux capture-pane`) and assesses progress-vs-wedged, which checklist step it's on, and whether a
  load-bearing question is sitting unanswered, nudging (`hello`) if wedged and surfacing real problems to the
  researcher. Exactly one supervision level (launcher watches executor; nobody watches the launcher, out of
  scope). The nudge is explicitly bounded health supervision, not driving — cross-referenced against the
  existing "don't drive it mid-run" designer-of-record invariant so the two don't read as contradictory. (2)
  Step 1's schedule-sketching now asks designers to actively brainstorm concurrency (including restructuring —
  sharding a step, starting a step before its wave completes) with multi-pod fan-out as an acceptable default,
  not a special case; the cost-estimate line is upgraded from "state the parallel-wave shape" to "justify
  every serialization" (each serial edge names a gate / true data dependency / shared-resource limit, and
  "cheaper" only counts if the billing model actually charges for concurrency). (3) `run-experiment`'s
  Execution-discipline "Parallelize, then iterate" line gets a runtime backstop: independent units run
  concurrently by default, and low GPU utilization during a long step should raise the bottleneck knob
  (batch/concurrency), noted in the run log — with a one-line tie back to the watchdog optionally folding
  `nvidia-smi` utilization into its periodic check. Motivated by the 2026-07-03 hereditary-ccp-platform run
  (the proven `/loop 20m` watchdog pattern; a DESIGN.md that declared serial Tinker training "cheap" on a
  false per-wallclock premise). Docs-only; paired with the verify-claims design-audit dimension above.
- experiment-lifecycle 0.3.17 (2026-07-02): fix two compounding bugs in `log-experiment.sh`'s note/design-stage secret scan that permanently blocked legitimate journal logs (#306). (1) The `sk-[A-Za-z0-9_-]{20,}` pattern had no LEFT word boundary, so it matched inside any long hyphenated identifier merely CONTAINING `sk-` — a committed HTML anchor like `…my-agent-task-always-succeeds-in-suspicious-ways` tripped it. Added a `(^|[^A-Za-z0-9_-])` guard so a match must start at line-start or after a non-word/non-hyphen char; the other patterns (`ghp_`/`github_pat_`/`AKIA`/PEM) are distinctive enough to leave unguarded, and real `sk-…` keys (after `=`/space/quote/`:`) still match. (2) The scan grepped the ENTIRE passed dir, so pre-existing merged content permanently blocked all future note-logs of that dir (the journal dir is the standard synthesis-pass target — worked around by hand each pass). The scan now runs on the EXACT set git STAGES in the commit worktree (`git diff --cached -z --name-only` in the same dedicated worktree the push uses, created off the freshly fetched `origin/$BASE_BRANCH`) — a file unchanged vs base stages nothing, so a pre-existing merged file is simply not in the set. Scanning the staged index (rather than reconstructing a working-tree-vs-base diff) makes the scanned set == the committed set by construction: no stale-base skew (we hold the fetched base) and no ignore-rule skew (the worktree's index under the base tree's `.gitignore` decides what is staged, not the possibly-dirty checkout) — the two scan/commit-divergence holes a first-cut diff-scoping approach left open. Paths are read NUL-delimited (`-z` / `read -d ''`) so a newline / quote / non-ASCII filename is scanned RAW rather than git-quoted-and-skipped (a scan bypass otherwise). A `stage_worktree` helper is shared by `--dry-run` (stages off the local base, no tokens/network, runs the identical staged scan, then stops — so dry-run validates the actual gate) and the real push path; a missing base ref or an empty staged delta fails CLOSED (refuse to log) rather than scanning something other than the commit. Note+design-stage gates only; the experiment gate does not scan. Also fixes a latent `set -e` bug the rework surfaced: `git diff --cached --quiet && die` as a function's last statement returned non-zero on the normal has-a-diff case and would have exited the caller before commit — rewritten as an explicit `if`. Adds an offline `log_experiment_secret_scan_smoke.sh` (run by `.aar-ci/checks.sh` when the script or smoke changes) driving the real script via `--dry-run` over git fixtures: unchanged pre-existing page passes, new/modified real key blocks, the hyphenated `sk-` phrase is not a false-positive, a non-ASCII staged path is scanned+blocked, missing base ref fails closed, and empty-delta refuses on nothing-to-commit.
- experiment-lifecycle 0.3.16 (2026-07-02): make the design-stage `log-experiment` merge MANDATORY before dispatch for pre-registered experiments (#304). `design-experiment` Step 4 previously called landing the pre-registration "optional" ("Landing the pre-registration (optional)"; "Whether/when this is required … is the instance's push policy, not mandated here"), which contradicted the two-PR flow that `log-experiment` (design-stage classification: `DESIGN.md` + `DESIGN_AUDIT*.md`, no `RESULTS.md`) and `run-experiment` (close-stage `log-experiment` requirement) already implement — so a design-side agent could clear the cross-family design-audit and still never land/merge the design PR. That optional block is replaced with a mandatory dispatch gate, reordered BEFORE the kickoff: once the researcher clears the design, run `log-experiment.sh <registry-dir>` to land the design-stage PR, and do NOT dispatch the executor until that PR is merged. Wording distinguishes the **design-audit** (the scientific / data-trustability cross-family review) from the **`log-experiment` design-stage PR** (the GitHub merge path that reuses that audit as its review record — it does not re-run the science). The gate is stated substrate-neutral (Claude, Codex, or other) since per #70 there is no separate per-family Codex wrapper — the Codex-facing surface is this shared SKILL.md — so a Codex-family design agent reads the same mandatory instruction; genuinely exploratory designer-driven work that is never dispatched is carved out. Docs-only edit to `plugins/experiment-lifecycle/skills/design-experiment/SKILL.md`.
- verify-claims 0.7.11 (2026-07-01): substrate-derived cross-family auditor selection (#262, #239). `audit_experiment.sh` now DERIVES the auditor from `AAR_SUBSTRATE` (the family that ran the work; REQUIRED — fails closed if unset/unknown, matching `log-experiment`, so a wrong default can't make the audit same-family) and the auditor is always the OPPOSITE family with a correct built-in default for BOTH families. `AUDIT_VERIFIER_CMD` is now an OVERRIDE honored ONLY when it is a different family than the runner; a same-family value — including an instance `BASH_ENV` that re-injects `AUDIT_VERIFIER_CMD=claude` into every non-interactive shell (#262) — is ignored with a warning and the opposite-family default is used, so the audit can never silently run same-family and the legitimate case never dead-ends on a `BLOCKED` the caller can't clear. Both built-in defaults run the auditor in the experiment dir (the codex default via `--cd`, the claude default via a `cd "$EXP"` subshell so the script's own cwd and relative `$OUT` path are unaffected) and capture the answer to `"$OUT_TMP"` (#239: a custom `claude -p` without the `> "$OUT_TMP"` redirection wrote to the run log and the harness failed closed with "auditor produced no findings file"; code-review HIGH: the claude default must also run in `$EXP` or it audits the wrong tree). Built-in defaults now execute as DIRECT argv (no `eval`) so a hostile `$EXP` path can't inject shell (code-review HIGH); `eval` is reserved for the explicit `AUDIT_VERIFIER_CMD` override, whose contract is a caller-owned shell command line. The `AUDIT_PRINT_VERIFIER` seam also prints `OUT_TMP` so the smoke asserts the claude default's EXACT redirect target. Adds an `AUDIT_PRINT_VERIFIER` seam + an offline `cross_family_verifier_smoke.sh` (run by `.aar-ci/checks.sh` when the script or smoke changes) covering self-correct-to-codex, the codex→claude `$OUT_TMP` default, override-honored, and fail-closed-on-unset/unknown. Not in this PR: #231 (re-add the disposition-injection smoke) — #279 moved the disposition-aware injection out of this repo into agentic-engineering's verify-claims, so that smoke belongs there, not in `plugins/verify-claims`. (#287.)
- verify-claims 0.7.10 (2026-06-30): trim the SWE-review modes (`--scaffold`/`--code`) out of the product's verify-claims, leaving it experiment-audits-only (`verify_claim`, `--design`, `--data`, close). Those modes now live in agentic-engineering's verify-claims; after agentic-engineering #7 (Phase 3b PR1), ship-change sources its SWE reviewer from there (base-ref materialized, judged against the target repo's `AGENTS.md`), so the product's copy was unused. Removes the scaffold/code mode-parse, input-handling, strict-`AAR_SUBSTRATE` enforcement, constitution branch, the two PROMPT blocks, and the now-dead disposition-aware merge-gate block; updates SKILL.md, the plugin/marketplace descriptions, and `AGENTS.md` (verify-claims here is experiment-audit-only; the canonical SWE reviewer is agentic-engineering's). `verify_claim.sh` + `audit_data.py` unchanged. A stray `--scaffold`/`--code` arg now fails closed via the existing context-dir guard. Symmetric agentic-engineering→SWE-only trim tracked in agentic-engineering #8. (Phase 3b PR2, #279.)
- experiment-lifecycle 0.3.3 (2026-06-28): relaunch-supervisor first-cut polish — the 3 merge-gate findings from #170/#186 (#188). (1) `RELAUNCH_SUPERVISOR.md`'s decision tree now folds `clear-relaunch` INTO the `relaunch(run)` expansion so a relaunch clears its driving request on EVERY branch (was asymmetric: the crash/session-gone branch left a pending request to re-trigger next pass; `clear-relaunch` is idempotent so the crash-with-no-request case is a harmless no-op). (2) `run_supervision_record.sh request-relaunch` now REQUIRES a bound `handoff_path` — pass `--handoff PATH` to bind it atomically with the request, or it must already be on the record; fails closed (exit 4, no write) otherwise — because `request-relaunch` is the can't-resume-in-place signal whose successor fallback (`launch_successor`) needs the handoff to point the fresh successor at (a "recover me" with nothing to recover from is now refused, not silently accepted). (3) `design-experiment`'s `START_TEMPLATE.md` / `CHECKLIST_TEMPLATE.md` now bind `--session-handle <opaque>` in the generated `create` call and name the dispatch/launcher as the resolver of that placeholder, with a CHECKLIST evidence requirement that it be resolved to a concrete instance value (not left literal) — so a normally-generated brief binds a probeable run-id→session handle by default. Also documents `request-relaunch [--handoff P]` + the bound-handoff rule at its canonical points of need (the `RELAUNCH_SUPERVISOR.md` record-API table and `run-experiment` `SKILL.md` resume-contract prose), and extends the helper smoke with the finding-2 coverage. Contract/docs + one strictly-more-restrictive helper guard; no new state or subcommands.
- experiment-lifecycle 0.3.2 (2026-06-28): the model-free relaunch supervisor — crash/exit + explicit-marker first cut (#54 child 3). Adds the supervisor's side of the crash-resilience contract as a substrate-neutral reference (`run-experiment/references/RELAUNCH_SUPERVISOR.md`): the desired-state gate (relaunch only a run that is desired-active, not stopped, not closed — never resurrect a deliberate `/quit` or a finished run), the two reliable failure signatures (a process exit the in-pane loop can't catch; an agent-declared needs-relaunch request), the decision tree (`resume_same_session` else `launch_successor(handoff_path)`), single-writer lock + idempotence + crash-storm cap, and the explicit non-inclusion of silent-wedge detection (the separate #54 `needs-design` child). The needs-relaunch signal lands as first-class atomic state on child 1's `run_supervision_record.sh` (a `request-relaunch`/`clear-relaunch`/`is-relaunch-requested` API, fail-closed on a terminal/missing/corrupt record and auto-cleared by stop/close) rather than a parallel on-disk marker (design-review HIGH: it is machine-consumed relaunch state naming the same `handoff_path`), plus an opaque, instance-owned `session_handle` field (the substrate-neutral run-id→session binding the supervisor needs; design-review MED). The concrete command mapping (`--continue`, `relaunch-session.sh`), `session_is_alive` probe, systemd/bash wiring, and the dry-run rollout window stay instance (NOT this repo), per the #54 blast radius.
- experiment-lifecycle 0.3.1 (2026-06-27): document the "notifier ≠ recovery" clarification in run-experiment's resume contract (#54 child 4). A `StopFailure`-style hook may fire on an API-error exit to push-notify / wake the model-free supervisor (and drop child 3's needs-relaunch marker where it exists), but it cannot itself resume the session — it runs after the process is gone, so recovery stays the supervisor's job (`resume_same_session` / `launch_successor`). Guards against a future reader wiring the hook expecting recovery and silently reintroducing the #54 gap. Docs-only; the API-timeout settings + concrete hook command are instance config (NOT this repo), per the #54 blast radius. Does not invent a marker API — the needs-relaunch marker's contract belongs to child 3.
- gpu-job 0.2.0 (2026-06-27): add the pod LEASE + the box-level model-free REAPER (#54 crash-resilience child 2 / #169). `scripts/pod_lease.sh` is a deletion-scoped per-pod lease written across acquire in three phases — intent (a `gpujob-<hex>` nonce + the durable `API_KEY_ENV` key reference + a short default expiry, written BEFORE deploy and used as the pod name so even a created-but-id-never-returned pod is covered), provisional (bind the real pod id), enriched (SSH endpoint + the run's real expiry) — with atomic writes + a per-lease lock, a fail-closed write-failure path in `deploy_pod.py` (synchronous DELETE / emergency record, never a silent un-leased orphan), and `close` only after `teardown.sh` verifies the pod gone. `scripts/pod_reaper.sh` is the standing reaper: it deletes ONLY registered+expired leases under each lease's lock (so a concurrent `refresh` can never be raced into a wrongful reap), resolves keys + lists pods + does the matched-key delete-verify in the product (the `API_KEY_ENV` seam), REPORTS-never-deletes unknown/ambiguous/unresolved-key pods, honors a legacy contract-1 pod-side keepalive (future=keep, inconclusive-read=report-and-retry NOT delete, past=reap), and has a `--dry-run`. Lease wiring is opt-out (`GPU_JOB_LEASE_DISABLE=1`); registry at `${GPU_JOB_LEASE_DIR:-~/.config/gpu-job/leases}`. SKILL.md documents the lease/reaper + the standalone-refresh requirement; `.aar-ci/checks.sh` runs the two new offline smokes. Instance owns only the secret values + the reaper schedule.
- aar-engineering 0.3.28 (2026-06-27): fix the `wf.sh finish` close-gate PR-body refresh to select the PR's OWN design doc instead of `head -1` of the `proposals/` diff. On a mass-rename PR that moves many docs, `head -1` picked an unrelated `proposals/10-*.md` and rewrote the body to `Closes #10` (not a `ready` issue), tripping the close-gate. The refresh now parses the branch's issue number (`change/<issue>-<slug>`) and prefers the changed doc named for it, falling back to the first changed doc only when none matches; the no-match lookup is `set -e` safe (`|| true`). Precursor that unblocks #65; the rename itself is out of scope here.
- feedback-loop 0.1.0 (2026-06-27): add product `file-feedback` and `triage-feedback` skills. Product feedback now has an installable home: agents route reusable scaffold friction to a configured product Issue tracker through the engineer-safe `wf.sh issue -R <repo>` path when available, and deployment-only notes are drafted through a single instance-guidance pointer instead of hardcoded local files. Includes `feedback_loop_init.sh`, marketplace/README install docs, packaged disposition references, lifecycle fallback wording, and a CI check that the duplicated init scripts stay identical.
- experiment-lifecycle 0.2.3 (2026-06-27): update experiment close/checklist feedback wording to use feedback-loop when installed and otherwise route through consuming-instance guidance, removing the old assumption that every install has Anton's local gotcha/backlog files.
- automated-researcher (2026-06-26): rename current product-facing docs and marketplace namespace from `aar-skills` to `automated-researcher`. README install examples, root marketplace metadata, AGENTS.md heading, `.aar-ci` author-facing labels/checks, and ship-change refresh/help text now use the new canonical name. Adds a deterministic check that README `plugin install <plugin>@...` examples match `.claude-plugin/marketplace.json:name`.
- docs (2026-06-19): clarify Codex skill setup after the wrapper audit. Codex should symlink the canonical source
  skills, with `ship-change` added only for scaffold developers; local Codex wrappers remain optional thin instance
  conveniences, not product source.
- aar-engineering 0.3.9 (2026-06-18): make the ship-change GitHub trail easier to skim. PR bodies now show a short reader view from the proposal's Problem and Approach sections, with the full design record under details. Review and classification comments now start with a plain-language result and keep the dense audit or classifier output under details. Author-triage guidance now says to start with the outcome in plain language while keeping accept/defer decisions visible.
- experiment-lifecycle 0.2.2 (2026-06-18): pin the autonomous executor substrate boundary. The dispatch contract now requires any autonomous detached executor to be able to arm its own independent recurring self-wake; tool-spawned Claude Agent subagents are documented as acceptable only for short controller-supervised probes, not long detached executors. The checklist self-wake gate now requires the independent waker/backstop id as evidence and treats an in-process monitor alone as FAIL for autonomous detached runs.
- aar-engineering 0.3.7 (2026-06-18): add symmetric engineer identity seams to ship-change. `WF_ENGINEER_TOKEN_CMD_CLAUDE/CODEX` and `WF_ENGINEER_GIT_AUTHOR_CLAUDE/CODEX` let Claude and Codex author through family bot identities when configured; `WF_REVIEWER_TOKEN_CMD` remains a legacy Codex-token alias. Review posting routes to the opposite-family identity, hardcoded bot-name prose is genericized, and unenforced installs keep ambient/comment fallback unless `WF_REQUIRE_ENGINEER_IDENTITY=1` (authoring) or `WF_REQUIRE_NATIVE_REVIEW=1` (final merge gate) is set.
- gpu-job 0.1.5 (2026-06-12): restore API_KEY_ENV indirection across deploy_pod.py / teardown.sh / watchdog.sh — names the env var holding the RunPod key (default RUNPOD_API_KEY). Regression in the 0.1.x extraction dropped the knob; a sourced .env exporting the personal RUNPOD_API_KEY silently deployed a research pod to a personal account, and teardown with the other account's key 404'd (masqueraded as deleted; ~$7 idle burn). Multi-account instances: set API_KEY_ENV in ~/.config/gpu-job/env.
- gpu-job 0.1.6 (2026-06-15): add `alive_check <output-file> <staleness-min>` to job_lib.sh — mtime-based positive-progress liveness probe. Replaces the `pgrep -f <token>` liveness pattern that self-matches the probing shell (≥6 incidents across the fleet: masked-dead jobs, killed own ssh sessions, never-exiting relaunch loops) and that reads a hung-but-not-exited process as alive. Pair with kill_tree for kills (never `pkill -f`).
- verify-claims 0.4.0 (2026-06-16): add audit_experiment.sh --data — the DATA rung of the cross-family audit ladder (facts→logic→data→evidence). A foreign model reads a STRATIFIED high-risk sample (longest/shortest/per-source/per-arm/near-cap/truncated rows) against a design-intent manifest and asks 'would this data make the experiment invalid or misleading?' — the semantic layer a script can't do. Pairs with the deterministic full-pool layer (orchestrator pipelines/eval/audit_data.py: counts/truncation/finish_reason/schema/dupes/balance + the sample). Motivated by the washout bug (generated replay froze clean while 1160/6457 rows were truncated mid-CoT; a 2-sample self-smoke missed it). Required for any new/generated/transformed data; N.A. for unchanged frozen artifacts. (plugin.json version was stale at 0.2.1 though the code had --design=0.3.0; corrected forward to 0.4.0.)
- verify-claims 0.4.1 (2026-06-16): SKILL.md body + description now document ALL FOUR modes (verify_claim + audit_experiment --design / --data / close) as the facts→logic→data→evidence ladder. The script had grown --design (0.3.0) and --data (0.4.0) but the skill that wraps it only described verify_claim + close — so two modes were undiscoverable from the skill. Doc-only.
- verify-claims 0.5.0 (2026-06-16): audit_data.py (the deterministic full-pool data-audit layer) MOVED into this plugin (was orchestrator/pipelines/eval/audit_data.py) — now `scripts/audit_data.py`, referenced relatively so it resolves on any install (was a hardcoded ~/orchestrator path in the skill body = a portability leak for outsiders). It pairs with --data: audit_data.py does counts/truncation/finish_reason/schema/dupes/balance on the full pool and emits the stratified sample --data reads. Migration piece 1 of design+audits → product (orchestrator keeps a symlink at the old path so instance refs/pod-bound scp still resolve). Also fixed a latent `--help` crash (bare `%` in a help string → argparse `incomplete format`). Description broadened: "verification gates, deterministic + cross-family."
- experiment-lifecycle 0.2.0 (2026-06-16): add the `run-experiment` skill — the zero-context EXECUTE half (genericized from the instance run-experiment). The execute protocol (autonomous-executor disposition, arm-self-wake-first, detached-driver topology, drive/collect/close, tear-down-on-block, standing data-audit, close audit) is now substrate-neutral, reading three seams: gpu-job (backend: deploy/helpers/watchdog/teardown), verify-claims (close audit + data audit), and an INSTANCE EXECUTION PROFILE (provisioning/recipes/artifact-store/ledger/teardown-key/cost-API policy — method-bearing, tracked, snapshotted into START.md). No RunPod/Qwen/workspace/orchestrator paths hardcoded; CronCreate/LOOK_AGAIN appear only as a labeled Claude-Code implementation example. experiment-lifecycle is now WHOLE (design + execute). Instance flip + fake-HOME proof (with a toy profile) gated next.
- verify-claims 0.6.0 (2026-06-16): add audit_experiment.sh --scaffold — cross-family DESIGN REVIEW for PRODUCT/scaffold change proposals (skills, conventions, migrations), the same harness as --design but with ARCHITECTURE dimensions (right seam, DRY/canonical-home, blast radius, reversibility, instance<->product leak, contract clarity, simplest-thing, convention-match) + a required plain-language-explanation check on the proposal. Reviews a proposal doc against the REAL tree (context = git root by default; F2). It's the design-review counterpart to /code-review on the resulting diff: architectural changes get --scaffold on the proposal BEFORE the build, then /code-review on the diff at PR time. Constitution loads from the CONTEXT repo's AGENTS.md and FAILS LOUD if empty (no toothless off-box review; F4). Dogfooded on its own proposal: Codex surfaced 4 real findings (2 HIGH/2 MED), all addressed. SKILL.md documents the mode.
- verify-claims 0.7.0 (2026-06-16): add audit_experiment.sh --code — cross-family review of a DIFF (implementation dimensions: correctness, edge-cases, regression, security, simplify), the code-review half of the SWE pipeline (--scaffold is the design half). Same cross-family harness: requires AAR_SUBSTRATE=author-family, reads the context repo's AGENTS.md, fails loud if absent. Context defaults to the CWD's git root (a diff is transient). Will be called by the ship-change pipeline at PR time. Self-reviewed via --code on its own diff (caught a real default-context bug — diff-dir vs CWD-repo — fixed before ship).
