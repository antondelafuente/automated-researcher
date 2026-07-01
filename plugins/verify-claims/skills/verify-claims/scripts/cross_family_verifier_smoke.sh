#!/bin/bash
# cross_family_verifier_smoke.sh — deterministic, offline guard for audit_experiment.sh's cross-family
# auditor selection. Covers #262 (a same-family / BASH_ENV-injected AUDIT_VERIFIER_CMD must NOT run
# same-family and must NOT dead-end) and #239 (the claude built-in default must redirect to $OUT_TMP).
# Uses the AUDIT_PRINT_VERIFIER seam: prints the chosen auditor + verifier command, invokes no model.
# Each case scrubs env (env -u BASH_ENV/AUDIT_VERIFIER_CMD/AAR_SUBSTRATE) so the instance BASH_ENV that
# re-injects AUDIT_VERIFIER_CMD cannot make the test non-hermetic.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
AE="$HERE/audit_experiment.sh"
[ -f "$AE" ] || { echo "  SMOKE-FAIL: audit_experiment.sh not found next to smoke" >&2; exit 1; }
fail=0; err(){ echo "  SMOKE-FAIL: $*" >&2; fail=1; }
EXP=$(mktemp -d "${TMPDIR:-/tmp}/cfvsmoke.XXXXXX") || { echo "  SMOKE-FAIL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$EXP"' EXIT
: > "$EXP/RESULTS.md"   # close mode only needs a dir; give it a file for realism

# seam(): run the selection seam under a scrubbed env; extra NAME=VALUE operands set only what a case tests.
seam(){ env -u BASH_ENV -u AUDIT_VERIFIER_CMD -u AAR_SUBSTRATE AUDIT_PRINT_VERIFIER=1 "$@" bash "$AE" "$EXP" 2>/dev/null; }

# (a) #262 — claude runner + a same-family (BASH_ENV-style) AUDIT_VERIFIER_CMD must self-correct to the
#     codex auditor: never block, never run same-family.
if out=$(seam AAR_SUBSTRATE=claude AUDIT_VERIFIER_CMD='claude -p > "$OUT_TMP"'); then
  echo "$out" | grep -q '^AUDITOR_FAMILY=codex$' || err "(a) did not self-correct to codex auditor: $out"
  echo "$out" | grep -q 'codex exec'            || err "(a) did not fall back to the codex default: $out"
else
  err "(a) claude runner + injected same-family verifier BLOCKED instead of self-correcting"
fi

# (b) #239 — codex runner selects the claude default; that default runs in $EXP (cwd = experiment dir, so
#     the auditor sees the files the prompt calls "the current directory") AND redirects to $OUT_TMP.
if out=$(seam AAR_SUBSTRATE=codex); then
  echo "$out" | grep -q '^AUDITOR_FAMILY=claude$' || err "(b) codex runner did not select claude auditor: $out"
  echo "$out" | grep -q 'claude -p'               || err "(b) claude default is not 'claude -p': $out"
  echo "$out" | grep -qF "cd \"$EXP\""            || err "(b) claude default does not run in the experiment dir (\$EXP): $out"
  echo "$out" | grep -q ') >'                     || err "(b) claude default lacks the > \$OUT_TMP redirection (#239): $out"
else
  err "(b) codex runner failed unexpectedly"
fi

# (c) a valid opposite-family override is honored verbatim.
if out=$(seam AAR_SUBSTRATE=claude AUDIT_VERIFIER_CMD='codex exec --sandbox read-only --smoke-marker -o "$OUT_TMP"'); then
  echo "$out" | grep -q -- '--smoke-marker' || err "(c) opposite-family override not honored verbatim: $out"
else
  err "(c) opposite-family override BLOCKED"
fi

# (d) unset / unknown substrate fails closed (no default that could pick a same-family auditor).
seam                     >/dev/null 2>&1 && err "(d) unset AAR_SUBSTRATE did not fail closed"
seam AAR_SUBSTRATE=frog  >/dev/null 2>&1 && err "(d) unknown AAR_SUBSTRATE did not fail closed"

[ "$fail" = 0 ] && echo "  ok: cross_family_verifier smoke (a-d)" >&2
exit "$fail"
