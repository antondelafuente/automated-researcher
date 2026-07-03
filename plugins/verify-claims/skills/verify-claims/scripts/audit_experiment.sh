#!/bin/bash
# audit_experiment.sh — independent, cross-family adversarial AUDIT of a completed experiment.
#
# Sibling to verify_claim.sh. Where verify_claim CHECKS a given list of claims (input-side gate,
# pre-launch), this GENERATES findings about a finished experiment (output-side gate, at close).
# It audits the experiment dir AGAINST the AAR's own constitution (AGENTS.md) + a validity rubric,
# run by a DIFFERENT model family than the agent that produced the work — because an agent cannot
# reliably catch its own reproducibility gaps, overclaims, or confounds, but a foreign reader can.
#
# Cross-family is the whole point and is guaranteed BY CONSTRUCTION: set AAR_SUBSTRATE to the family
# that RAN the experiment (REQUIRED — no default; a wrong default must not make the audit same-family,
# matching log-experiment.sh) and the auditor is ALWAYS the opposite family. Both families have a correct
# built-in default verifier, so normally you set nothing else. AUDIT_VERIFIER_CMD is an OVERRIDE honored
# only when it is a DIFFERENT family than the runner; a same-family value — a misconfig, or an instance
# BASH_ENV that re-injects AUDIT_VERIFIER_CMD into every non-interactive shell (issue #262) — is IGNORED
# with a warning and the opposite-family default is used, so the audit can never silently run same-family
# and the legitimate case never dead-ends on a block the caller can't clear.
#
# Validated 2026-06-12: from a cold read of a pre-fix experiment state, Codex independently
# rediscovered all three findings a human had routed to ChatGPT (repro gap, in-sample steering,
# claim overreach) PLUS two more, with zero false findings. Hardened 2026-06-12 (audit-the-auditor):
# stale-output guard, cross-family enforcement, DATA SANITY dimension, durable-vs-committed wording.
#
# Usage: audit_experiment.sh <experiment-dir> [out-file]              # close-side (post-hoc) audit
#        audit_experiment.sh --design <experiment-dir> [design-file] [out-file]   # PRE-LAUNCH design audit
#        audit_experiment.sh --data <experiment-dir> [manifest] [out-file]        # MID-RUN data audit
# This is the PRODUCT's experiment-audit engine (--design / --data / close). The SWE-pipeline review modes
# (--scaffold / --code) live in agentic-engineering's verify-claims; ship-change sources its reviewer from
# there (base-ref materialized), so they are intentionally NOT here.
# --data audits the ACTUAL generated/transformed data against the design intent (the 'facts→logic→
#   DATA→evidence' ladder): the deterministic full-pool layer is `pipelines/eval/audit_data.py`
#   (counts/truncation/schema/dupes/balance → data_audit*.json + a stratified high-risk sample); this
#   mode is the SEMANTIC layer — a foreign model reads the SAMPLE rows + the manifest's intent and asks
#   "would this data make the experiment invalid or misleading?" Motivated by the washout truncation bug
#   (a generated replay froze clean while 1160/6457 rows were truncated mid-CoT; a 2-sample smoke missed it).
#   experiment-dir: the ~/orchestrator/<exp>/ dir to audit (read-only; the auditor sees its files)
#   out-file:       findings destination (default: <experiment-dir>/AUDIT.md, or DESIGN_AUDIT.md in --design mode)
#   design-file:    (--design mode) the proposal to audit; default = newest DESIGN*.md in the dir
# --design audits the PROPOSAL's DATA-TRUSTABILITY before any money/GPU moves (third gate alongside
# verify_claim pre-launch and the close audit): will it produce reliable, comparable data for its stated
# purpose? comparability/co-measurement, confounds that corrupt the number, variable-pinning, anchor
# reproduction, cheaper-decisive alternatives. Claim-rigor (decision rules, claim-scope, power) is audited
# ONLY if the design asserts a verdict — measurement designs state a purpose, not a claim. Motivated by
# midtrain-interp v2, whose two real flaws (in-sample steering eval; no random-direction control)
# were DESIGN flaws only caught at close. Dimension 7 (SCHEDULE EFFICIENCY, #311) is motivated by the
# 2026-07-03 hereditary-ccp-platform incident: a DESIGN.md declared serial-overnight Tinker training "the
# cheap default" for 15 LoRA runs on a false per-wallclock premise — Tinker bills per training compute, so
# 14 parallel submissions cost the same as 14 serial ones — caught only by the researcher in conversation
# after the design had already passed this same audit; wall-clock ETA dropped ~2-4 days to ~1 day at zero
# cost delta.
# Env: AAR_SUBSTRATE=claude|codex (family that RAN the exp; REQUIRED — fails closed if unset/unknown so a
#                                  wrong default can't make the audit same-family; auditor = opposite family)
#      AUDIT_VERIFIER_CMD=...      (OVERRIDE the auditor; honored only if a DIFFERENT family than the runner,
#                                  and it MUST write its final answer to "$OUT_TMP" — see the built-in defaults.
#                                  A same-family value is ignored (warn) + the opposite-family default is used.)
#      AUDIT_CONSTITUTION=path     (the standards file; default ~/AGENTS.md)
set -euo pipefail
MODE=close
if [ "${1:-}" = "--design" ]; then MODE=design; shift;
elif [ "${1:-}" = "--data" ]; then MODE=data; shift; fi
EXP=${1:?usage: audit_experiment.sh [--design|--data] <experiment-dir> [args...]}
if [ "$MODE" = design ]; then
  DESIGN_FILE=${2:-$(find "${EXP%/}" -maxdepth 1 -type f -name 'DESIGN*.md' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2-)}
  [ -n "$DESIGN_FILE" ] && [ -f "$DESIGN_FILE" ] || { echo "BLOCKED: no design file found in $EXP (pass one explicitly)" >&2; exit 1; }
  OUT=${3:-${EXP%/}/DESIGN_AUDIT.md}
elif [ "$MODE" = data ]; then
  MANIFEST=${2:-$(find "${EXP%/}" -maxdepth 1 -type f \( -name 'data_audit_manifest*.md' -o -name 'DESIGN*.md' \) -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2-)}
  [ -n "$MANIFEST" ] && [ -f "$MANIFEST" ] || { echo "BLOCKED: no manifest/design-intent found in $EXP (pass one explicitly) — the auditor needs to know what the data SHOULD be" >&2; exit 1; }
  if ! find "${EXP%/}" -maxdepth 1 -type f -name '*data_audit*.json' | grep -q .; then
    echo "WARN: no data_audit*.json in $EXP — run pipelines/eval/audit_data.py first (layer 1) so the semantic audit has the deterministic report + the stratified sample" >&2
  fi
  OUT=${3:-${EXP%/}/DATA_AUDIT.md}
else
  OUT=${2:-${EXP%/}/AUDIT.md}
fi
[ -d "$EXP" ] || { echo "BLOCKED: context/experiment dir missing: $EXP" >&2; exit 1; }

# --- cross-family auditor selection (guaranteed by construction; #262 / #239) -------------------
# RUNNER_FAMILY is the family that RAN the experiment (AAR_SUBSTRATE — REQUIRED, no default: a wrong
# default must not make the audit same-family, matching log-experiment.sh). The auditor is ALWAYS the
# opposite family; its built-in default verifier is assembled below (after $OUT_TMP exists).
RUNNER_FAMILY=${AAR_SUBSTRATE:-}
case "$RUNNER_FAMILY" in
  claude) AUDITOR_FAMILY=codex ;;
  codex)  AUDITOR_FAMILY=claude ;;
  *) echo "BLOCKED: AAR_SUBSTRATE must be claude|codex (got '${RUNNER_FAMILY:-<unset>}') — set it to the" >&2
     echo "  family that RAN the experiment so the auditor is the OTHER family. Fail closed rather than" >&2
     echo "  default to a family and risk a silent same-family audit." >&2
     exit 1 ;;
esac
# AUDIT_VERIFIER_CMD is an OVERRIDE, honored ONLY when a DIFFERENT family than the runner. A same-family
# value — a misconfig, or an instance BASH_ENV re-injecting AUDIT_VERIFIER_CMD into every shell (#262) — is
# IGNORED (warn) and the opposite-family built-in default is used, so the audit can never silently run
# same-family and the legitimate case never dead-ends. A custom (neither-claude-nor-codex) command is
# trusted as a deliberate third-family escape hatch (it can never equal the runner family).
VERIFIER_OVERRIDE=""
if [ -n "${AUDIT_VERIFIER_CMD:-}" ]; then
  case "$AUDIT_VERIFIER_CMD" in
    *claude*) OVERRIDE_FAMILY=claude ;; *codex*) OVERRIDE_FAMILY=codex ;; *) OVERRIDE_FAMILY=custom ;;
  esac
  if [ "$OVERRIDE_FAMILY" = "$RUNNER_FAMILY" ]; then
    echo "[audit_experiment] WARN: ignoring same-family AUDIT_VERIFIER_CMD (family=$OVERRIDE_FAMILY == runner)" >&2
    echo "  — likely a misconfig or an instance BASH_ENV re-injection (#262); using the built-in $AUDITOR_FAMILY auditor." >&2
  else
    VERIFIER_OVERRIDE=$AUDIT_VERIFIER_CMD
    [ "$OVERRIDE_FAMILY" = custom ] && AUDITOR_FAMILY=custom
  fi
fi

CONSTITUTION=${AUDIT_CONSTITUTION:-$HOME/AGENTS.md}
CONSTI_TEXT=""
[ -f "$CONSTITUTION" ] && CONSTI_TEXT=$(cat "$CONSTITUTION")
if [ "$MODE" = data ]; then
  DATA_REPORTS=$(find "${EXP%/}" -maxdepth 1 -type f -name '*data_audit*.json' -printf '%f\n' 2>/dev/null | sort | tr '\n' ' ')
  DATA_SAMPLES=$(find "${EXP%/}" -maxdepth 1 -type f \( -name '*data_audit*_sample.jsonl' -o -name '*data_audit*sample*.jsonl' \) -printf '%f\n' 2>/dev/null | sort | tr '\n' ' ')
fi

if [ "$MODE" = design ]; then
PROMPT="You are an INDEPENDENT ADVERSARIAL REVIEWER from a different model family than the agent that
wrote this experiment PROPOSAL. Nothing has been run yet; your job is to find the flaws BEFORE money
and GPU time move. The proposal under review is: $(basename "$DESIGN_FILE") (in the current directory).
Read it in full; read other files in the dir tree for context (prior RESULTS*.md, AUDIT.md, code)
— prior experiments' flaws often reveal what the new design must control for. IGNORE operational/state
files (LOOK_AGAIN.md, *.log, driver logs, CLAIMED_BY, .done markers): they describe the RUN's status, not
the design — never raise a finding from them (e.g. 'the run already launched' is not a design flaw).

An experiment's job is to produce TRUSTWORTHY DATA for a stated purpose; INTERPRETATION ('what does it
mean') is the researcher's SEPARATE step, done afterward by looking at the data. So this audit checks
DATA-TRUSTABILITY, not interpretation-rigor. A measurement design states a PURPOSE ('what the data is
designed to inform') but pre-registers NO verdict, decision rule, or falsifier — and that is CORRECT, not
incomplete: do NOT flag a measurement design for 'missing success criteria / decision rules / power
analysis.' Review against the program's constitution (below). The most load-bearing standard: validity and
comparability ('are these two numbers even on the same scale?'); the silent failure mode is a clean pipeline
producing a confidently-wrong NUMBER.

Audit these dimensions. For each, try HARD to find a real problem; if there genuinely is none, say
'no material finding' for it — do NOT invent issues. False findings destroy this tool's value.
1. VALIDITY / COMPARABILITY (lead) — will any two numbers being compared be on the same scale, same metric,
   same data distribution, co-measured? Any train/eval leakage, probe contamination, or selection effect
   built into the construction? Does the anchor / baseline reproduce?
2. CONFOUNDS THAT CORRUPT THE NUMBER — are the planned comparisons matched; are the baselines and negative
   controls (random/orthogonal/shuffled class, placebo arms) IN THE PLAN, not deferred? Is a nuisance
   variable (descriptor/length/format) confounded with the signal?
3. VARIABLE-PINNING & HONEST REPORTING — is the independent variable actually pinned (only it varies across
   arms)? Are components reported separately (not silently pooled), and parse%/coverage reported honestly?
4. EXECUTION UNDER-SPECIFICATION — steps a zero-context executor would have to guess (datasets, composition
   of checkpoints, prompt formats), where a wrong guess silently changes the DATA.
5. RIGHT / CHEAPEST DATA FOR THE PURPOSE — given what the design says the data is for, is THIS the right
   data, and is there a materially cheaper way to get the same trustworthy data (or a small addition that
   makes it cleaner / more comparable)?
6. CLAIM-RIGOR — CONDITIONAL: fire ONLY IF the design actually asserts a rigorous interpretation / verdict
   / pre-registered conclusion. THEN audit it as one (pre-registration completeness: success criteria AND
   falsifiers with thresholds; claim-scope: does the evidence license the claim — causal strength,
   generality, in-sample-vs-held-out; power: can it distinguish the asserted hypotheses at the planned n).
   If the design states a PURPOSE but no verdict, this dimension is 'no material finding' — NOT 'incomplete.'
7. SCHEDULE EFFICIENCY (falsifiable) — does the schedule justify EVERY serial edge (a step that waits on a
   prior step finishing rather than launching alongside it)? Each one must name what it buys: a validation
   gate (a pilot/smoke that must pass first), a true data dependency (step B needs step A's output), or a
   shared-resource limit (e.g. one GPU, one rate-limited endpoint) — NOT bare "cheaper" or "simpler" without
   a billing argument. If the design calls a serial arrangement cheaper, does its reasoning actually match
   the billing model — does compute cost PER-COMPUTE (Tinker-style: N parallel submissions cost the same as
   N serial ones, so serializing to save money is a false economy) or PER-WALLCLOCK (a rented pod, where
   concurrency needs more units, not zero-cost parallelism)? Flag a serial default that (a) names no reason,
   or (b) claims a cost saving under the wrong billing model for that resource.
8. PRESENTATION-DATA PERSISTENCE — if the design has a Presentation subsection (per-figure/table plots +
   the columns/fields each needs, at what granularity), does the data-collection spec actually PERSIST every
   field the Presentation section requires, at the granularity it requires? A Presentation section that names
   a column or a per-arm/per-row breakdown the collection plan never records is an execution-under-specification
   gap that surfaces only after the run. No Presentation subsection → 'no material finding,' not incomplete.

Also emit, separate from the findings, a one-line QUALITATIVE EVIDENCE-QUALITY read — the good/bad signal the
researcher wants — e.g. 'this will produce a clean comparable number' / 'this confound will muddy it' /
'cheaper way to get the same data' (see the output format).

PRIOR-ROUND DEBATE (when this is a RE-RUN on a revised proposal): if the proposal contains the author's
RESPONSES to earlier findings (e.g. a 'Design-audit responses' / pass-N section), this is a PEER DEBATE,
not a fresh scan. You and the author are two minds converging on the BIG, OBVIOUS design flaws —
confounds, missing controls, comparability traps that change what the result MEANS — NOT maximizing a
finding count. For each prior finding: CONCEDE the ones the response adequately resolves (do NOT
re-raise them); ESCALATE only when the response is wrong or insufficient (quote it, say why it still
fails); otherwise raise only GENUINELY NEW flaws. On a re-run, polish / wording / threshold-calibration
are NOT findings unless they change a conclusion. Reporting 'no new material finding' is a GOOD,
expected outcome once the big flaws are addressed — that is how the debate converges.

VERIFY DATA-BACKED ASSUMPTIONS: where the design leans on a property of the ACTUAL data (number of
classes/biases/strata, available n, label balance) and that data is accessible (a file in the dir, or
the cited HF/source you can inspect), CHECK it rather than trusting the prose — a design that assumes
many strata when the data has few is a power flaw the document alone won't reveal.

Output format (exactly), most severe first:
FINDING <n>: <HIGH|MED|LOW> [<dimension>]
  issue: <one sentence>
  evidence: <file>: \"<short quote or precise reference>\"
  recommendation: <one sentence>
...
NO-FINDING DIMENSIONS: <list any dimension where you found nothing material>
EVIDENCE-QUALITY: <one line — will this design produce a clean, comparable number for its stated purpose, or what will muddy it / a cheaper way to get the same data>
SUMMARY: high=<n> med=<n> low=<n>

=== THE PROGRAM CONSTITUTION (audit against this) ===
$CONSTI_TEXT"
elif [ "$MODE" = data ]; then
PROMPT="You are an INDEPENDENT ADVERSARIAL DATA AUDITOR from a different model family than the agent
that generated/transformed this data. A deterministic full-pool check already ran (counts, truncation,
schema, duplicates, source/label balance — see data_audit*.json); do NOT redo it. Your job is the
SEMANTIC layer a script cannot do: READ THE ACTUAL SAMPLE ROWS and judge whether this data would make
the experiment INVALID or MISLEADING.

What the data is SUPPOSED to be (design intent + invariants) is in: $(basename "$MANIFEST"). The
deterministic report(s) are: ${DATA_REPORTS:-<none found>} (READ THEM — esp. HARD_FAILS,
cot.by_source_open_think, source_balance, char_len). The stratified HIGH-RISK sample file(s) are:
${DATA_SAMPLES:-<none found>} — they deliberately
includes the longest / shortest / near-cap / truncated / per-source / per-arm / spread rows (the
washout bug hid in the long rows a random smoke missed). READ those rows, not just the aggregate JSON.

Audit these dimensions. For each, try HARD to find a real problem; if there genuinely is none, say
'no material finding' for it — do NOT invent issues. False findings destroy this tool's value.
1. MATCHES INTENT — do the rows actually look like what the manifest says (right task/domain, intended
   distribution, on-policy-ness, reasoning actually present and coherent, the right format)?
2. CONFOUNDS / LEAKAGE — answer leaking into the prompt; the trait/label correlated with a nuisance
   variable (descriptor/length/format confound); train↔eval overlap; a probe measuring something other
   than the target (the 'confounded probe' class).
3. LABEL / SOURCE / ARM SANITY — labels right and rows routed to the correct arm; source/arm balance as
   intended; any mislabeled, misrouted, or wrong-distribution rows.
4. FORMAT / TEMPLATE / MASKING — chat template rendered correctly, special tokens / think tags right,
   masking boundaries sane, no degenerate (empty / repetitive / mode-collapsed) generations.
5. GENERATOR ARTIFACTS — does generated data carry artifacts: the model narrating the instructions,
   refusals, scaffolding leaking into the output, or truncation the deterministic layer flagged that you
   should CONFIRM is real in context.
6. WOULD-IT-INVALIDATE — net: would training on / evaluating with this data produce a confidently-wrong
   or misleading result? The highest-leverage question.

Output format (exactly), most severe first:
FINDING <n>: <HIGH|MED|LOW> [<dimension>]
  issue: <one sentence>
  evidence: <sample filename __audit_idx__ N / audit-report field>: \"<short quote>\"
  recommendation: <one sentence>
...
NO-FINDING DIMENSIONS: <list any dimension where you found nothing material>
SUMMARY: high=<n> med=<n> low=<n>

=== THE DESIGN INTENT / MANIFEST (what the data should be) ===
$(cat "$MANIFEST" 2>/dev/null)

=== THE PROGRAM CONSTITUTION (audit against this) ===
$CONSTI_TEXT"
else
PROMPT="You are an INDEPENDENT ADVERSARIAL AUDITOR from a different model family than the agent that
ran this experiment. You are auditing a COMPLETED autonomous-research experiment before it is treated
as 'done'. Read any file in the current directory tree (grep/head as needed; some logs are large).

You audit the experiment AGAINST the research program's own constitution, included below. An experiment's
job is to produce TRUSTWORTHY DATA; INTERPRETATION is the researcher's separate later step — so a RESULTS
that describes the data (the numbers / the plot, + an optional clearly-marked lightweight qualitative read)
and asserts NO pre-registered verdict is VALID and complete: do NOT flag it for a 'missing conclusion /
decision rule.' The most load-bearing standards: a fresh agent must reproduce the run and understand the DATA
FROM THIS DIR ALONE; validity and comparability are the main failure mode; headline numbers must trace to
durable, versioned code in the record, not ad-hoc steps. The interpretation backstop is CONDITIONAL: IF
RESULTS *does* assert a rigorous claim/verdict, THEN it must not overclaim and its conclusions must be
separated from postdictions (fitted after).

Audit these dimensions. For each, try HARD to find a real problem; if there genuinely is none, say
'no material finding' for it — do NOT invent issues. False findings destroy this tool's value.
1. REPRODUCIBILITY — were the HEADLINE numeric artifacts produced by DURABLE, VERSIONED code present
   in the record (the scripts/drivers in the dir), or by something not in the records? Does that code
   regenerate them? Is there evidence of a clean rerun? (If git metadata is available, also check the
   code is committed; if not — e.g. a /tmp or R2 copy — judge durability/presence, not git status.)
2. CLAIM-vs-EVIDENCE — CONDITIONAL on RESULTS asserting a claim: does each CONCLUSION follow from the data
   shown, or overreach the method (causal-strength, generality, storage-vs-correlation, in-sample-vs-general)?
   A data-only RESULTS that reports numbers without a verdict is valid — do NOT flag 'missing conclusion.'
3. CONFOUNDS / VALIDITY — comparisons matched, baselines present, alternative explanations and
   missing controls (e.g. random/orthogonal baselines) ruled out?
4. DATA SANITY — actually SAMPLE the raw generated/training/eval rows (not just the aggregate
   numbers): are labels right, any train/eval or prompt-template leakage, malformed/duplicated rows,
   generator artifacts, or descriptor/format confounds in how the data was constructed? This is the
   'crappy generated data / confounded probe' failure class — inspect the rows, don't trust the JSON.
5. CONCLUSIONS vs POSTDICTIONS — ONLY IF RESULTS asserts a verdict: are conclusions separated from
   postdictions, postdictions flagged untested? A data-only RESULTS (numbers + lightweight read) needs none.
6. RECORDS SELF-SUFFICIENCY — could a fresh agent reproduce the headline results FROM THIS DIR ALONE
   (are the decisive artifacts/probes/logs present, not only referenced on remote storage)?
7. HONEST BOUNDS — are the real limitations (n, single model/organism, in-sample fits, selected
   sweeps) stated?

PRIOR-ROUND DEBATE (when this is a RE-RUN on a revised dir): if the dir contains the author's RESPONSES
to earlier findings ('RESPONSE:' lines, an audit-response section, a later AUDIT2.md), this is a PEER
DEBATE, not a fresh scan — converge on the BIG, OBVIOUS validity flaws (a confidently-wrong number, an
overclaim, an unreproducible headline), NOT a maximal finding count. CONCEDE findings the responses
adequately resolve (don't re-raise); ESCALATE only when a response is wrong/insufficient (quote it, say
why); otherwise raise only GENUINELY NEW flaws. Polish/wording are not findings on a re-run unless they
change a conclusion. 'No new material finding' is a GOOD, expected convergence outcome.

Output format (exactly), most severe first:
FINDING <n>: <HIGH|MED|LOW> [<dimension>]
  issue: <one sentence>
  evidence: <file>: \"<short quote or precise reference>\"
  recommendation: <one sentence>
...
NO-FINDING DIMENSIONS: <list any dimension where you found nothing material>
SUMMARY: high=<n> med=<n> low=<n>

=== THE PROGRAM CONSTITUTION (audit against this) ===
$CONSTI_TEXT"
fi


# Testability seam: dump the assembled prompt without invoking a model (lets CI assert prompt assembly).
if [ -n "${AUDIT_DRY_RUN:-}" ]; then printf '%s\n' "$PROMPT"; exit 0; fi

# --- run, with stale-output guard (FINDING 1): write to a temp file, atomic-mv only on success ----
OUT_TMP="$(mktemp "${TMPDIR:-/tmp}/audit.XXXXXX.md")"
# Built-in default verifiers MUST (1) run with cwd = "$EXP" so the auditor sees the experiment files the
# PROMPT calls "the current directory" (the codex default uses --cd; the claude default cd's in a SUBSHELL
# so the script's own cwd — and the relative $OUT/$OUT.run.log paths — are unaffected), and (2) write their
# FINAL answer to $OUT_TMP (the harness atomically promotes it to $OUT). claude's print mode writes to
# STDOUT, which the harness redirects to the run log — so the claude default REDIRECTS stdout to $OUT_TMP
# (#239: a custom 'claude -p' WITHOUT this redirection wrote to the run log and the harness failed closed
# with "auditor produced no findings file"). A custom AUDIT_VERIFIER_CMD override must likewise run in "$EXP"
# and write its final answer to "$OUT_TMP".
# Select the auditor. A built-in default is run DIRECTLY as argv (NEVER eval'd) so a hostile $EXP path
# can't inject shell (security). Only a caller-supplied AUDIT_VERIFIER_CMD override is eval'd — its
# documented contract is a shell command line (it may carry a redirection/pipeline), and the caller owns it.
# VERIFIER_CMD below is a DISPLAY string (logging + the print seam); the built-ins EXECUTE from the argv
# branches in run_verifier, not from this string.
if [ -n "$VERIFIER_OVERRIDE" ]; then
  VERIFIER_KIND=override; VERIFIER_CMD=$VERIFIER_OVERRIDE
elif [ "$AUDITOR_FAMILY" = claude ]; then
  VERIFIER_KIND=claude;   VERIFIER_CMD="( cd \"$EXP\" && claude -p ) > \"$OUT_TMP\""
else
  VERIFIER_KIND=codex;    VERIFIER_CMD="codex exec --sandbox read-only --skip-git-repo-check --cd \"$EXP\" -o \"$OUT_TMP\""
fi
# run_verifier: stdin = the PROMPT. Built-ins run as direct argv (no eval); the override is eval'd (its
# documented contract is a shell command line that writes its final answer to "$OUT_TMP").
run_verifier(){
  case "$VERIFIER_KIND" in
    claude)   ( cd "$EXP" && claude -p ) > "$OUT_TMP" ;;
    codex)    codex exec --sandbox read-only --skip-git-repo-check --cd "$EXP" -o "$OUT_TMP" ;;
    override) eval "$VERIFIER_OVERRIDE" ;;
  esac
}
# Testability seam: print the resolved cross-family selection without invoking a model (mirrors
# AUDIT_DRY_RUN; lets the offline smoke assert selection + the exact $OUT_TMP redirect target). Cleans up.
if [ -n "${AUDIT_PRINT_VERIFIER:-}" ]; then
  printf 'AUDITOR_FAMILY=%s\nRUNNER_FAMILY=%s\nOUT_TMP=%s\nVERIFIER_CMD=%s\n' \
    "$AUDITOR_FAMILY" "$RUNNER_FAMILY" "$OUT_TMP" "$VERIFIER_CMD"
  rm -f "$OUT_TMP"; exit 0
fi
echo "[audit_experiment] mode=$MODE exp=$EXP auditor=$AUDITOR_FAMILY runner=$RUNNER_FAMILY" >&2
if ! run_verifier <<< "$PROMPT" >"$OUT.run.log" 2>&1; then
  echo "BLOCKED: auditor run failed — last lines of $OUT.run.log:" >&2; tail -5 "$OUT.run.log" >&2
  rm -f "$OUT_TMP"; exit 1; fi
[ -s "$OUT_TMP" ] || { echo "BLOCKED: auditor produced no findings file (stale $OUT NOT reused)" >&2; rm -f "$OUT_TMP"; exit 1; }
mv "$OUT_TMP" "$OUT"
echo "[audit_experiment] findings -> $OUT" >&2
grep -E "^FINDING|^SUMMARY|^NO-FINDING" "$OUT" || true
