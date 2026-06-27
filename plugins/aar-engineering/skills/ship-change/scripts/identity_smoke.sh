#!/bin/bash
# identity_smoke.sh — unit-style smoke for wf.sh's strict engineer-identity policy (#109).
# Self-contained: fake gh, throwaway git repos, no network and no real tokens.
set -uo pipefail
unset BASH_ENV ENV
unset GH_TOKEN
unset WF_ENGINEER_TOKEN_CMD_CLAUDE WF_ENGINEER_TOKEN_CMD_CODEX WF_REVIEWER_TOKEN_CMD
unset WF_ENGINEER_GIT_AUTHOR_CLAUDE WF_ENGINEER_GIT_AUTHOR_CODEX
unset WF_ALLOW_AMBIENT_IDENTITY AUDIT_VERIFIER_CMD
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
REMOTE="$TMP/origin.git"; git init --bare -q "$REMOTE"

cat > "$TMP/bin/gh" <<'EOF'
#!/bin/bash
set -u
printf '%s\n' "$*" >> "${GH_FAKE_LOG:-/dev/null}"
while true; do
  case "${1:-}" in
    -R|--repo) shift 2 ;;
    -R=*|--repo=*) shift ;;
    *) break ;;
  esac
done
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
  issue)
    case "${2:-}" in
      create) echo "https://github.com/example/repo/issues/7"; exit 0 ;;
      comment) echo "comment-ok"; exit 0 ;;
      *) echo "fake gh: unsupported issue $*" >&2; exit 1 ;;
    esac ;;
  pr)
    case "${2:-}" in
      view) echo "7"; exit 0 ;;
      comment) cat >/dev/null; echo "comment-ok"; exit 0 ;;
      *) echo "fake gh: unsupported pr $*" >&2; exit 1 ;;
    esac ;;
  *) echo "fake gh: unsupported $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export GH_FAKE_LOG="$TMP/gh.log"

REPO="$TMP/repo"; mkdir -p "$REPO/proposals"
( cd "$REPO" && git init -q && git remote add origin https://github.com/example/repo.git )
( cd "$REPO" && git remote set-url --push origin "file://$REMOTE" )
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

echo "=== explicit ambient override: issue create/comment leave trail calls ==="
: > "$GH_FAKE_LOG"
out=$(GH_TOKEN=ambient-token \
  WF_ALLOW_AMBIENT_IDENTITY=1 \
  bash "$WF" issue codex create -R example/repo -t title -b body 2>&1); rc=$?
echo "$out"
check "issue create exits zero under explicit ambient override" "[ $rc -eq 0 ]"
check "issue create prints created URL" "grep -q 'https://github.com/example/repo/issues/7' <<<\"\$out\""
check "issue create posts override trail to created issue" "grep -q 'issue comment 7 -R example/repo --body-file -' \"$GH_FAKE_LOG\""
: > "$GH_FAKE_LOG"
out=$(GH_TOKEN=ambient-token \
  WF_ALLOW_AMBIENT_IDENTITY=1 \
  bash "$WF" issue codex comment -R example/repo 8 -b body 2>&1); rc=$?
echo "$out"
check "issue comment exits zero under explicit ambient override" "[ $rc -eq 0 ]"
check "issue comment posts override trail to parsed issue number" "grep -q 'issue comment 8 -R example/repo --body-file -' \"$GH_FAKE_LOG\""

cat > "$TMP/fake-audit.sh" <<'EOF'
#!/bin/bash
set -uo pipefail
out=${4:?review-output}
{
  printf 'AAR_SUBSTRATE=%s\n' "${AAR_SUBSTRATE-}"
  printf 'AUDIT_VERIFIER_CMD=%s\n' "${AUDIT_VERIFIER_CMD-<unset>}"
  printf 'BASH_ENV=%s\n' "${BASH_ENV-<unset>}"
} > "${FAKE_AUDIT_LOG:?}"
cat > "$out" <<'REVIEW'
SUMMARY: high=0 med=0 low=0
REVIEW
EOF
chmod +x "$TMP/fake-audit.sh"

cat > "$TMP/bad-bash-env.sh" <<'EOF'
export AUDIT_VERIFIER_CMD='claude -p "poisoned from BASH_ENV" > "$OUT_TMP"'
EOF

REVIEW_REPO="$TMP/review-repo"; mkdir -p "$REVIEW_REPO/proposals"
( cd "$REVIEW_REPO" && git init -q && git remote add origin https://github.com/example/repo.git )
( cd "$REVIEW_REPO" && git remote set-url --push origin "file://$REMOTE" )
cat > "$REVIEW_REPO/AGENTS.md" <<'EOF'
# test constitution
EOF
( cd "$REVIEW_REPO" && git add AGENTS.md && git commit -qm base && git push -q -u origin main && git checkout -q -b change/review )
cat > "$REVIEW_REPO/proposals/1-review.md" <<'EOF'
# Proposal: review test (#1)

## Problem

test

## Approach

test
EOF
( cd "$REVIEW_REPO" && git add proposals/1-review.md && git commit -qm "design: review test" )

echo "=== author-aware review env: claude author strips same-family verifier and BASH_ENV ==="
: > "$GH_FAKE_LOG"; FAKE_AUDIT_LOG="$TMP/audit-claude.env"
out=$(GH_TOKEN=ambient-token \
  WF_ENGINEER_TOKEN_CMD_CLAUDE='printf claude-token' \
  WF_ENGINEER_TOKEN_CMD_CODEX='printf codex-token' \
  AUDIT_EXPERIMENT="$TMP/fake-audit.sh" \
  BASH_ENV="$TMP/bad-bash-env.sh" \
  FAKE_AUDIT_LOG="$FAKE_AUDIT_LOG" \
  bash "$WF" design-review "$REVIEW_REPO" claude 2>&1); rc=$?
echo "$out"; cat "$FAKE_AUDIT_LOG"
check "claude-authored design-review exits zero under poisoned BASH_ENV" "[ $rc -eq 0 ]"
check "claude-authored review logs the stripped same-family verifier" "grep -q 'ignoring same-family AUDIT_VERIFIER_CMD' <<<\"\$out\""
check "claude-authored audit saw author family" "grep -q '^AAR_SUBSTRATE=claude$' \"$FAKE_AUDIT_LOG\""
check "claude-authored audit saw empty verifier override" "grep -q '^AUDIT_VERIFIER_CMD=$' \"$FAKE_AUDIT_LOG\""
check "claude-authored audit saw empty BASH_ENV" "grep -q '^BASH_ENV=$' \"$FAKE_AUDIT_LOG\""

echo "=== author-aware review env: codex author keeps Claude verifier but still clears BASH_ENV ==="
: > "$GH_FAKE_LOG"; FAKE_AUDIT_LOG="$TMP/audit-codex.env"
out=$(GH_TOKEN=ambient-token \
  WF_ENGINEER_TOKEN_CMD_CLAUDE='printf claude-token' \
  WF_ENGINEER_TOKEN_CMD_CODEX='printf codex-token' \
  AUDIT_EXPERIMENT="$TMP/fake-audit.sh" \
  AUDIT_VERIFIER_CMD='claude -p "$(cat)" > "$OUT_TMP"' \
  BASH_ENV="$TMP/bad-bash-env.sh" \
  FAKE_AUDIT_LOG="$FAKE_AUDIT_LOG" \
  bash "$WF" design-review "$REVIEW_REPO" codex 2>&1); rc=$?
echo "$out"; cat "$FAKE_AUDIT_LOG"
check "codex-authored design-review exits zero with Claude verifier" "[ $rc -eq 0 ]"
check "codex-authored audit kept a Claude verifier" "grep -q '^AUDIT_VERIFIER_CMD=.*claude' \"$FAKE_AUDIT_LOG\""
check "codex-authored audit saw empty BASH_ENV" "grep -q '^BASH_ENV=$' \"$FAKE_AUDIT_LOG\""

echo "=== invalid model reviewer: doctor rejects Codex-family verifier for Codex author ==="
out=$(GH_TOKEN=ambient-token \
  WF_ENGINEER_TOKEN_CMD_CODEX='printf codex-token' \
  WF_ENGINEER_TOKEN_CMD_CLAUDE='printf claude-token' \
  WF_ENGINEER_GIT_AUTHOR_CODEX='Codex Engineer <codex@example.com>' \
  AUDIT_VERIFIER_CMD='codex exec --sandbox read-only' \
  bash "$WF" doctor codex "$REPO" 2>&1); rc=$?
echo "$out"
check "doctor exits nonzero for Codex-family verifier on Codex-authored reviews" "[ $rc -ne 0 ]"
check "doctor reports invalid model reviewer" "grep -q 'model reviewer: invalid' <<<\"\$out\""

echo
[ "$fail" = 0 ] && { echo "identity smoke: ALL PASS"; exit 0; } || { echo "identity smoke: FAILURES" >&2; exit 1; }
