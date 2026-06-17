#!/bin/bash
# classify.sh — record whether a scaffold change is MECHANICAL or ARCHITECTURAL, WITH EVIDENCE.
#
# Architectural = needs the human (PM)'s design approval; mechanical = the agents merge it on the cross-family
# review + checks alone. FAIL-CLOSED: a change defaults to ARCHITECTURAL unless it is explicitly marked
# mechanical — a mislabel can never silently skip the human gate.
#
# TWO sources of "always architectural", checked together:
#   1. A NON-CONFIGURABLE protected floor (hardcoded below) — the CI policy itself, the constitution, the secrets
#      gate. The adjustable config CANNOT remove these, so a change to the policy can't downgrade itself (the
#      self-referential bypass a review caught). The config can only ADD more.
#   2. The adjustable .aar-ci/classifier.conf — a plain glob-per-line DATA file (PARSED, never sourced, so it
#      has no code-execution surface and cannot weaken the floor) — the tunable part.
#
# Usage: classify.sh [--mechanical "<reason>"] <changed-path>...
#   --mechanical "<reason>" downgrades to mechanical, recorded with the reason — honored ONLY if no
#   always-architectural path (floor or config) fired (you can't downgrade a constitution/policy change).
# Output: "CLASSIFICATION: architectural|mechanical" + "EVIDENCE: ...". ALWAYS exits 0 — it RECORDS, never blocks.
set -uo pipefail

# 1. the non-configurable protected floor (the config cannot remove these)
PROTECTED_FLOOR=(
  '.aar-ci/*'           # the CI policy + this classifier itself
  '.githooks/*'         # the secrets gate
  'CLAUDE.md' 'AGENTS.md' '*/CLAUDE.md' '*/AGENTS.md'   # the constitution
)

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

# 2. the adjustable config is ADDITIVE-ONLY and must NOT be able to weaken the floor. We do NOT execute it as
#    shell — a sourced config is arbitrary code (it could `PROTECTED_FLOOR=()` to empty the "non-configurable"
#    floor, or run a `$(...)` side effect just by being read). Instead the config is a plain DATA file: one
#    glob pattern per line, `#` comments and blank lines ignored. We PARSE it (never execute it), so its
#    content is only ever matched as a glob — there is no code-execution surface at all, and it can only ADD
#    architectural globs, never touch the floor.
ALWAYS_ARCHITECTURAL=()
CONF="$ROOT/.aar-ci/classifier.conf"
if [ -f "$CONF" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"                              # strip trailing/whole-line comments
    line="${line#"${line%%[![:space:]]*}"}"         # ltrim
    line="${line%"${line##*[![:space:]]}"}"         # rtrim
    [ -n "$line" ] && ALWAYS_ARCHITECTURAL+=("$line")
  done < "$CONF"
fi

# the effective always-architectural set = floor (always, never weakenable) + config (additive)
EFFECTIVE=("${PROTECTED_FLOOR[@]}" "${ALWAYS_ARCHITECTURAL[@]}")

# parse a --mechanical override (a missing/empty reason is just ignored -> fail-closed, never aborts)
MECH_REASON=""
if [ "${1:-}" = "--mechanical" ]; then MECH_REASON="${2:-}"; shift; [ $# -gt 0 ] && shift; fi

PATHS=("$@")
if [ ${#PATHS[@]} -eq 0 ]; then
  echo "CLASSIFICATION: architectural"
  echo "EVIDENCE: no changed paths given -> fail-closed to architectural"
  exit 0
fi

# normalize every input to a repo-relative path so a protected file can't dodge the globs by being passed as
# ./AGENTS.md, from a subdir, or as an absolute path (the globs are repo-relative; git diff --name-only is too,
# but a caller may not be). Strip a leading ./ and rebase an under-$ROOT absolute path onto $ROOT.
norm=()
for p in "${PATHS[@]}"; do
  q="${p#./}"
  case "$q" in "$ROOT"/*) q="${q#"$ROOT"/}";; esac
  norm+=("$q")
done
PATHS=("${norm[@]}")

# hard rules: any changed path matching the effective always-architectural set => architectural (can't downgrade)
hits=()
for p in "${PATHS[@]}"; do
  for g in "${EFFECTIVE[@]}"; do
    # shellcheck disable=SC2254
    case "$p" in $g) hits+=("$p matches '$g'");; esac
  done
done

if [ ${#hits[@]} -gt 0 ]; then
  echo "CLASSIFICATION: architectural"
  printf 'EVIDENCE: always-architectural — %s\n' "${hits[@]}"
  [ -n "$MECH_REASON" ] && echo "EVIDENCE: --mechanical override IGNORED — an always-architectural path can't be downgraded"
  exit 0
fi

# No always-architectural path fired.
if [ -n "$MECH_REASON" ]; then
  echo "CLASSIFICATION: mechanical"
  echo "EVIDENCE: no always-architectural path; explicitly downgraded by reviewer — $MECH_REASON"
else
  echo "CLASSIFICATION: architectural"
  echo "EVIDENCE: no always-architectural path matched, and not explicitly marked mechanical (or no reason given) -> fail-closed default (architectural)"
fi
exit 0
