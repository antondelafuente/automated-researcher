#!/bin/bash
# audit_experiment.sh — independent, cross-family adversarial AUDIT of a completed experiment.
#
# Sibling to verify_claim.sh. Where verify_claim CHECKS a given list of claims (input-side gate,
# pre-launch), this GENERATES findings about a finished experiment (output-side gate, at close).
# It audits the experiment dir AGAINST the AAR's own constitution (AGENTS.md) + a validity rubric,
# run by a DIFFERENT model family than the agent that produced the work — because an agent cannot
# reliably catch its own reproducibility gaps, overclaims, or confounds, but a foreign reader can.
#
# Cross-family is the whole point: on a Claude AAR the auditor is Codex; on a Codex AAR set
# AUDIT_VERIFIER_CMD to `claude -p …`. Always the OTHER family from whoever ran the experiment.
# The cross-family guarantee is MECHANICAL here (not just documented): set AAR_SUBSTRATE to the
# family that RAN the experiment (in --scaffold mode: the family that AUTHORED the proposal — i.e. the
# AAR invoking --scaffold); the script refuses to run if the auditor family would match it.
#
# Validated 2026-06-12: from a cold read of a pre-fix experiment state, Codex independently
# rediscovered all three findings a human had routed to ChatGPT (repro gap, in-sample steering,
# claim overreach) PLUS two more, with zero false findings. Hardened 2026-06-12 (audit-the-auditor):
# stale-output guard, cross-family enforcement, DATA SANITY dimension, durable-vs-committed wording.
#
# Usage: audit_experiment.sh <experiment-dir> [out-file]              # close-side (post-hoc) audit
#        audit_experiment.sh --design <experiment-dir> [design-file] [out-file]   # PRE-LAUNCH design audit
#        audit_experiment.sh --data <experiment-dir> [manifest] [out-file]        # MID-RUN data audit
#        audit_experiment.sh --scaffold <proposal.md> [context-dir] [out-file]    # SCAFFOLD/PRODUCT design review
#        audit_experiment.sh --code <diff-file> [context-dir] [out-file]          # DIFF code review (implementation)
# --scaffold reviews a PROPOSAL doc for a scaffold/product change against ARCHITECTURE dimensions (right seam,
# DRY/canonical-home, blast radius, reversibility, instance<->product leak, contract clarity, simplest-thing,
# convention-match). --code reviews a DIFF against IMPLEMENTATION dimensions (correctness, edge-cases, regression,
# security, simplify) — the design and code review halves of the SWE pipeline. Both require AAR_SUBSTRATE = the
# AUTHOR's family (cross-family enforced) and read the context repo's AGENTS.md (fail loud if absent). Default
# context: --scaffold = the proposal file's git root; --code = the CWD's git root (the diff is transient).
# --data audits the ACTUAL generated/transformed data against the design intent (the 'facts→logic→
#   DATA→evidence' ladder): the deterministic full-pool layer is `pipelines/eval/audit_data.py`
#   (counts/truncation/schema/dupes/balance → data_audit*.json + a stratified high-risk sample); this
#   mode is the SEMANTIC layer — a foreign model reads the SAMPLE rows + the manifest's intent and asks
#   "would this data make the experiment invalid or misleading?" Motivated by the washout truncation bug
#   (a generated replay froze clean while 1160/6457 rows were truncated mid-CoT; a 2-sample smoke missed it).
#   experiment-dir: the ~/orchestrator/<exp>/ dir to audit (read-only; the auditor sees its files)
#   out-file:       findings destination (default: <experiment-dir>/AUDIT.md, or DESIGN_AUDIT.md in --design mode)
#   design-file:    (--design mode) the proposal to audit; default = newest DESIGN*.md in the dir
# --design audits the PROPOSAL before any money/GPU moves (third gate alongside verify_claim
# pre-launch and the close audit): confounds & missing controls, comparability traps,
# pre-registration completeness, claim-scope, power, cheaper-decisive alternatives. Motivated by
# midtrain-interp v2, whose two real flaws (in-sample steering eval; no random-direction control)
# were DESIGN flaws only caught at close.
# Env: AAR_SUBSTRATE=claude|codex (family that ran the exp; default claude — set in instance config)
#      AUDIT_VERIFIER_CMD=...      (override the auditor; must be a DIFFERENT family than AAR_SUBSTRATE)
#      AUDIT_CONSTITUTION=path     (the standards file; default ~/AGENTS.md)
set -euo pipefail
MODE=close
if [ "${1:-}" = "--design" ]; then MODE=design; shift;
elif [ "${1:-}" = "--data" ]; then MODE=data; shift;
elif [ "${1:-}" = "--scaffold" ]; then MODE=scaffold; shift;
elif [ "${1:-}" = "--code" ]; then MODE=code; shift; fi
if [ "$MODE" = scaffold ] || [ "$MODE" = code ]; then
  # --scaffold reviews a PROPOSAL.md (design); --code reviews a DIFF file (implementation). Both: file input +
  # context repo + author family. Cross-family + context-constitution handling below is shared by both.
  PROPOSAL=${1:?usage: audit_experiment.sh --scaffold <proposal.md> | --code <diff-file> [context-dir] [out-file]}
  [ -f "$PROPOSAL" ] || { echo "BLOCKED: input file missing: $PROPOSAL" >&2; exit 1; }
  [ "$MODE" != code ] || [ -s "$PROPOSAL" ] || { echo "BLOCKED: --code given an EMPTY diff ($PROPOSAL) — a failed or no-op diff generation would otherwise pass review without reviewing any code. Regenerate the diff." >&2; exit 1; }
  # Context = the dir the auditor reads to CHECK against the real tree. Default to the GIT/WORKTREE ROOT, else the file's dir.
  if [ -n "${2:-}" ]; then EXP=$2;
  elif [ "$MODE" = code ]; then EXP=$(git rev-parse --show-toplevel 2>/dev/null) || EXP=$(pwd);   # a diff is transient (often /tmp) → context = the CWD's repo, not the diff's dir
  else EXP=$(git -C "$(dirname "$PROPOSAL")" rev-parse --show-toplevel 2>/dev/null) || EXP=$(cd "$(dirname "$PROPOSAL")" && pwd); fi
  if [ "$MODE" = scaffold ]; then OUT=${3:-${PROPOSAL%.md}.SCAFFOLD_AUDIT.md}; else OUT=${3:-${PROPOSAL}.CODE_REVIEW.md}; fi   # append (don't %.*-strip — that mangles a no-ext diff under a dotted dir)
  PROPOSAL_REL=$(realpath --relative-to="$EXP" "$PROPOSAL" 2>/dev/null || realpath "$PROPOSAL" 2>/dev/null || echo "$PROPOSAL")  # never degrade to a bare basename
else
EXP=${1:?usage: audit_experiment.sh [--design|--data|--scaffold] <experiment-dir|proposal> [args...]}
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
fi
[ -d "$EXP" ] || { echo "BLOCKED: context/experiment dir missing: $EXP" >&2; exit 1; }

# --- cross-family enforcement (FINDING 2) -------------------------------------------------------
# Infer the auditor's family from the verifier command (default = codex).
AUDITOR_FAMILY=codex
if [ -n "${AUDIT_VERIFIER_CMD:-}" ]; then
  case "$AUDIT_VERIFIER_CMD" in
    *claude*) AUDITOR_FAMILY=claude ;; *codex*) AUDITOR_FAMILY=codex ;; *) AUDITOR_FAMILY=custom ;;
  esac
fi
if [ "$MODE" = scaffold ] || [ "$MODE" = code ]; then
  case "${AAR_SUBSTRATE:-}" in
    claude|codex) ;;   # exact match only — a typo (e.g. 'codx') must NOT slip a same-family review past the gate
    *) echo "BLOCKED: --$MODE requires AAR_SUBSTRATE = the AUTHOR's family, exactly 'claude' or 'codex'" >&2
       echo "  (got '${AAR_SUBSTRATE:-<unset>}'). No default: the experiment default (claude) or a typo would let a" >&2
       echo "  Codex author be reviewed by Codex (same family = not cross-family). Set it to whoever wrote the change." >&2
       exit 1 ;;
  esac
fi
RUNNER_FAMILY=${AAR_SUBSTRATE:-claude}
if [ "$AUDITOR_FAMILY" = "$RUNNER_FAMILY" ]; then
  echo "BLOCKED: cross-family audit required — auditor family ($AUDITOR_FAMILY) == experiment runner" >&2
  echo "  family ($RUNNER_FAMILY). Set AUDIT_VERIFIER_CMD to a DIFFERENT family (e.g. on a Codex AAR:" >&2
  echo "  AUDIT_VERIFIER_CMD='claude -p ...'), or correct AAR_SUBSTRATE if mis-set." >&2
  exit 1
fi

if [ "$MODE" = scaffold ] || [ "$MODE" = code ]; then
  # Portable default: the CONTEXT repo's AGENTS.md (an outsider's conventions), not $HOME's.
  CONSTITUTION=${AUDIT_CONSTITUTION:-${EXP%/}/AGENTS.md}
else
  CONSTITUTION=${AUDIT_CONSTITUTION:-$HOME/AGENTS.md}
fi
CONSTI_TEXT=""
[ -f "$CONSTITUTION" ] && CONSTI_TEXT=$(cat "$CONSTITUTION")
if { [ "$MODE" = scaffold ] || [ "$MODE" = code ]; } && [ -z "$CONSTI_TEXT" ]; then
  echo "BLOCKED: no constitution found for --$MODE (looked at $CONSTITUTION). A review without the" >&2
  echo "  program's conventions is toothless — set AUDIT_CONSTITUTION to your AGENTS.md (or add one to the context repo)." >&2
  exit 1
fi
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

Review against the program's constitution (below). The most load-bearing standards: validity and
comparability are the main failure mode ('are these two numbers even on the same scale?'); success
criteria and falsifiers must be pre-registered BEFORE the run; conclusions must be distinguishable
from postdictions by design; the silent failure mode is a clean pipeline producing a
confidently-wrong number.

Audit these dimensions. For each, try HARD to find a real problem; if there genuinely is none, say
'no material finding' for it — do NOT invent issues. False findings destroy this tool's value.
1. CONFOUNDS / MISSING CONTROLS — are the planned comparisons matched; are the baselines and
   negative controls (random/orthogonal/shuffled class, placebo arms) IN THE PLAN, not deferred?
2. VALIDITY / COMPARABILITY — will any two numbers being compared be on the same scale, same metric,
   same data distribution? Any train/eval leakage, probe contamination, or selection effect built
   into the construction?
3. PRE-REGISTRATION COMPLETENESS — are success criteria AND falsifiers stated with thresholds? Is
   every plausible outcome interpretable (no 'heads I win, tails ambiguous' designs)? Are
   hyperparameter/selection steps confined to fit data?
4. CLAIM-SCOPE — will the planned evidence actually license the claim the design says it is after
   (causal strength, generality, storage-vs-routing, in-sample-vs-held-out)? Quote the claim and the
   evidence that falls short.
5. POWER / SENSITIVITY — n, seeds, effect sizes: can the design distinguish its hypotheses at the
   planned sample sizes, or will results land inside the noise band?
6. EXECUTION UNDER-SPECIFICATION — steps a zero-context executor would have to guess (datasets,
   composition of checkpoints, prompt formats, thresholds), where a wrong guess silently changes
   the result.
7. CHEAPER / MORE DECISIVE ALTERNATIVE — is there a materially cheaper design answering the same
   question, or a small addition that turns a suggestive result into a decisive one?

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
elif [ "$MODE" = code ]; then
PROMPT="You are an INDEPENDENT CODE REVIEWER from a different model family than the agent (author) that wrote
this change. Review the DIFF below. The DESIGN was reviewed separately (--scaffold) — do NOT re-litigate the
design/architecture or naming preference. Your job is the IMPLEMENTATION: real defects in the changed lines.
You may read the surrounding tree (the current directory) for context on conventions and on what the changed
code calls.

Audit these dimensions. For each, try HARD to find a real problem; if there genuinely is none, say 'no material
finding' — do NOT invent issues. False findings destroy this tool's value.
1. CORRECTNESS — does the changed code do what it intends? Logic errors, wrong conditions, off-by-one, wrong
   variable, broken control flow, a guard that doesn't guard.
2. EDGE CASES — unset/empty vars (esp. under 'set -u'), quoting/word-splitting, missing files, non-zero exits
   swallowed, locale/whitespace, a fallback that silently degrades, partial-failure leaving bad state.
3. REGRESSION — does the change break an existing path it touches (other modes/branches/callers)? Check the
   dispatch and shared code it modifies against the surrounding tree.
4. SECURITY / SAFETY — secrets/tokens leaked into output or logs, an injection via unsanitized input, a
   destructive op (rm/force-push/delete) without the guard the convention requires, a gate that can be bypassed.
5. SIMPLIFY — a genuinely simpler/clearer form that removes a real bug-surface (not style nits).

Output (exactly), most severe first:
FINDING <n>: <HIGH|MED|LOW> [<correctness|edge-case|regression|security|simplify>]
  issue: <one sentence>
  evidence: <file/hunk>: \"<short quote from the diff>\"
  recommendation: <one sentence>
...
NO-FINDING AREAS: <list dimensions with nothing material>
SUMMARY: high=<n> med=<n> low=<n>

=== THE DIFF UNDER REVIEW ($PROPOSAL_REL) ===
$(cat "$PROPOSAL")

=== THE PROGRAM CONSTITUTION (conventions to check against) ===
$CONSTI_TEXT"
elif [ "$MODE" = scaffold ]; then
PROMPT="You are an INDEPENDENT ADVERSARIAL REVIEWER from a different model family than the agent that
wrote this SCAFFOLD/PRODUCT change PROPOSAL. Nothing has been built yet (or it's a draft); your job is to
find the DESIGN flaws BEFORE the change lands and every agent depends on it. The proposal under review is:
$PROPOSAL_REL (path relative to the current directory tree root). Read it in full, THEN read the ACTUAL scaffold it
touches (skills, scripts, plugin.json/marketplace.json, CLAUDE.md/AGENTS.md, existing helpers) to CHECK its
claims against reality — a proposal that says 'no home exists for this' or 'this matches the convention' is
only as good as the tree confirms. IGNORE transient/state files (logs, .done, CLAIMED_BY).

This is the PRODUCT: a scaffold that turns coding agents into autonomous researchers, consumed by
zero-context agents and (eventually) outside researchers. Review against the program's constitution (below)
— especially: ONE canonical home per fact (no two live copies); the instance↔product boundary (generic
content must not hardcode instance specifics, and instance specifics must not freeze into the product);
discovered-at-point-of-need (a zero-context consumer must be able to find + use it WITHOUT a hidden
instance fallback); scaffold length is product cost (bloat is a defect).

Audit these dimensions. For each, try HARD to find a real problem; if there genuinely is none, say 'no
material finding' for it — do NOT invent issues. False findings destroy this tool's value.
1. RIGHT SEAM / ABSTRACTION — is the boundary drawn where the system actually varies (the generic/instance
   split, the interface/contract cut at the right place — or 'gated around the wrong unit')?
2. DRY / CANONICAL HOME — does a home for this ALREADY exist? Is it duplicating logic/config/prose, or
   adding a new thing where EXTENDING an existing helper/skill/mode is the real fix?
3. BLAST RADIUS / DEPENDENTS — who depends on the touched files (every AAR? a live experiment? other
   skills/plugins)? Is it safe for in-flight work; does it need a migration / restart / back-compat shim
   the proposal omits?
4. REVERSIBILITY — how hard to undo if wrong? Anything one-way (deleting a canonical artifact, a convention
   everyone adopts)? Are old paths preserved (symlink/shim)?
5. INSTANCE <-> PRODUCT LEAK — does generic/product content hardcode instance specifics (paths, model
   names, keys, lab recipes)? Does instance/frozen content get pushed into the product where it doesn't
   belong? (The migration's core failure class.)
6. INTERFACE / CONTRACT CLARITY — for a zero-context consumer (a fresh agent, an outside install): is the
   new interface/convention discoverable and unambiguous, and does it resolve with NO hidden instance
   fallback ('works only because the author's box has X')?
7. SIMPLEST THING / SCOPE — is this the MINIMUM change that solves the stated problem, or over-engineered
   (extra modes/abstraction)? Conversely, does it UNDER-solve — fix a symptom not the cause, leave the real
   gap open?
8. CONVENTION-MATCH — does it follow established patterns (path-scoped commits, the gate ladder, the
   skill/plugin shape, naming, single-canonical-home), or introduce a one-off the next agent won't expect?

Also judge the PROPOSAL ITSELF: does it state the problem, justify the chosen approach OVER the alternatives
it lists, and own its blast radius + rollback — or assert a solution without the case for it?

PRIOR-ROUND DEBATE (when this is a RE-REVIEW on a revised proposal): if the proposal contains the author's
RESPONSES to earlier findings, this is a PEER DEBATE, not a fresh scan. CONCEDE findings the responses
adequately resolve (don't re-raise); ESCALATE only when a response is wrong/insufficient (quote it, say
why); otherwise raise only GENUINELY NEW flaws. Polish/wording/naming are NOT findings on a re-run unless
they change the design. 'No new material finding' is the GOOD, expected convergence outcome.

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
else
PROMPT="You are an INDEPENDENT ADVERSARIAL AUDITOR from a different model family than the agent that
ran this experiment. You are auditing a COMPLETED autonomous-research experiment before it is treated
as 'done'. Read any file in the current directory tree (grep/head as needed; some logs are large).

You audit the experiment AGAINST the research program's own constitution, included below. The most
load-bearing standards in it: a fresh agent must be able to reproduce the run and know its conclusion
FROM THIS DIR ALONE; conclusions (pre-registered) must be separated from postdictions (fitted after);
validity and comparability are the main failure mode; headline numbers must trace to durable,
versioned code in the experiment record, not ad-hoc steps.

Audit these dimensions. For each, try HARD to find a real problem; if there genuinely is none, say
'no material finding' for it — do NOT invent issues. False findings destroy this tool's value.
1. REPRODUCIBILITY — were the HEADLINE numeric artifacts produced by DURABLE, VERSIONED code present
   in the record (the scripts/drivers in the dir), or by something not in the records? Does that code
   regenerate them? Is there evidence of a clean rerun? (If git metadata is available, also check the
   code is committed; if not — e.g. a /tmp or R2 copy — judge durability/presence, not git status.)
2. CLAIM-vs-EVIDENCE — does each CONCLUSION follow from the data shown, or overreach the method
   (causal-strength, generality, storage-vs-correlation, in-sample-vs-general)?
3. CONFOUNDS / VALIDITY — comparisons matched, baselines present, alternative explanations and
   missing controls (e.g. random/orthogonal baselines) ruled out?
4. DATA SANITY — actually SAMPLE the raw generated/training/eval rows (not just the aggregate
   numbers): are labels right, any train/eval or prompt-template leakage, malformed/duplicated rows,
   generator artifacts, or descriptor/format confounds in how the data was constructed? This is the
   'crappy generated data / confounded probe' failure class — inspect the rows, don't trust the JSON.
5. CONCLUSIONS vs POSTDICTIONS — separated, postdictions flagged untested?
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

# --- run, with stale-output guard (FINDING 1): write to a temp file, atomic-mv only on success ----
OUT_TMP="$(mktemp "${TMPDIR:-/tmp}/audit.XXXXXX.md")"
VERIFIER_CMD=${AUDIT_VERIFIER_CMD:-"codex exec --sandbox read-only --skip-git-repo-check --cd \"$EXP\" -o \"$OUT_TMP\""}
echo "[audit_experiment] mode=$MODE exp=$EXP auditor=$AUDITOR_FAMILY runner=$RUNNER_FAMILY" >&2
if ! eval "$VERIFIER_CMD" <<< "$PROMPT" >"$OUT.run.log" 2>&1; then
  echo "BLOCKED: auditor run failed — last lines of $OUT.run.log:" >&2; tail -5 "$OUT.run.log" >&2
  rm -f "$OUT_TMP"; exit 1; fi
[ -s "$OUT_TMP" ] || { echo "BLOCKED: auditor produced no findings file (stale $OUT NOT reused)" >&2; rm -f "$OUT_TMP"; exit 1; }
mv "$OUT_TMP" "$OUT"
echo "[audit_experiment] findings -> $OUT" >&2
grep -E "^FINDING|^SUMMARY|^NO-FINDING" "$OUT" || true
