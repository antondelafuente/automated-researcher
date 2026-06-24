#!/bin/bash
# identity_smoke.sh — unit-style smoke for wf.sh's strict engineer-identity policy (#109).
# Self-contained: fake gh, throwaway git repos, no network and no real tokens.
set -uo pipefail
WF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wf.sh
[ -f "$WF" ] || { echo "FAIL: wf.sh not found next to smoke" >&2; exit 1; }

fail=0
check(){ if eval "$2"; then echo "  PASS: $1"; else echo "  FAIL: $1" >&2; fail=1; fi; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/identity-smoke.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME" "$TMP/bin"
export GIT_CONFIG_GLOBAL="$TMP/gitconfig"; : > "$GIT_CONFIG_GLOBAL"
git config --global user.email smoke@example.com
git config --global user.name smoke
git config --global init.defaultBranch main

cat > "$TMP/bin/gh" <<'EOF'
#!/bin/bash
set -u
case "${1:-}" in
  auth)
    [ "${2:-}" = status ] && [ -n "${GH_TOKEN:-}" ] && exit 0
    exit 1 ;;
  api)
    target=${2:-}
    case "$target" in
      user)
        [ "${GH_TOKEN:-}" = ambient-token ] && { echo ambient-owner; exit 0; }
        exit 1 ;;
      repos/example/repo)
        case "${GH_TOKEN:-}" in
          ambient-token|codex-token|claude-token) echo example/repo; exit 0 ;;
          *) exit 1 ;;
        esac ;;
      *) exit 1 ;;
    esac ;;
  *) echo "fake gh: unsupported $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

REPO="$TMP/repo"; mkdir -p "$REPO/proposals"
( cd "$REPO" && git init -q && git remote add origin https://github.com/example/repo.git )
cat > "$REPO/proposals/1-test.md" <<'EOF'
# Proposal: test (#1)

## Problem

test

## Approach

test
EOF
( cd "$REPO" && git add proposals/1-test.md && git commit -qm init )
printf '\nchanged for open\n' >> "$REPO/proposals/1-test.md"

echo "=== missing engineer env: doctor blocks and names the missing seams ==="
out=$(GH_TOKEN=ambient-token bash "$WF" doctor codex "$REPO" 2>&1); rc=$?
echo "$out"
check "doctor exits nonzero without engineer token env" "[ $rc -ne 0 ]"
check "doctor names missing Codex token seam" "grep -q 'WF_ENGINEER_TOKEN_CMD_CODEX' <<<\"\$out\""
check "doctor names missing Claude reviewer token seam" "grep -q 'WF_ENGINEER_TOKEN_CMD_CLAUDE' <<<\"\$out\""
check "doctor names ambient fallback hatch" "grep -q 'WF_ALLOW_AMBIENT_IDENTITY=1' <<<\"\$out\""

echo "=== protected open blocks before ambient owner fallback ==="
out=$(GH_TOKEN=ambient-token bash "$WF" open "$REPO" codex 2>&1); rc=$?
echo "$out"
check "open exits nonzero without engineer token env" "[ $rc -ne 0 ]"
check "open failure names the token seam" "grep -q 'WF_ENGINEER_TOKEN_CMD_CODEX' <<<\"\$out\""
check "open failure names the ambient override" "grep -q 'WF_ALLOW_AMBIENT_IDENTITY=1' <<<\"\$out\""

echo "=== configured engineer env: doctor is ready ==="
out=$(GH_TOKEN=ambient-token \
  WF_ENGINEER_TOKEN_CMD_CODEX='printf codex-token' \
  WF_ENGINEER_TOKEN_CMD_CLAUDE='printf claude-token' \
  WF_ENGINEER_GIT_AUTHOR_CODEX='Codex Engineer <codex@example.com>' \
  AUDIT_VERIFIER_CMD='claude -p "$(cat)" > "$OUT_TMP"' \
  bash "$WF" doctor codex "$REPO" 2>&1); rc=$?
echo "$out"
check "doctor exits zero with engineer token env" "[ $rc -eq 0 ]"
check "doctor reports ready" "grep -q '^READY:' <<<\"\$out\""

echo "=== explicit ambient override: doctor proceeds with ambient gh ==="
out=$(GH_TOKEN=ambient-token \
  WF_ALLOW_AMBIENT_IDENTITY=1 \
  AUDIT_VERIFIER_CMD='claude -p "$(cat)" > "$OUT_TMP"' \
  bash "$WF" doctor codex "$REPO" 2>&1); rc=$?
echo "$out"
check "doctor exits zero under explicit ambient override" "[ $rc -eq 0 ]"
check "doctor reports ambient fallback enabled" "grep -q 'ambient workflow fallback: ENABLED' <<<\"\$out\""
check "doctor reports ready under override" "grep -q '^READY:' <<<\"\$out\""

echo
[ "$fail" = 0 ] && { echo "identity smoke: ALL PASS"; exit 0; } || { echo "identity smoke: FAILURES" >&2; exit 1; }
