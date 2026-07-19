# CHECKLIST — <exp>   (verification gates; protocol + annotated record in ONE file)
#
# THIS TEMPLATE IS A UNIVERSAL CORE + STANDING DATA AUDIT + A CONDITIONAL MENU, NOT A MANDATE.
# The checklist is the DESIGNER's to shape.
#
# DESIGNER (design-experiment): keep the UNIVERSAL and DATA AUDIT gates; instantiate the data-audit
#   surfaces for THIS experiment (training data, eval input data, eval rollouts). For each CONDITIONAL
#   gate either keep it — INSTANTIATING its declared invariant for THIS experiment — or mark it N.A.; then ADD the
#   EXPERIMENT-SPECIFIC gates (you know this experiment's failure modes; the executor can't invent them).
#   Different experiment types lean very differently: a training run uses most CONDITIONAL gates; a pure
#   interp/ROME run marks most N.A. and adds its own (e.g. "forward-hook removed after each pass",
#   "patch recipient == the reference map's checkpoint"); an eval-only run marks training-only gates N.A.
#   but still audits eval inputs and model-generated eval rollouts.
#   Prune and extend at your discretion — the template's value is the universal lifecycle gates + a
#   reminder-menu of the common conditional ones, so nothing standard is silently forgotten.
#
# EXECUTOR (run-experiment): resolve every [BLOCK] gate to exactly ONE end-state, with EVIDENCE:
#     ☑ PASS ev: <artifact path + numbers>     e.g. ev: training_data_audit.json open_think=0/8316 drops={}
#     ☑ N.A. ev: <why it doesn't apply>         CONDITIONAL gates only; DATA AUDIT has no N.A. loophole
#     ☒ FAIL ev: <what failed>                  → BLOCKS continuation; a FAIL is a LOAD-BEARING flag:
#                                                  notify the researcher, work around, proceed only if they
#                                                  clear a changed method. (Record the FAIL — don't delete it; the
#                                                  FAIL→fix→PASS history is the validity trail.)
#   Evidence is a number / output / path, NEVER a bare ✓. Tick in place. Commit at close; the cross-family
#   close audit verifies the checklist against the artifacts (which is what stops cargo-cult ticking).
#   A checklist FAIL is a VALIDITY-TRAIL term, distinct from ledger `technical-failure` (run-experiment
#   SKILL.md Step 4, #376) — it never by itself implies the ledger status is a failure.

## UNIVERSAL  (every GPU experiment)
- ☐ [BLOCK] Read DESIGN.md + START.md; design is locked (no redesign).                          ev:
- ☐ [BLOCK] Experiment CLAIMED before ANY GPU/API spend, per the instance's claim convention (checked no peer
      already owns the dir; wrote the claim marker — e.g. a `CLAIMED_BY` naming who/date/scope — and committed
      it path-scoped). The claim guardrail must fire BEFORE the first billable action, not at close.  ev: git log <claim-marker>
- ☐ [BLOCK] Self-wake / idle-cost backstop armed PER SUBSTRATE before any detached run or billable background work.
      Autonomous detached runs MUST name the independent waker id/handle; billable background compute MUST name the
      idle-cost teardown backstop; controller-supervised detached probes MUST name the supervising watcher/driver.
      Parking with only an in-process monitor is FAIL for autonomous detached runs; a blocking watcher that keeps the
      executor turn alive is controller-supervised, not autonomous detached.
      (Claude: heartbeat cron + LOOK_AGAIN; Codex: blocking watcher + the gpu-job lease as idle-teardown backstop).
      Same tick also owns the pod-lease refresh heartbeat for every live pod, gated on POSITIVE-PROGRESS
      evidence (or an active operator-declared `QUIET_PHASE.md`) — never raw busy/liveness alone, or a wedged
      hot-loop refreshes forever — with no-progress-and-no-marker surfaced loudly on the next wake rather than
      silently skipped; a healthy long run must never silently outlive its lease expiry (#293).      ev:
- ☐ [BLOCK] Resume contract armed (so a model-free supervisor can relaunch a dead run): standing successor
      handoff (`TEMP.md`) current; run-supervision record written and **desired-active** with a session handle
      bound (`run_supervision_record.sh start <run-id> --handoff <TEMP.md> --session-handle <opaque> --worktree
      <this worktree's path>`) — the `<opaque>` handle RESOLVED to a concrete instance value by the
      dispatch/launcher (a tmux name, systemd unit, pid-file path), NOT left as the literal placeholder, so the
      supervisor can find this run's session; `--worktree` is set by the executor itself, from inside its own
      worktree, at start — the run-id<->worktree binding `reap_worktree.sh` checks at close; live pod ids checkpointed (`run_supervision_record.sh checkpoint <run-id> --handoff <TEMP.md> --lease-pod <id>`)
      and EACH live pod registered for reaping via the `gpu-job` pod lease (the sole backstop since the
      per-pod watchdog was retired, #266) AND kept fresh by the self-wake heartbeat above for as long as the run
      is actively driven.                                                                      ev: run_supervision_record.sh status <run-id>
- ☐ Read the consuming instance's feedback/gotcha guidance, or the `FEEDBACK_INSTANCE_GUIDANCE`
      target when using feedback-loop (a peer may have logged the wall you're about to hit).      ev:
- ☐ [BLOCK] R2 upload verified — EVERY unique artifact (adapter, eval summaries, rollout/sample
      logs, generated data, reproduce scripts), not just SUMMARY.md, BEFORE teardown.            ev: rclone lsf
- ☐ [BLOCK] RESULTS.md written — describes the data (numbers / plot) per the DESIGN spec; any
      lightweight qualitative read stays separable from the numbers (no pre-registered verdict). If
      RESULTS does assert a claim, conclusions are separated from postdictions.                  ev:
- ☐ [BLOCK] presentation_manifest.json written next to RESULTS.md — unconditional, config-free.
      Required {title, labels}; figures/datasets all-optional, populated per the DESIGN.md
      Presentation subsection (no unconfigured-viewer exception — write it regardless).           ev:
- ☐ [BLOCK] Viewer publish leg resolved per the START.md profile snapshot (#347) — MECHANICAL bar only;
      exactly ONE of three end-states, each with evidence (never silently skip):
      (a) PUBLISHED — snapshot carries a `[recipes.viewer]` pointer: pinned figures rendered per the DESIGN.md
          Presentation spec, per-experiment page SOURCE (build/assemble scripts + manifest) committed to the
          viewer repo, page + gallery landed via the recipe's gated path (page prose is a first-pass draft —
          its quality is NOT this gate's bar), AND the gallery-rebuild command actually RUN with the new page
          VERIFIED PRESENT in the built output (not just rendered) — never just the named step.
          ev: landed PR/commit + committed source paths + page URL + rebuild command run + grep/fetch showing
              the experiment's slug listed in the built index/gallery
      (b) NO RECIPE — no `[recipes.viewer]` in the snapshot; manifest-only close.  ev: "no [recipes.viewer] in snapshot"
      (c) RECIPE INCOMPLETE — pointer present but the recipe is missing required contents (repo+landing path,
          page lib+prior page, commands, source destination): a load-bearing brief-gap flag, NOT a blocked
          close — notify the designer-of-record, close manifest-only, record it in GAPS. This is a recorded
          PASS end-state (the close proceeds), never recorded as (b).
          ev: "recipe incomplete: missing <items>; flagged <where>; manifest-only"
- ☐ [BLOCK] Ledger's folded/latest status is TERMINAL (`done`/`failed`/`killed`, or the instance's
      ledger recipe's terminal set) — not just that a launch event exists somewhere in its history. Never
      backfill a `running`/`launched`/`deploying` event after a terminal one: a last-non-null-field-wins
      fold reopens a finished run for every consumer (dashboards included) even though the run is actually
      done (`automated-researcher#338`). Missing launch metadata at this point is a non-status note or a
      fresh terminal-status event — never a non-terminal one. **The value reflects OPERATIONAL run health,
      not a verdict** (run-experiment SKILL.md Step 4, #376) — a `FAIL` elsewhere on this checklist never by
      itself justifies the recipe's technical-failure value.                                      ev:
- ☐ [BLOCK] Cross-family close audit run + every finding responded (ACCEPT/DISPUTE/DEFER).       ev: AUDIT.md
- ☐ [BLOCK] Teardown verified via the DEPLOYING account's control plane (REST 404 / GraphQL
      empty with the DEPLOY key — never SSH liveness); self-wake cleared.                         ev:
- ☐ [BLOCK] Run-supervision record close READY (NOT cleared early): the record exists and the close path is
      durably in charge, so the desired-active clear is the POST-AUDIT finalizer. Then run that finalizer —
      `run_supervision_record.sh close <run-id>` (finished) or `stop <run-id>` (deliberate /quit, never
      relaunch) — AFTER the close audit, so a finished run can't be resurrected and an early clear can't
      orphan a still-billing pod.                                                                 ev: run_supervision_record.sh status <run-id>
- ☐ [BLOCK] Workspace teardown READY (own worktree, NOT removed early, automated-researcher#532): R2 upload
      verified (above) AND log-experiment has merged the record — the same two gates that make `git worktree
      remove --force` safe (untracked executor scratch would otherwise be lost). `reap_worktree.sh` also
      requires the record's own `worktree_path` bound at `start` (the Resume contract gate above) — the actual
      run-id<->worktree binding, so a clean-closed run-id can only ever reap the worktree IT bound, never a
      peer's. Then run the finalizer — `cd` OUT of the worktree first, `reap_worktree.sh <run-id>
      <worktree-path>` (fires only on a clean close via the same `is-closed` guard; branch ref kept) — right
      before session reap. N.A. only if this run was never given its own dedicated worktree.       ev: git worktree list
- ☐ Retro filed via feedback-loop's file-feedback when installed/configured; otherwise recorded
      through the consuming instance's feedback guidance.                                         ev:

## DATA AUDIT  (STANDING — not conditional; every experiment touches data)
- ☐ [BLOCK] Audit/resolve EVERY data surface class — **(a) training data, (b) eval input data,
      (c) the model-generated eval ROLLOUTS** (the model's eval output the grader reads — where the
      parse / truncation / empty-`<think>` / grader-failure bugs live; "read the rollouts, not the scalar").
      If a surface is absent by design, record that explicit absence as evidence, not N.A.
      Two layers, BEFORE trusting any number:
      (1) **deterministic full-pool** — the `verify-claims` skill's `audit_data.py <surface>.jsonl [--cot] [--require-finish-reason] ...` on
          EACH surface — ALWAYS (cheap script: truncation/schema/dupes/empties/balance + a stratified
          high-risk sample; exit 2 = HARD FAIL → fix before proceeding);
      (2) **cross-family SEMANTIC** — the `verify-claims` skill's `audit_experiment --data <exp> <manifest>` on EACH surface vs the design
          intent → respond to every finding. **NO N.A. — always audit all three.** The eval ROLLOUTS especially
          are audited EVERY run (they're generated fresh, never frozen); re-reading even a fixed eval-input set
          is cheap and not worth a loophole.                                                     ev: data_audit*.json + DATA_AUDIT.md

## CONDITIONAL  (keep + instantiate the invariant for THIS experiment, or ☑ N.A. with a reason)
- ☐ [BLOCK] Full input/training-data samples READ (actual text, not aggregates): masking, format,
      leakage, length all sane.                                                                   ev:
- ☐ [BLOCK] Cheapest REPRESENTATIVE smoke passed for any NEW code / dataset / save-load path
      (first-batches, or a small-model path) before the real run — no OOM / format / save error.  ev:
- ☐ [BLOCK] Anchor-gate: the base/reference reproduces its standing value (and any loaded released
      checkpoint matches its published numbers) BEFORE pooling or comparing.                      ev:
- ☐ [BLOCK] Compared arms co-measured in ONE serving session; the canonical grader on EVERY
      decision cell (no cheap-grader on a reported/decision cell).                                ev:
- ☐ Full eval rollouts READ (actual text): grader / parse / truncation / think-length all sane.   ev:
- ☐ Decoding config (temperature/top_p/max_new_tokens/seed/sampling mode) PERSISTED in the rollout
      artifacts (each row or a companion summary) and CONSISTENT across co-measured arms — verifiable from
      the artifacts, not only from driver source.                                                  ev:

## EXPERIMENT-SPECIFIC  (designer writes these — the domain-knowledge part the executor can't invent)
- ☐ ...

## GAPS  (executor fills as you go — the design-feedback signal; too many = an under-pinned design)
- mechanical defaults I had to invent (the design didn't pin): ...
- load-bearing things I had to flag: ...
