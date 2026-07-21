#!/bin/bash
# cross_family_verifier_smoke.sh — deterministic, offline guard for audit_experiment.sh's cross-family
# auditor selection. Covers #262 (a same-family / BASH_ENV-injected AUDIT_VERIFIER_CMD must NOT run
# same-family and must NOT dead-end), #239 (the claude built-in default must redirect to $OUT_TMP), and
# #373 (executable-token family-sniffing, BASH_ENV sanitized for this script's own subshells, and the
# built-in codex auditor's apikey-CODEX_HOME quota fallback).
# Uses the AUDIT_PRINT_VERIFIER seam: prints the chosen auditor + verifier command, invokes no model.
# Each case scrubs env (env -u BASH_ENV/AUDIT_VERIFIER_CMD/AAR_SUBSTRATE) so the instance BASH_ENV that
# re-injects AUDIT_VERIFIER_CMD cannot make the test non-hermetic. Cases (h)-(j) instead run the REAL
# run/retry path against a fake `codex` on PATH (never a real model call) to cover #373's quota fallback.
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
#     the auditor sees the files the prompt calls "the current directory") AND redirects to the EXACT
#     $OUT_TMP findings path (not merely some redirection to a wrong file).
if out=$(seam AAR_SUBSTRATE=codex); then
  echo "$out" | grep -q '^AUDITOR_FAMILY=claude$' || err "(b) codex runner did not select claude auditor: $out"
  echo "$out" | grep -q 'claude -p'               || err "(b) claude default is not 'claude -p': $out"
  echo "$out" | grep -qF "cd \"$EXP\""            || err "(b) claude default does not run in the experiment dir (\$EXP): $out"
  ot=$(printf '%s\n' "$out" | sed -n 's/^OUT_TMP=//p')
  vc=$(printf '%s\n' "$out" | sed -n 's/^VERIFIER_CMD=//p')
  [ -n "$ot" ] || err "(b) seam did not print OUT_TMP: $out"
  case "$vc" in *"> \"$ot\"") : ;; *) err "(b) claude default redirect target != exact \$OUT_TMP: vc=[$vc] ot=[$ot]" ;; esac
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

# (e) #465 — a --design re-audit with no explicit out-file must never clobber a prior DESIGN_AUDIT.md:
#     it auto-numbers to the next free DESIGN_AUDIT<n>.md instead. Also, preserving DESIGN_AUDIT*.md across
#     passes must never make a later pass's default DESIGN_FILE auto-detect pick a prior audit's OWN output
#     (newer mtime than DESIGN.md) instead of the actual proposal — the auto-detect glob must exclude them.
: > "$EXP/DESIGN.md"
design_seam(){ env -u BASH_ENV -u AUDIT_VERIFIER_CMD AUDIT_PRINT_VERIFIER=1 AAR_SUBSTRATE=claude bash "$AE" --design "$EXP" 2>/dev/null; }
if out=$(design_seam); then
  echo "$out" | grep -q '^OUT=.*/DESIGN_AUDIT\.md$' || err "(e) first design pass did not default to DESIGN_AUDIT.md: $out"
  echo "$out" | grep -q '^DESIGN_FILE=.*/DESIGN\.md$' || err "(e) first design pass did not select DESIGN.md as DESIGN_FILE: $out"
else
  err "(e) first design pass failed unexpectedly"
fi
: > "$EXP/DESIGN_AUDIT.md"
if out=$(design_seam); then
  echo "$out" | grep -q '^OUT=.*/DESIGN_AUDIT2\.md$' || err "(e) re-audit with DESIGN_AUDIT.md present did not auto-number to DESIGN_AUDIT2.md: $out"
  echo "$out" | grep -q '^DESIGN_FILE=.*/DESIGN\.md$' || err "(e) re-audit with a newer DESIGN_AUDIT.md present picked it as DESIGN_FILE instead of DESIGN.md: $out"
else
  err "(e) second design pass failed unexpectedly"
fi
: > "$EXP/DESIGN_AUDIT2.md"
if out=$(design_seam); then
  echo "$out" | grep -q '^OUT=.*/DESIGN_AUDIT3\.md$' || err "(e) third design pass did not auto-number to DESIGN_AUDIT3.md: $out"
  echo "$out" | grep -q '^DESIGN_FILE=.*/DESIGN\.md$' || err "(e) third design pass picked a preserved DESIGN_AUDIT*.md as DESIGN_FILE instead of DESIGN.md: $out"
else
  err "(e) third design pass failed unexpectedly"
fi
if out=$(env -u BASH_ENV -u AUDIT_VERIFIER_CMD AUDIT_PRINT_VERIFIER=1 AAR_SUBSTRATE=claude bash "$AE" --design "$EXP" "$EXP/DESIGN.md" "$EXP/CUSTOM_OUT.md" 2>/dev/null); then
  echo "$out" | grep -q '^OUT=.*/CUSTOM_OUT\.md$' || err "(e) explicit out-file was not honored verbatim (no auto-numbering): $out"
else
  err "(e) design pass with explicit out-file failed unexpectedly"
fi
rm -f "$EXP/DESIGN.md" "$EXP/DESIGN_AUDIT.md" "$EXP/DESIGN_AUDIT2.md"

# (f) #373 — the real incident: a codex override whose command line contains a literal claude-lookalike
#     scratch path (e.g. a /tmp/claude-1000/... working dir) must be classified by its EXECUTABLE token
#     ("codex"), not misclassified same-family by a substring match over the whole command string.
if out=$(seam AAR_SUBSTRATE=claude AUDIT_VERIFIER_CMD='codex exec --sandbox read-only --cd "/tmp/claude-1000/wd" -o "$OUT_TMP"'); then
  echo "$out" | grep -q '^AUDITOR_FAMILY=codex$'   || err "(f) codex override with a claude-lookalike path was not classified codex: $out"
  echo "$out" | grep -q -- '/tmp/claude-1000/wd'   || err "(f) opposite-family override not honored verbatim: $out"
else
  err "(f) codex override with a claude-lookalike path BLOCKED instead of being honored"
fi

# (g) #373 — defense-in-depth: this script must unset BASH_ENV for its own subshells/eval/external
#     processes, so an instance ~/.env that re-injects AUDIT_VERIFIER_CMD via BASH_ENV cannot clobber a
#     caller override a second time inside any child bash this script spawns.
BENV_FILE=$(mktemp "${TMPDIR:-/tmp}/cfvsmoke_bashenv.XXXXXX") || { echo "  SMOKE-FAIL: mktemp failed" >&2; exit 1; }
if out=$(env -u AUDIT_VERIFIER_CMD BASH_ENV="$BENV_FILE" AUDIT_PRINT_VERIFIER=1 AAR_SUBSTRATE=claude bash "$AE" "$EXP" 2>/dev/null); then
  echo "$out" | grep -q '^BASH_ENV=<unset>$' || err "(g) BASH_ENV not sanitized for this script's own subshells: $out"
else
  err "(g) BASH_ENV-set run failed unexpectedly"
fi
rm -f "$BENV_FILE"

# (h)-(j) #373 — the built-in codex auditor's apikey-CODEX_HOME quota fallback. A fake `codex` on PATH
#     drives the real run/retry path (never a real model call): "exec" fails with a usage-limit error
#     unless CODEX_HOME/auth.json exists, and "login --api-key" (the actual fallback mechanism, since
#     `-c preferred_auth_method=apikey` alone does not switch auth in codex 0.144) writes it.
FAKEBIN=$(mktemp -d "${TMPDIR:-/tmp}/cfvsmoke_fakebin.XXXXXX") || { echo "  SMOKE-FAIL: mktemp failed" >&2; exit 1; }
cat > "$FAKEBIN/codex" <<'FAKE_CODEX'
#!/bin/bash
case "${1:-}" in
  login)
    mkdir -p "${CODEX_HOME:?}"
    printf '{"OPENAI_API_KEY":"%s"}\n' "${3:-fake}" > "$CODEX_HOME/auth.json"
    exit 0 ;;
  exec)
    shift; out=""
    while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac; done
    if [ -n "${CODEX_HOME:-}" ] && [ -s "$CODEX_HOME/auth.json" ]; then
      printf 'FINDING 1: LOW [test]\n  issue: fake\n  evidence: fake: "x"\n  recommendation: fake\nSUMMARY: high=0 med=0 low=1\n' > "$out"
      exit 0
    fi
    case "${FAKE_CODEX_FAILURE:-quota}" in
      quota)   echo "Error: You've hit your usage limit. Try again later." >&2 ;;
      generic) echo "Error: boom, something unrelated broke." >&2 ;;
    esac
    exit 1 ;;
  *) exit 1 ;;
esac
FAKE_CODEX
chmod +x "$FAKEBIN/codex"

# (h) usage-limit failure + OPENAI_API_KEY set: retries via the apikey CODEX_HOME and succeeds, having
#     announced the billing switch loudly (never silently).
H_EXP=$(mktemp -d "${TMPDIR:-/tmp}/cfvsmoke_h.XXXXXX")
: > "$H_EXP/RESULTS.md"
if out=$(env -u BASH_ENV -u AUDIT_VERIFIER_CMD PATH="$FAKEBIN:$PATH" OPENAI_API_KEY=fake-key AAR_SUBSTRATE=claude bash "$AE" "$H_EXP" 2>&1); then
  [ -s "$H_EXP/AUDIT.md" ]                        || err "(h) quota fallback did not produce $H_EXP/AUDIT.md: $out"
  grep -q 'FINDING 1' "$H_EXP/AUDIT.md" 2>/dev/null || err "(h) AUDIT.md missing the fallback run's content"
  echo "$out" | grep -qi 'API-BILLED'              || err "(h) fallback did not announce the billing switch loudly: $out"
else
  err "(h) quota fallback did not succeed: $out"
fi
rm -rf "$H_EXP"

# (i) same usage-limit failure with NO OPENAI_API_KEY: BLOCKED with the specific no-key message, never
#     silently retried and never left to a generic/confusing failure.
I_EXP=$(mktemp -d "${TMPDIR:-/tmp}/cfvsmoke_i.XXXXXX")
: > "$I_EXP/RESULTS.md"
if out=$(env -u BASH_ENV -u AUDIT_VERIFIER_CMD -u OPENAI_API_KEY PATH="$FAKEBIN:$PATH" AAR_SUBSTRATE=claude bash "$AE" "$I_EXP" 2>&1); then
  err "(i) usage-limit failure with no OPENAI_API_KEY did not block: $out"
else
  echo "$out" | grep -qi 'no OPENAI_API_KEY' || err "(i) block message did not name the missing OPENAI_API_KEY: $out"
fi
rm -rf "$I_EXP"

# (j) a NON-quota codex failure must NOT trigger the apikey fallback — never spend API billing on an
#     unrelated failure.
J_EXP=$(mktemp -d "${TMPDIR:-/tmp}/cfvsmoke_j.XXXXXX")
: > "$J_EXP/RESULTS.md"
if out=$(env -u BASH_ENV -u AUDIT_VERIFIER_CMD PATH="$FAKEBIN:$PATH" OPENAI_API_KEY=fake-key FAKE_CODEX_FAILURE=generic AAR_SUBSTRATE=claude bash "$AE" "$J_EXP" 2>&1); then
  err "(j) non-quota failure did not block: $out"
else
  echo "$out" | grep -qi 'API-BILLED' && err "(j) non-quota failure incorrectly triggered the apikey fallback: $out"
fi
rm -rf "$J_EXP" "$FAKEBIN"

[ "$fail" = 0 ] && echo "  ok: cross_family_verifier smoke (a-j)" >&2
exit "$fail"
