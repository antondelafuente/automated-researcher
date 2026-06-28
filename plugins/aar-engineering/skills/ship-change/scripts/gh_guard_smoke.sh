#!/bin/bash
# gh_guard_smoke.sh — behavior smoke for the gh write-guard wrapper + the wf.sh bypass contract (#165).
#
# Proves ALL directions with a FAKE gh on PATH (no network):
#   reads pass; bare writes are blocked; credential-mutating `gh auth` is blocked; the whitelisted non-mutating
#   `gh auth` helper forms pass; `gh api` is default-deny on a non-GET method/body; the WF_GH_INTERNAL marker
#   and WF_GH_ALLOW_OWNER_WRITE override pass through; and the ACTUAL wf.sh internal paths survive the guard
#   (real_gh review/comment/classify shapes + git_push_author against a HOSTILE ambient credential helper, where
#   the forced tokenized URL must win). Also asserts the static check passes on the real wf.sh and fails on a
#   planted unmarked call.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GUARD="$HERE/gh-guard.sh"
WF="$HERE/wf.sh"
STATIC="$HERE/gh_guard_static_check.sh"
ROOT=$(cd "$HERE" && git rev-parse --show-toplevel 2>/dev/null || echo "$HERE/../../../../..")

fails=0
pass(){ echo "  ok: $1"; }
fail(){ echo "  FAIL: $1" >&2; fails=$((fails+1)); }

TMP=$(mktemp -d) || { echo "[smoke] FATAL: mktemp -d failed" >&2; exit 2; }
# fail closed if TMP is empty / not a dir BEFORE deriving any paths from it — under `set -uo pipefail` (no
# -e) an empty $TMP would otherwise make `$TMP/bin` resolve to /bin and a later symlink target /bin/gh.
case "$TMP" in /*) : ;; *) echo "[smoke] FATAL: mktemp -d returned a non-absolute path '$TMP'" >&2; exit 2 ;; esac
[ -d "$TMP" ] || { echo "[smoke] FATAL: TMP '$TMP' is not a directory" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT

# --- a FAKE real gh: records the args it was called with, always succeeds. The guard resolves it via WF_REAL_GH.
FAKE_GH="$TMP/real_gh_fake.sh"
cat > "$FAKE_GH" <<'EOF'
#!/bin/bash
# fake gh — log the invocation so the smoke can assert the guard let it through, then succeed.
echo "FAKE_GH_CALLED: $*" >> "$FAKE_GH_LOG"
# emulate `gh auth git-credential get` so git's credential helper path can use it
if [ "${1:-}" = auth ] && [ "${2:-}" = git-credential ]; then
  cat >/dev/null 2>&1 || true
  printf 'protocol=https\nhost=github.com\nusername=x-access-token\npassword=FAKE_AMBIENT\n'
fi
exit 0
EOF
chmod +x "$FAKE_GH"
export WF_REAL_GH="$FAKE_GH"
export FAKE_GH_LOG="$TMP/gh.log"; : > "$FAKE_GH_LOG"

# run the GUARD with a given env; returns the guard's rc
guard(){ bash "$GUARD" "$@"; }

echo "[smoke] direction matrix"

# 1. a read passes through (and reaches the fake gh)
: > "$FAKE_GH_LOG"
if guard pr view 1 >/dev/null 2>&1 && grep -q 'FAKE_GH_CALLED: pr view 1' "$FAKE_GH_LOG"; then pass "read 'pr view' passes through"; else fail "read 'pr view' should pass through"; fi
: > "$FAKE_GH_LOG"
if guard issue list >/dev/null 2>&1 && grep -q 'FAKE_GH_CALLED: issue list' "$FAKE_GH_LOG"; then pass "read 'issue list' passes"; else fail "read 'issue list' should pass"; fi

# 2. a bare write is BLOCKED (does NOT reach the fake gh)
: > "$FAKE_GH_LOG"
if ! guard issue create -t x -b y >/dev/null 2>&1 && ! grep -q FAKE_GH_CALLED "$FAKE_GH_LOG"; then pass "bare 'issue create' blocked"; else fail "bare 'issue create' should be blocked"; fi
: > "$FAKE_GH_LOG"
if ! guard pr comment 1 -b hi >/dev/null 2>&1; then pass "bare 'pr comment' blocked"; else fail "bare 'pr comment' should be blocked"; fi
# 2b. the -R owner/repo form must NOT bypass the guard (review F1: -R's value was mis-read as the subcommand)
: > "$FAKE_GH_LOG"
if ! guard -R o/r pr comment 1 -b hi >/dev/null 2>&1 && ! grep -q FAKE_GH_CALLED "$FAKE_GH_LOG"; then pass "'gh -R o/r pr comment' blocked (no -R bypass)"; else fail "'gh -R o/r pr comment' must be blocked"; fi
: > "$FAKE_GH_LOG"
if ! guard --repo o/r issue create -t x >/dev/null 2>&1; then pass "'gh --repo o/r issue create' blocked (no --repo bypass)"; else fail "'gh --repo o/r issue create' must be blocked"; fi
# 2c. but a -R READ still passes
: > "$FAKE_GH_LOG"
if guard -R o/r pr view 1 >/dev/null 2>&1 && grep -q 'pr view 1' "$FAKE_GH_LOG"; then pass "'gh -R o/r pr view' passes (read)"; else fail "'gh -R o/r pr view' should pass"; fi
# 2e. `gh issue develop` CREATES a branch (write) unless --list (review F2)
: > "$FAKE_GH_LOG"
if ! guard issue develop 123 >/dev/null 2>&1 && ! grep -q FAKE_GH_CALLED "$FAKE_GH_LOG"; then pass "'gh issue develop' blocked (creates a branch)"; else fail "'gh issue develop' must be blocked"; fi
: > "$FAKE_GH_LOG"
if guard issue develop 123 --list >/dev/null 2>&1 && grep -q 'issue develop' "$FAKE_GH_LOG"; then pass "'gh issue develop --list' passes (read)"; else fail "'gh issue develop --list' should pass"; fi
# 2f. `gh pr checkout` is local-only -> passes (review F3)
: > "$FAKE_GH_LOG"
if guard pr checkout 5 >/dev/null 2>&1 && grep -q 'pr checkout 5' "$FAKE_GH_LOG"; then pass "'gh pr checkout' passes (local-only)"; else fail "'gh pr checkout' should pass"; fi
# 2d. the blocked message must NOT echo the raw argv (review F3: bodies/tokens must not leak). Capture the
# guard's output first (the guard exits non-zero; neutralize it with `|| true`), THEN grep the captured text
# separately — a `guard … | grep` pipeline would be masked by pipefail/`!` and always pass (review F2).
LEAK_OUT=$(guard pr comment 1 -b 'SECRET_BODY_TEXT' 2>&1 || true)
if ! printf '%s' "$LEAK_OUT" | grep -q 'SECRET_BODY_TEXT'; then pass "blocked message does not leak the raw argv"; else fail "blocked message leaked the raw argv (F3)"; fi
: > "$FAKE_GH_LOG"
if ! guard pr merge 1 --squash >/dev/null 2>&1; then pass "bare 'pr merge' blocked"; else fail "bare 'pr merge' should be blocked"; fi
: > "$FAKE_GH_LOG"
if ! guard issue close 1 >/dev/null 2>&1; then pass "bare 'issue close' blocked"; else fail "bare 'issue close' should be blocked"; fi

# 3. credential-mutating gh auth blocked; whitelisted forms pass
: > "$FAKE_GH_LOG"
if ! guard auth login >/dev/null 2>&1; then pass "'gh auth login' blocked"; else fail "'gh auth login' should be blocked"; fi
if ! guard auth refresh >/dev/null 2>&1; then pass "'gh auth refresh' blocked"; else fail "'gh auth refresh' should be blocked"; fi
if ! guard auth setup-git >/dev/null 2>&1; then pass "'gh auth setup-git' blocked"; else fail "'gh auth setup-git' should be blocked"; fi
if ! guard auth logout >/dev/null 2>&1; then pass "'gh auth logout' blocked"; else fail "'gh auth logout' should be blocked"; fi
: > "$FAKE_GH_LOG"
if guard auth status >/dev/null 2>&1 && grep -q 'FAKE_GH_CALLED: auth status' "$FAKE_GH_LOG"; then pass "'gh auth status' passes (whitelisted)"; else fail "'gh auth status' should pass"; fi
: > "$FAKE_GH_LOG"
if guard auth token >/dev/null 2>&1 && grep -q 'FAKE_GH_CALLED: auth token' "$FAKE_GH_LOG"; then pass "'gh auth token' passes (whitelisted)"; else fail "'gh auth token' should pass"; fi
: > "$FAKE_GH_LOG"
if echo | guard auth git-credential get >/dev/null 2>&1 && grep -q 'FAKE_GH_CALLED: auth git-credential' "$FAKE_GH_LOG"; then pass "'gh auth git-credential' passes (whitelisted)"; else fail "'gh auth git-credential' should pass"; fi

# 4. gh api default-deny on method/body; GET passes
: > "$FAKE_GH_LOG"
if guard api repos/o/r >/dev/null 2>&1 && grep -q 'FAKE_GH_CALLED: api repos/o/r' "$FAKE_GH_LOG"; then pass "'gh api' GET passes"; else fail "'gh api' GET should pass"; fi
if ! guard api -X POST repos/o/r/issues >/dev/null 2>&1; then pass "'gh api -X POST' blocked"; else fail "'gh api -X POST' should be blocked"; fi
if ! guard api --method PATCH repos/o/r/pulls/1 -f body=x >/dev/null 2>&1; then pass "'gh api --method PATCH' blocked"; else fail "'gh api --method PATCH' should be blocked"; fi
if ! guard api repos/o/r/issues -f title=x >/dev/null 2>&1; then pass "'gh api' GET-with-body (-f) blocked (implicit POST)"; else fail "'gh api -f' should be blocked"; fi
if ! guard api graphql -f query='mutation{addComment}' >/dev/null 2>&1; then pass "'gh api graphql mutation' blocked"; else fail "graphql mutation should be blocked"; fi
# default-DENY: a graphql call carrying ANY body is blocked (a mutation can hide in --input/file-backed
# fields where the literal text isn't in argv) — review F1.
if ! guard api graphql -f query='query{viewer{login}}' >/dev/null 2>&1; then pass "'gh api graphql' inline-query body blocked (default-deny)"; else fail "graphql body should be blocked (default-deny)"; fi
if ! guard api graphql --input mut.json >/dev/null 2>&1; then pass "'gh api graphql --input' blocked (mutation can hide in the file)"; else fail "graphql --input should be blocked"; fi
# a graphql call with NO body is a harmless read (rare; passes)
: > "$FAKE_GH_LOG"
if guard api graphql >/dev/null 2>&1; then pass "'gh api graphql' (no body) passes"; else fail "graphql with no body should pass"; fi

# 5. the WF_GH_INTERNAL marker passes a WRITE straight through
: > "$FAKE_GH_LOG"
if WF_GH_INTERNAL=1 guard issue create -t x -b y >/dev/null 2>&1 && grep -q 'FAKE_GH_CALLED: issue create' "$FAKE_GH_LOG"; then pass "WF_GH_INTERNAL marker passes a write"; else fail "WF_GH_INTERNAL marker should pass a write"; fi
: > "$FAKE_GH_LOG"
if WF_GH_INTERNAL=1 guard auth login >/dev/null 2>&1 && grep -q 'FAKE_GH_CALLED: auth login' "$FAKE_GH_LOG"; then pass "WF_GH_INTERNAL passes even gh auth login"; else fail "WF_GH_INTERNAL should pass gh auth login"; fi

# 6. WF_GH_ALLOW_OWNER_WRITE override passes a write (with a logged note)
: > "$FAKE_GH_LOG"
if WF_GH_ALLOW_OWNER_WRITE=1 guard issue create -t x -b y 2>/dev/null >/dev/null && grep -q 'FAKE_GH_CALLED: issue create' "$FAKE_GH_LOG"; then pass "WF_GH_ALLOW_OWNER_WRITE override passes a write"; else fail "owner-write override should pass a write"; fi
if WF_GH_ALLOW_OWNER_WRITE=1 guard issue create -t x -b y 2>&1 >/dev/null | grep -q 'owner-maintenance override'; then pass "owner-write override emits a logged note"; else fail "owner-write override should log a note"; fi

echo "[smoke] wf.sh internal paths survive the guard (real_gh + a guard ahead of gh on PATH)"
# Put the GUARD ahead of the real gh on PATH (as install would). The fake real gh is found via WF_REAL_GH.
GBIN="$TMP/bin"; mkdir -p "$GBIN"; ln -sf "$GUARD" "$GBIN/gh"
run_wf_helper(){
  # source wf.sh's helpers in a subshell with the guard on PATH, then call real_gh / a wf-shaped invocation.
  PATH="$GBIN:$PATH" bash -c '
    set -uo pipefail
    # extract just the helper defs we need by sourcing wf.sh up to its dispatch is hard; instead define a
    # minimal real_gh exactly as wf.sh does and confirm it bypasses the guard on PATH.
    real_gh(){ WF_GH_INTERNAL=1 gh "$@"; }
    : > "$FAKE_GH_LOG"
    real_gh api -X POST repos/o/r/pulls/1/reviews -f event=APPROVE >/dev/null 2>&1 || exit 7
    grep -q "FAKE_GH_CALLED: api -X POST" "$FAKE_GH_LOG" || exit 8
    : > "$FAKE_GH_LOG"
    echo body | real_gh -R o/r pr comment 1 --body-file - >/dev/null 2>&1 || exit 9
    grep -q "pr comment 1" "$FAKE_GH_LOG" || exit 10
    : > "$FAKE_GH_LOG"
    real_gh api --method PATCH repos/o/r/pulls/1 -f body=x >/dev/null 2>&1 || exit 11
    grep -q "FAKE_GH_CALLED: api --method PATCH" "$FAKE_GH_LOG" || exit 12
  '
}
export FAKE_GH_LOG
if run_wf_helper; then pass "wf.sh real_gh review/comment/classify(PATCH) shapes pass the guard on PATH"; else fail "wf.sh real_gh shapes did not survive the guard (rc=$?)"; fi

echo "[smoke] git_push_author forces the engineer credential over a HOSTILE ambient helper"
# Build a local bare 'remote' and a clone; set a HOSTILE ambient credential helper that would authenticate as
# the owner. Then call wf.sh's git_push_author with an engineer token; the forced tokenized URL + cleared
# helper must make the push use the engineer credential, not the hostile helper.
GITTEST="$TMP/gittest"; mkdir -p "$GITTEST"
( cd "$GITTEST"
  git init -q --bare remote.git
  git clone -q remote.git work 2>/dev/null
  cd work
  git config user.email e@x; git config user.name n
  echo hi > f; git add f; git commit -qm init
  # point origin at an HTTPS-looking url so git_push_author's tokenized-URL rewrite path runs, but make the
  # rewritten host resolve to our LOCAL bare repo via insteadOf. The token must ride into the URL.
  git remote set-url origin https://github.com/o/r.git
) >/dev/null 2>&1
# extract git_push_author from wf.sh and run it with the guard on PATH + a hostile credential helper present.
PUSH_OUT=$(PATH="$GBIN:$PATH" GIT_TERMINAL_PROMPT=0 bash -c '
  set -uo pipefail
  WT="'"$GITTEST/work"'"
  # a HOSTILE helper: would supply an OWNER credential for any github.com push.
  git -C "$WT" config --add credential.helper "!f(){ echo username=owner; echo password=HOSTILE_OWNER; }; f"
  # redirect the tokenized github URL to our local bare repo so the push has somewhere to land, regardless of
  # which credential is used (we assert via the URL the engineer token rode in, not auth acceptance).
  git -C "$WT" config url."'"$GITTEST"'/remote.git".insteadOf "https://x-access-token:ENGINEER_TOKEN@github.com/o/r.git"
  # define git_push_author EXACTLY as wf.sh does by sourcing the function out of wf.sh.
  WF="'"$WF"'"
  # pull the function definition block (real_gh + git_push_author) out of wf.sh and eval it.
  eval "$(sed -n "/^real_gh()/,/^}/p; /^git_push_author()/,/^}/p" "$WF")"
  git_push_author ENGINEER_TOKEN "$WT" -q origin HEAD:refs/heads/pushed 2>&1
  # confirm the push landed in the LOCAL bare repo (proves the tokenized URL + insteadOf path ran)
  git -C "'"$GITTEST"'/remote.git" rev-parse --verify -q refs/heads/pushed >/dev/null && echo PUSH_LANDED
' 2>&1)
if printf '%s' "$PUSH_OUT" | grep -q PUSH_LANDED; then pass "git_push_author push landed via the forced tokenized engineer URL"; else fail "git_push_author forced-credential push failed: $PUSH_OUT"; fi

# an SSH-form github remote (review F2) must ALSO normalize to the tokenized HTTPS push, not fall back to
# ambient SSH. Same insteadOf trick redirects the normalized URL to the local bare repo.
( cd "$GITTEST/work"; git remote set-url origin ssh://git@github.com/o/r.git ) >/dev/null 2>&1
PUSH_OUT_SSH=$(PATH="$GBIN:$PATH" GIT_TERMINAL_PROMPT=0 bash -c '
  set -uo pipefail
  WT="'"$GITTEST/work"'"
  git -C "$WT" config url."'"$GITTEST"'/remote.git".insteadOf "https://x-access-token:ENGINEER_TOKEN@github.com/o/r.git"
  eval "$(sed -n "/^real_gh()/,/^}/p; /^git_push_author()/,/^}/p" "'"$WF"'")"
  git_push_author ENGINEER_TOKEN "$WT" -q origin HEAD:refs/heads/pushed_ssh 2>&1
  git -C "'"$GITTEST"'/remote.git" rev-parse --verify -q refs/heads/pushed_ssh >/dev/null && echo PUSH_LANDED_SSH
' 2>&1)
if printf '%s' "$PUSH_OUT_SSH" | grep -q PUSH_LANDED_SSH; then pass "git_push_author normalizes an ssh:// github remote to the tokenized push (F2)"; else fail "ssh:// github remote push failed: $PUSH_OUT_SSH"; fi

# a `-u`/`--set-upstream` push must NOT persist the tokenized URL (the TOKEN) into .git/config (review HIGH).
( cd "$GITTEST/work"; git remote set-url origin https://github.com/o/r.git ) >/dev/null 2>&1
PUSH_OUT_U=$(PATH="$GBIN:$PATH" GIT_TERMINAL_PROMPT=0 bash -c '
  set -uo pipefail
  WT="'"$GITTEST/work"'"
  git -C "$WT" config url."'"$GITTEST"'/remote.git".insteadOf "https://x-access-token:ENGINEER_TOKEN@github.com/o/r.git"
  eval "$(sed -n "/^real_gh()/,/^}/p; /^git_push_author()/,/^}/p" "'"$WF"'")"
  git_push_author ENGINEER_TOKEN "$WT" -q -u origin "$(git -C "$WT" rev-parse --abbrev-ref HEAD)" 2>&1
  # dump the on-disk config so the smoke can assert the token is absent and upstream points at named origin
  echo "---CONFIG---"
  # exclude the test-harness insteadOf line (which intentionally carries the token to redirect the push to the
  # local bare repo) — we only care whether git_push_author PERSISTED a token-bearing remote/upstream entry.
  git -C "$WT" config --local --list | grep -v "^url\."
' 2>&1)
if printf '%s' "$PUSH_OUT_U" | grep -q 'ENGINEER_TOKEN'; then fail "-u push PERSISTED the engineer token into .git/config (HIGH): $PUSH_OUT_U"; else pass "-u push does NOT persist the token into .git/config"; fi
CURBR=$(git -C "$GITTEST/work" rev-parse --abbrev-ref HEAD)
if printf '%s' "$PUSH_OUT_U" | grep -q "branch.${CURBR}.remote=origin"; then pass "-u push sets upstream to the NAMED origin remote (not a URL)"; else fail "-u push did not set upstream to named origin: $PUSH_OUT_U"; fi

echo "[smoke] git_push_author only treats real github.com as a github remote (review F2)"
# a look-alike host (suffix github.com) must NOT be rewritten to a tokenized github.com URL. Point origin at
# a local bare repo via an https://evilgithub.com/... url + insteadOf; the non-github branch pushes as-is.
( cd "$GITTEST/work"
  git remote set-url origin https://evilgithub.com/o/r.git
) >/dev/null 2>&1
EVIL_OUT=$(PATH="$GBIN:$PATH" GIT_TERMINAL_PROMPT=0 bash -c '
  set -uo pipefail
  WT="'"$GITTEST/work"'"
  # if the code WRONGLY rewrote to github.com, this insteadOf would catch the tokenized github url; since it
  # should NOT, we instead redirect the evilgithub url to the local bare repo.
  git -C "$WT" config url."'"$GITTEST"'/remote.git".insteadOf "https://evilgithub.com/o/r.git"
  eval "$(sed -n "/^real_gh()/,/^}/p; /^git_push_author()/,/^}/p" "'"$WF"'")"
  git_push_author ENGINEER_TOKEN "$WT" -q origin HEAD:refs/heads/pushed_evil 2>&1
  git -C "'"$GITTEST"'/remote.git" rev-parse --verify -q refs/heads/pushed_evil >/dev/null && echo PUSH_LANDED_EVIL
' 2>&1)
if printf '%s' "$EVIL_OUT" | grep -q PUSH_LANDED_EVIL; then pass "look-alike host (suffix github.com) is NOT rewritten to github.com (F2)"; else fail "look-alike host push failed (should push as-is): $EVIL_OUT"; fi

echo "[smoke] install-gh-guard refuses to clobber a non-guard gh (review F2)"
IBIN="$TMP/installbin"; mkdir -p "$IBIN"
# a pre-existing NON-guard gh in the install dir (e.g. a real binary the operator placed there)
printf '#!/bin/bash\necho not-the-guard\n' > "$IBIN/gh"; chmod +x "$IBIN/gh"
# put a real-ish gh elsewhere on PATH so install passes its "real gh exists" check, with the install dir LATER.
RBIN="$TMP/realbin"; mkdir -p "$RBIN"; printf '#!/bin/bash\necho realgh\n' > "$RBIN/gh"; chmod +x "$RBIN/gh"
INST_OUT=$(PATH="$RBIN:$PATH" bash "$WF" install-gh-guard "$IBIN" 2>&1); INST_RC=$?
if [ "$INST_RC" -ne 0 ] && [ "$(cat "$IBIN/gh")" = "$(printf '#!/bin/bash\necho not-the-guard')" ]; then pass "install-gh-guard refuses to overwrite a non-guard gh"; else fail "install-gh-guard should refuse a non-guard gh (rc=$INST_RC): $INST_OUT"; fi
# --force replaces it (now a symlink to the guard)
PATH="$RBIN:$PATH" bash "$WF" install-gh-guard "$IBIN" --force >/dev/null 2>&1
if [ -L "$IBIN/gh" ] && [ "$(readlink -f "$IBIN/gh")" = "$(readlink -f "$GUARD")" ]; then pass "install-gh-guard --force replaces a non-guard gh"; else fail "install-gh-guard --force should replace with the guard symlink"; fi
# idempotent re-install of our own symlink succeeds
if PATH="$RBIN:$PATH" bash "$WF" install-gh-guard "$IBIN" >/dev/null 2>&1; then pass "install-gh-guard is idempotent on its own symlink"; else fail "install-gh-guard should be idempotent on its own symlink"; fi
# re-install when the guard is ALREADY ACTIVE (gh resolves to $IBIN/gh first) must still succeed, not reject
# on the "real gh resolves inside the install dir" check (review F2).
if PATH="$IBIN:$RBIN:$PATH" bash "$WF" install-gh-guard "$IBIN" >/dev/null 2>&1; then pass "install-gh-guard succeeds when the guard is already active on PATH"; else fail "install-gh-guard should succeed (idempotent) when already active"; fi

echo "[smoke] static check: passes on real wf.sh, fails on a planted unmarked call"
if bash "$STATIC" "$ROOT" >/dev/null 2>&1; then pass "static check passes on the real wf.sh"; else fail "static check should pass on the real wf.sh"; fi
PLANT="$TMP/plantroot/plugins/aar-engineering/skills/ship-change/scripts"
mkdir -p "$PLANT"; cp "$WF" "$PLANT/wf.sh"; printf '\ngh pr merge 999 --squash\n' >> "$PLANT/wf.sh"
if ! bash "$STATIC" "$TMP/plantroot" >/dev/null 2>&1; then pass "static check FAILS on a planted unmarked gh call"; else fail "static check should fail on a planted unmarked gh call"; fi

echo
if [ "$fails" -eq 0 ]; then echo "[smoke] gh write-guard: ALL PASS"; exit 0; else echo "[smoke] gh write-guard: $fails FAILURE(S)" >&2; exit 1; fi
