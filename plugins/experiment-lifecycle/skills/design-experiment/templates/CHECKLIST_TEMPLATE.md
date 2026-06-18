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

## UNIVERSAL  (every GPU experiment)
- ☐ [BLOCK] Read DESIGN.md + START.md; design is locked (no redesign).                          ev:
- ☐ [BLOCK] Self-wake / idle-cost backstop armed PER SUBSTRATE before detached billable work.
      Autonomous detached runs MUST name the independent waker id/handle; any detached compute MUST name the
      idle-cost teardown backstop. An in-process monitor alone is FAIL for autonomous detached runs.
      (Claude: heartbeat cron + LOOK_AGAIN; Codex: blocking watcher + box-side idle-teardown watchdog).  ev:
- ☐ Read experiment_gotchas.md tail (a peer may have logged the wall you're about to hit).      ev:
- ☐ [BLOCK] R2 upload verified — EVERY unique artifact (adapter, eval summaries, rollout/sample
      logs, generated data, reproduce scripts), not just SUMMARY.md, BEFORE teardown.            ev: rclone lsf
- ☐ [BLOCK] RESULTS.md written + judged against the pre-registered DESIGN rules; conclusions
      separated from postdictions.                                                               ev:
- ☐ [BLOCK] Cross-family close audit run + every finding responded (ACCEPT/DISPUTE/DEFER).       ev: AUDIT.md
- ☐ [BLOCK] Teardown verified via the DEPLOYING account's control plane (REST 404 / GraphQL
      empty with the DEPLOY key — never SSH liveness); self-wake/watchdog cleared.               ev:
- ☐ Retro filed (gotchas + backlog + the GAPS below) via file-feedback.                          ev:

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

## EXPERIMENT-SPECIFIC  (designer writes these — the domain-knowledge part the executor can't invent)
- ☐ ...

## GAPS  (executor fills as you go — the design-feedback signal; too many = an under-pinned design)
- mechanical defaults I had to invent (the design didn't pin): ...
- load-bearing things I had to flag: ...
