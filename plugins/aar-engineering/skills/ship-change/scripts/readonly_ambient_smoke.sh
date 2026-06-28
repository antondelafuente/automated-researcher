#!/bin/bash
# readonly_ambient_smoke.sh — behavior smoke for the read-only-ambient detector (#166, child #2 of #149).
#
# Proves `wf.sh doctor … --readonly` (and the plain-doctor reporter) with a FAKE gh + git on PATH (no network):
#   - three API-surface fixtures via the provenance seam: authoritatively-read-only (PASS), write-capable
#     (FAIL), uninspectable/unattested (FAIL-CLOSED, not PASS);
#   - per-SOURCE isolation: a write-capable GITHUB_TOKEN is caught even behind a read-only GH_TOKEN;
#   - the ambient git-push surface: an auth-rejected --dry-run PASSes, an accepted --dry-run FAILs;
#   - NO fixture path performs a mutation (the fake gh/git record every call; we assert no write reaches them);
#   - the strict --readonly form EXITS NON-ZERO on FAIL, and 0 on PASS (the machine-consumable gate).
set -uo pipefail
# strip any inherited BASH_ENV/ENV so the wf.sh child shells don't source the instance env (same convention as
# identity_smoke.sh), AND any inherited WF_READONLY_* seam so a real instance minter never runs against the
# smoke's fake fixtures (#166 code-review F3) — keeps the smoke hermetic on any agent box. run_strict re-sets
# only WF_READONLY_TOKEN_INFO_CMD per fixture and explicitly clears WF_READONLY_TOKEN_CMD.
unset BASH_ENV ENV WF_READONLY_TOKEN_CMD WF_READONLY_TOKEN_INFO_CMD

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WF="$HERE/wf.sh"

fails=0
pass(){ echo "  ok: $1"; }
fail(){ echo "  FAIL: $1" >&2; fails=$((fails+1)); }

TMP=$(mktemp -d) || { echo "[smoke] FATAL: mktemp -d failed" >&2; exit 2; }
case "$TMP" in /*) : ;; *) echo "[smoke] FATAL: mktemp -d non-absolute '$TMP'" >&2; exit 2 ;; esac
[ -d "$TMP" ] || { echo "[smoke] FATAL: TMP '$TMP' not a dir" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT

BIN="$TMP/bin"; mkdir -p "$BIN"
MUTLOG="$TMP/mutations.log"; : > "$MUTLOG"
export READONLY_SMOKE_MUTLOG="$MUTLOG"

# --- a FAKE gh: classifies its own args; records any MUTATING call into MUTLOG; never hits the network. -----
# We need: `gh auth token` (stored cred), `gh auth status`, and `gh api -X PATCH …` (the advisory probe).
# The advisory probe's HTTP status is driven by env READONLY_SMOKE_API: "denied" -> 403, "writable" -> 422.
cat > "$BIN/gh" <<'EOF'
#!/bin/bash
# fake gh for the readonly-ambient smoke.
# find the subcommand + verb (skip a leading -R/--repo value and other flags crudely)
sub=""; verb=""
args=("$@")
i=0; n=${#args[@]}
while [ "$i" -lt "$n" ]; do
  a=${args[$i]}
  case "$a" in
    -R|--repo|-H|--hostname) i=$((i+2)); continue ;;
    -*) i=$((i+1)); continue ;;
    *) sub=$a; verb=${args[$((i+1))]:-}; break ;;
  esac
done
case "$sub" in
  auth)
    case "$verb" in
      token)  printf '%s\n' "${READONLY_SMOKE_STORED_TOKEN:-}" ; exit 0 ;;
      status) [ -n "${READONLY_SMOKE_STORED_TOKEN:-}" ] && exit 0 || exit 1 ;;
      *) exit 0 ;;
    esac
    ;;
  api)
    # detect a write method (the advisory PATCH probe). Record it as a MUTATION ATTEMPT (so the smoke can
    # assert the probe is the ONLY write-shaped call AND that it never actually mutates — a fake never mutates).
    method="GET"
    j=0; m=${#args[@]}
    while [ "$j" -lt "$m" ]; do
      case "${args[$j]}" in
        -X|--method) method=${args[$((j+1))]:-GET} ;;
        -X*) method=${args[$j]#-X} ;;
        --method=*) method=${args[$j]#--method=} ;;
      esac
      j=$((j+1))
    done
    mu=$(printf '%s' "$method" | tr '[:lower:]' '[:upper:]')
    if [ "$mu" != GET ] && [ "$mu" != HEAD ]; then
      # consume any --input body on stdin so the pipe doesn't break, and record the body shape for the
      # mutation-freedom assertion (the real detector pipes an empty '{}' object via --input -).
      body=""; for f in "${args[@]}"; do [ "$f" = "--input" ] && body=$(cat); done
      echo "API_WRITE_ATTEMPT: args=[$*] body=[$body]" >> "$READONLY_SMOKE_MUTLOG"
      # emulate the LIVE behavior proven against a disposable repo (#166 PR evidence): an empty-{} PATCH is
      # ACCEPTED (200, non-mutating) by a write-capable token; DENIED (403/404) for read-only/no-access.
      # Key off the TOKEN in GH_TOKEN (the detector probes per-source with GH_TOKEN="$tok"), so per-source
      # isolation is exercised faithfully (RW_* -> 200; RO_*/everything else -> 403).
      case "${GH_TOKEN:-}" in
        RW_*)  printf 'HTTP/2.0 200 OK\n' ; exit 0 ;;
        RWX_*) printf 'HTTP/2.0 422 Unprocessable Entity\n' ; exit 1 ;;  # validation-reject after perm check -> writable
        *)     printf 'HTTP/2.0 403 Forbidden\n' ; exit 1 ;;
      esac
    fi
    # a GET: just succeed (no output needed by the detector's provenance path)
    exit 0
    ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$BIN/gh"

# --- a FAKE git: passes through to real git for local ops, but intercepts `push` to simulate the ambient
#     git-push surface. READONLY_SMOKE_GIT=rejected -> auth-reject; =accepted -> accept (FAIL signal). Records
#     any push attempt; --dry-run must NEVER reach a real remote.
REAL_GIT=$(command -v git)
# write the standard fake git: intercepts `push` (the dry-run probe) and `credential` (so it NEVER reaches the
# real machine's credential helpers — #166 code-review F2 hermeticity), passes every other op (init/commit/
# remote/config) to the real git. Per-URL push outcome so the SSH-surface false-pass (F1) is testable.
write_fake_git(){  # write_fake_git <bin/git path> [ssh-push-output-override-block]
  cat > "$1" <<EOF
#!/bin/bash
# credential: stub fill/approve/reject so the probe's 'git credential fill' stays hermetic (no real helpers).
for a in "\$@"; do
  if [ "\$a" = credential ]; then
    cat >/dev/null 2>&1 || true   # consume the credential request on stdin
    exit 0                        # emit NOTHING -> no ambient credential in the smoke's default fixtures
  fi
done
is_push=0; purl=""
for a in "\$@"; do
  if [ "\$is_push" = 1 ] && [ "\${a#-}" = "\$a" ] && [ -z "\$purl" ]; then purl="\$a"; fi
  [ "\$a" = push ] && is_push=1
done
if [ "\$is_push" = 1 ]; then
  echo "GIT_PUSH_ATTEMPT: \$*" >> "$MUTLOG"
  case "\$purl" in
    git@*|ssh://*) outcome=\${READONLY_SMOKE_GIT_SSH:-rejected} ;;
    *)             outcome=\${READONLY_SMOKE_GIT_HTTPS:-rejected} ;;
  esac
  case "\$outcome" in
    accepted)    echo "To \$purl (dry run)"; exit 0 ;;
    hostkey)     echo "Host key verification failed." >&2; echo "fatal: Could not read from remote repository." >&2; exit 128 ;;
    authzdenied) echo "ERROR: Permission to o/r.git denied to some-user." >&2; echo "fatal: Could not read from remote repository." >&2; exit 128 ;;
    *)           echo "fatal: Authentication failed for '\$purl'" >&2; exit 128 ;;
  esac
fi
exec "$REAL_GIT" "\$@"
EOF
  chmod +x "$1"
}
write_fake_git "$BIN/git"

# --- provenance seam fixtures: WF_READONLY_TOKEN_INFO_CMD reads the token on stdin, prints canonical perms.
#     We key the emitted perms off the token VALUE so per-source isolation is testable.
INFOCMD="$TMP/info.sh"
cat > "$INFOCMD" <<'EOF'
#!/bin/bash
tok=$(cat)
case "$tok" in
  RO_*) printf '{"permissions":{"contents":"read","metadata":"read","pull_requests":"read"}}\n' ;;
  RWX_*) printf '{"permissions":{"contents":"read","metadata":"read"}}\n' ;;  # provenance says READ-ONLY...
  RW_*) printf '{"permissions":{"contents":"write","metadata":"read"}}\n' ;;
  *)    : ;;   # unattested: emit nothing -> detector FAILS CLOSED
esac
EOF
chmod +x "$INFOCMD"

REPO="o/r"
# run the strict detector with a controlled env. Returns the exit code; stdout captured in $RO_OUT. The 5th
# arg drives the HTTPS push outcome (accepted|rejected); $RO_TARGET (default $REPO) and $RO_GIT_SSH let a
# fixture point at a worktree dir with an SSH origin and a separate SSH push outcome.
run_strict(){  # run_strict <GH_TOKEN> <GITHUB_TOKEN> <stored> <api-fixture> <git-https-outcome>
  RO_OUT=$(PATH="$BIN:$PATH" \
    GH_TOKEN="${1:-}" GITHUB_TOKEN="${2:-}" READONLY_SMOKE_STORED_TOKEN="${3:-}" \
    READONLY_SMOKE_API="${4:-denied}" READONLY_SMOKE_GIT_HTTPS="${5:-rejected}" \
    READONLY_SMOKE_GIT_SSH="${RO_GIT_SSH:-rejected}" \
    WF_READONLY_TOKEN_CMD="" WF_READONLY_TOKEN_INFO_CMD="$INFOCMD" \
    bash "$WF" doctor claude "${RO_TARGET:-$REPO}" --readonly 2>&1)
  return $?
}

echo "[smoke] read-only-ambient detector"

# fixture 1: authoritatively read-only token on GH_TOKEN, git rejected -> PASS, exit 0
: > "$MUTLOG"
if run_strict "RO_aaa" "" "" denied rejected; then
  echo "$RO_OUT" | grep -q 'READONLY-PASS' && pass "read-only token -> PASS (exit 0)" || fail "read-only token: expected READONLY-PASS line"
else
  fail "read-only token should exit 0; got nonzero. out: $RO_OUT"
fi

# fixture 2: write-capable token -> FAIL, exit nonzero
: > "$MUTLOG"
if run_strict "RW_bbb" "" "" writable rejected; then
  fail "write-capable token should exit NONZERO"
else
  echo "$RO_OUT" | grep -q 'READONLY-FAIL' && pass "write-capable token -> FAIL (exit nonzero)" || fail "write-capable token: expected READONLY-FAIL line"
  echo "$RO_OUT" | grep -qi 'write/admin' && pass "FAIL names the write/admin provenance" || fail "FAIL should cite write/admin provenance"
fi

# fixture 3: uninspectable/unattested token (no info match) -> FAIL CLOSED, exit nonzero (NOT pass)
: > "$MUTLOG"
if run_strict "OPAQUE_ccc" "" "" denied rejected; then
  fail "unattested token should exit NONZERO (fail closed), not pass"
else
  echo "$RO_OUT" | grep -q 'FAIL-CLOSED' && pass "unattested token -> FAIL-CLOSED (not a pass)" || fail "unattested token: expected FAIL-CLOSED line"
  echo "$RO_OUT" | grep -qi 'advisory NEVER certifies a PASS' && pass "advisory-never-certifies note present" || fail "missing advisory-never-certifies note"
fi

# fixture 4: per-source isolation — read-only GH_TOKEN but WRITE-capable GITHUB_TOKEN -> overall FAIL
: > "$MUTLOG"
if run_strict "RO_aaa" "RW_ddd" "" writable rejected; then
  fail "write-capable GITHUB_TOKEN behind read-only GH_TOKEN should FAIL"
else
  echo "$RO_OUT" | grep -q 'GITHUB_TOKEN: FAIL' && pass "per-source: write-capable GITHUB_TOKEN caught behind read-only GH_TOKEN" || fail "per-source isolation did not catch GITHUB_TOKEN"
  echo "$RO_OUT" | grep -q 'GH_TOKEN: read-only' && pass "per-source: GH_TOKEN still reported read-only" || fail "GH_TOKEN should still read read-only"
fi

# fixture 5: stored gh auth credential is write-capable -> FAIL (env tokens absent)
: > "$MUTLOG"
if run_strict "" "" "RW_eee" writable rejected; then
  fail "write-capable stored gh auth should FAIL"
else
  echo "$RO_OUT" | grep -q 'stored gh auth: FAIL' && pass "stored gh auth write-capable -> FAIL" || fail "stored gh auth FAIL not reported"
fi

# fixture 6: ambient git-push ACCEPTED -> FAIL even with a read-only API token
: > "$MUTLOG"
if run_strict "RO_aaa" "" "" denied accepted; then
  fail "accepted git push --dry-run should FAIL the detector"
else
  echo "$RO_OUT" | grep -q 'ambient git push: FAIL' && pass "git-push accepted -> FAIL" || fail "git-push FAIL not reported"
fi

# fixture 7: ambient git-push rejected -> read-only on the git surface
: > "$MUTLOG"
run_strict "RO_aaa" "" "" denied rejected || true
echo "$RO_OUT" | grep -q 'ambient git push: read-only' && pass "git-push rejected -> read-only" || fail "git-push read-only not reported"

# fixture 8 (F1): a WORKTREE whose origin push url is SSH and ACCEPTS, while the synthesized HTTPS surface
# REJECTS -> the detector must STILL FAIL (it probes the actual origin push url, catching the SSH-key surface
# the old synthesized-HTTPS-only probe missed). Build a real local repo with an ssh:// origin.
WT="$TMP/wt-ssh"; mkdir -p "$WT"
"$REAL_GIT" -C "$WT" init -q
"$REAL_GIT" -C "$WT" remote add origin "git@github.com:o/r.git"
: > "$MUTLOG"
RO_TARGET="$WT" RO_GIT_SSH=accepted run_strict "RO_aaa" "" "" denied rejected
if [ $? -eq 0 ]; then
  fail "SSH-accepted worktree origin should FAIL (F1: must probe the actual push url, not just HTTPS)"
else
  echo "$RO_OUT" | grep -q 'ambient git push: FAIL' && pass "F1: SSH origin push accepted -> FAIL (probes actual origin url)" || fail "F1: SSH-surface false-pass not caught"
fi
# and the same worktree with SSH REJECTED + HTTPS REJECTED -> read-only (both surfaces auth-rejected)
: > "$MUTLOG"
RO_TARGET="$WT" RO_GIT_SSH=rejected run_strict "RO_aaa" "" "" denied rejected || true
echo "$RO_OUT" | grep -q 'ambient git push: read-only' && pass "F1: SSH+HTTPS both rejected -> read-only" || fail "F1: both-rejected should be read-only"

# fixture 8b (F1 r4): an owner/repo-ONLY target (no worktree) must STILL probe the canonical SSH surface — an
# ambient SSH key that can push must FAIL even without a worktree origin. SSH accepts, HTTPS rejects -> FAIL.
: > "$MUTLOG"
RO_GIT_SSH=accepted run_strict "RO_aaa" "" "" denied rejected
if [ $? -eq 0 ]; then
  fail "owner/repo-only target with an accepting SSH surface must FAIL (F1 r4: synthesize SSH url too)"
else
  echo "$RO_OUT" | grep -q 'ambient git push: FAIL' && pass "F1 r4: owner/repo target probes canonical SSH url -> FAIL" || fail "F1 r4: SSH url not synthesized for owner/repo target"
fi

# fixture 9 (F1 r3): a PRE-AUTH transport failure (host key verification failed) must read INCONCLUSIVE ->
# strict-FAIL, NOT read-only — SSH failed before the credential was ever tested.
: > "$MUTLOG"
RO_TARGET="$WT" RO_GIT_SSH=hostkey run_strict "RO_aaa" "" "" denied rejected
if [ $? -eq 0 ]; then
  fail "host-key-verification (pre-auth) must NOT certify read-only (strict-fail)"
else
  echo "$RO_OUT" | grep -q 'ambient git push: inconclusive' && pass "F1 r3: pre-auth host-key failure -> inconclusive (strict-fail, not read-only)" || fail "F1 r3: pre-auth failure should be inconclusive"
fi

# fixture 9b (F2/422): the advisory probe classifies HTTP 422 as WRITABLE. Token whose provenance says
# read-only but whose advisory PATCH returns 422 -> the contradiction path FAILs (advisory saw a write).
: > "$MUTLOG"
if run_strict "RWX_zzz" "" "" denied rejected; then
  fail "422 advisory must be treated as writable -> contradiction FAIL"
else
  echo "$RO_OUT" | grep -q 'advisory probe accepted a write' && pass "F2: HTTP 422 advisory classified writable (contradiction FAIL)" || fail "F2: 422 not treated as writable"
fi

# fixture 10b (F1 r6): strict --readonly with NO probeable target must fail closed on the git surface. The CLI
# always defaults a repo target, so this branch is exercised by a structural check that the no-target strict
# branch both emits NOT-VERIFIED and sets the fail flag (DOCTOR_RO_FAIL=1 on the same line).
if grep -q 'no repo/worktree target in strict --readonly -> fail closed.*DOCTOR_RO_FAIL=1' "$WF"; then
  pass "F1 r6: strict no-target branch fails closed (NOT-VERIFIED + DOCTOR_RO_FAIL=1)"
else
  fail "F1 r6: strict no-target fail-closed branch missing or does not set DOCTOR_RO_FAIL"
fi

# fixture 10 (F1 r5): strict --readonly with WF_DOCTOR_SKIP_LIVE_PROBES=1 must NOT emit READONLY-PASS — the
# git surface was never tested, so strict mode fails closed (the skip is only for the non-gating reporter).
: > "$MUTLOG"
RO_OUT=$(PATH="$BIN:$PATH" GH_TOKEN="RO_aaa" WF_DOCTOR_SKIP_LIVE_PROBES=1 \
  WF_READONLY_TOKEN_CMD="" WF_READONLY_TOKEN_INFO_CMD="$INFOCMD" \
  bash "$WF" doctor claude "$REPO" --readonly 2>&1); rc=$?
if [ "$rc" = 0 ]; then
  fail "strict --readonly with skipped live probes must NOT pass (F1 r5)"
else
  echo "$RO_OUT" | grep -q 'NOT-VERIFIED' && pass "F1 r5: strict --readonly + skip-live-probes -> fail closed (NOT-VERIFIED)" || fail "F1 r5: expected NOT-VERIFIED git-push line in strict skip mode"
fi

# --- MUTATION-FREEDOM: across ALL fixtures, the only write-shaped calls were the advisory PATCH probe and the
#     --dry-run push; assert the fake never performed a real mutation (it can't, by construction) AND that the
#     git push calls all carried --dry-run.
: > "$MUTLOG"
run_strict "RW_bbb" "" "" writable accepted || true
if grep -q 'GIT_PUSH_ATTEMPT' "$MUTLOG"; then
  if grep 'GIT_PUSH_ATTEMPT' "$MUTLOG" | grep -vq -- '--dry-run'; then
    fail "a git push WITHOUT --dry-run was attempted (mutation risk)"
  else
    pass "every git push attempt carried --dry-run (non-mutating)"
  fi
  # hook-free: every probe push must carry --no-verify so a pre-push hook can never run (#166 F1 r7).
  if grep 'GIT_PUSH_ATTEMPT' "$MUTLOG" | grep -vq -- '--no-verify'; then
    fail "a git push WITHOUT --no-verify was attempted (a pre-push hook could run)"
  else
    pass "every git push attempt carried --no-verify (hook-free)"
  fi
fi
if grep -q 'API_WRITE_ATTEMPT' "$MUTLOG"; then
  # the advisory probe must carry an EMPTY {} body and NO -f settable field (no field -> never mutates, proven
  # live against a disposable repo where an empty-{} PATCH returns 200 without changing updated_at).
  if grep 'API_WRITE_ATTEMPT' "$MUTLOG" | grep -Eq -- '(^| )-f( |=)|(^| )--field'; then
    fail "the advisory API probe carried a -f/--field (could mutate)"
  elif grep 'API_WRITE_ATTEMPT' "$MUTLOG" | grep -vq -- 'body=\[{}\]'; then
    fail "the advisory API probe did not carry the expected empty {} body"
  else
    pass "advisory API probe carried only an empty {} body (non-mutating by construction)"
  fi
fi

# --- F1 r8: the git probe installs a mutation-safe credential layer. Structural: the push resets the helper
#     chain and uses ONLY the read-only shim, and the shim no-ops store/erase. Behavioral: a real-git push with
#     a LOGGING credential helper inherited must NOT trigger the helper's `store`/`erase` (proven empirically to
#     fire on a successful dry-run otherwise), while `get` is still forwarded.
if grep -q 'GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1' "$WF" \
   && grep -q '"credential.helper=$shim"' "$WF" \
   && grep -q 'no-op store/erase (never mutate)' "$WF" \
   && grep -q 'git credential fill' "$WF"; then
  pass "F1 r8/r9/r10: probe isolates git config + resolves cred via 'git credential fill' + static replay shim (structural)"
else
  fail "F1 r8/r9/r10: probe does not isolate config + use git-native credential resolution"
fi
# F1 r11: credential resolution runs in the TARGET WORKTREE context (credctx -C "$wt") with the URL PATH +
# credential.useHttpPath, so worktree-local + path-scoped credential config is honored (structural).
if grep -q 'credctx=(-C "\$wt")' "$WF" \
   && grep -q 'git "${credctx\[@\]}" -c credential.useHttpPath=true credential fill' "$WF" \
   && grep -q 'path=%s' "$WF"; then
  pass "F1 r11: credential fill runs in the worktree context with the URL path (worktree-local/path-scoped cfg honored)"
else
  fail "F1 r11: credential fill does not use the worktree context + URL path"
fi
# F3 r11: a TIMEOUT during the credential snapshot is treated as inconclusive (fail-closed), not a silent
# empty-credential read-only (structural — the timeout branch returns RC=3 before building the replay helper).
if grep -q 'credential fill timed out after' "$WF" && grep -q 'fillrc=124' "$WF" 2>/dev/null || \
   grep -q 'fillrc" = 124' "$WF"; then
  pass "F3 r11: credential-fill timeout -> inconclusive (fail-closed, not empty-cred read-only)"
else
  fail "F3 r11: credential-fill timeout is not handled as inconclusive"
fi
# behavioral shim unit: build a shim like the function does (forward get to a logging helper, no-op store/erase)
CREDLOG="$TMP/cred-ops.log"; : > "$CREDLOG"
LOGHELPER="$TMP/loghelper.sh"
cat > "$LOGHELPER" <<EOF
#!/bin/bash
echo "REAL_HELPER_OP: \$1" >> "$CREDLOG"
[ "\$1" = get ] && printf 'username=x\npassword=SECRET\n'
exit 0
EOF
chmod +x "$LOGHELPER"
SHIM="$TMP/shim.sh"
cat > "$SHIM" <<EOF
#!/bin/bash
op=\$1
if [ "\$op" != get ]; then cat >/dev/null 2>&1 || true; exit 0; fi
in=\$(cat)
out=\$(printf "%s\n" "\$in" | "$LOGHELPER" get 2>/dev/null); if printf "%s" "\$out" | grep -q "^password="; then printf "%s\n" "\$out"; exit 0; fi
exit 0
EOF
chmod +x "$SHIM"
# get -> forwarded (helper logs a get, password returned); store/erase -> no-op (helper NOT invoked)
printf 'protocol=https\nhost=github.com\n\n' | "$SHIM" get >/dev/null 2>&1
printf 'protocol=https\nhost=github.com\nusername=x\npassword=SECRET\n\n' | "$SHIM" store >/dev/null 2>&1
printf 'protocol=https\nhost=github.com\n\n' | "$SHIM" erase >/dev/null 2>&1
if grep -q 'REAL_HELPER_OP: get' "$CREDLOG" && ! grep -qE 'REAL_HELPER_OP: (store|erase)' "$CREDLOG"; then
  pass "F1 r8: shim forwards get but no-ops store/erase (no credential-store mutation)"
else
  fail "F1 r8: shim did not isolate get from store/erase (ops: $(tr '\n' ' ' < "$CREDLOG"))"
fi
# F1 r9 (behavioral): a URL-SCOPED helper (credential.https://github.com.helper) must be neutralized by the
# config isolation — under GIT_CONFIG_GLOBAL=/dev/null + the shim, a real `git push --dry-run` must NOT invoke
# the URL-scoped helper's store/erase (it would mutate the store). Uses real git against a non-resolving host
# so it stays offline (auth/transport fails fast; we only assert no store/erase op was logged).
URLLOG="$TMP/urlscoped-ops.log"; : > "$URLLOG"
URLHELPER="$TMP/urlhelper.sh"
cat > "$URLHELPER" <<EOF
#!/bin/bash
echo "URLSCOPED_OP: \$1" >> "$URLLOG"
[ "\$1" = get ] && printf 'username=x\npassword=SECRET\n'
exit 0
EOF
chmod +x "$URLHELPER"
R9GLOBAL="$TMP/r9-gitconfig"; : > "$R9GLOBAL"
GIT_CONFIG_GLOBAL="$R9GLOBAL" "$REAL_GIT" config --global "credential.https://nonresolve.invalid.helper" "$URLHELPER"
R9TMP=$(mktemp -d); "$REAL_GIT" -C "$R9TMP" init -q
"$REAL_GIT" -C "$R9TMP" -c user.name=t -c user.email=t@t commit -q --allow-empty -m x
# the read-only shim (get-forward, store/erase no-op) — same shape the probe builds
R9SHIM="$TMP/r9-shim.sh"
cat > "$R9SHIM" <<EOF
#!/bin/bash
op=\$1
if [ "\$op" != get ]; then cat >/dev/null 2>&1 || true; exit 0; fi
in=\$(cat); out=\$(printf "%s\n" "\$in" | "$URLHELPER" get 2>/dev/null); printf "%s\n" "\$out"; exit 0
EOF
chmod +x "$R9SHIM"
GIT_TERMINAL_PROMPT=0 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  timeout 15 "$REAL_GIT" -C "$R9TMP" -c "credential.helper=$R9SHIM" -c core.sshCommand='ssh -o BatchMode=yes -o ConnectTimeout=3' \
  push --dry-run --no-verify "https://nonresolve.invalid/o/r.git" HEAD:refs/heads/probe >/dev/null 2>&1
if ! grep -qE 'URLSCOPED_OP: (store|erase)' "$URLLOG"; then
  pass "F1 r9: URL-scoped helper neutralized by config isolation (no store/erase during probe)"
else
  fail "F1 r9: URL-scoped helper still ran store/erase (ops: $(tr '\n' ' ' < "$URLLOG"))"
fi
rm -rf "$R9TMP"

# F1 r10 (behavioral): a credential helper WITH ARGUMENTS must be resolved by git's OWN parser (`git credential
# fill`), not a hand-rolled shim that mis-quotes the args — otherwise a write-capable ambient HTTPS credential
# goes undetected (false-pass). Assert `git credential fill` invokes the arg'd helper correctly and returns the
# credential (the exact primitive the probe now uses).
R10LOG="$TMP/r10-ops.log"; : > "$R10LOG"
R10BIN="$TMP/r10bin"; mkdir -p "$R10BIN"
cat > "$R10BIN/git-credential-argd" <<EOF
#!/bin/bash
op="\${@: -1}"
echo "ARGD_OP: \$op flags=[\${@:1:\$#-1}]" >> "$R10LOG"
[ "\$op" = get ] && printf 'username=x-access-token\npassword=AMBIENT_SECRET\n'
exit 0
EOF
chmod +x "$R10BIN/git-credential-argd"
R10GLOBAL="$TMP/r10-gitconfig"; : > "$R10GLOBAL"
GIT_CONFIG_GLOBAL="$R10GLOBAL" "$REAL_GIT" config --global credential.helper "argd --flag=value"
R10OUT=$(printf 'protocol=https\nhost=github.com\n\n' | \
  GIT_TERMINAL_PROMPT=0 GIT_CONFIG_GLOBAL="$R10GLOBAL" PATH="$R10BIN:$PATH" "$REAL_GIT" credential fill 2>/dev/null || true)
if printf '%s' "$R10OUT" | grep -q '^password=AMBIENT_SECRET' && grep -q 'ARGD_OP: get flags=\[--flag=value\]' "$R10LOG"; then
  pass "F1 r10: git credential fill resolves a helper WITH ARGS (no false-pass from arg mis-quoting)"
else
  fail "F1 r10: helper-with-args not resolved by git credential fill (out=[$(printf '%s' "$R10OUT" | tr '\n' '|')] ops=[$(cat "$R10LOG")])"
fi

# --- F3: GitHub SSH authz-denial messages classify as read-only (auth-rejected), not inconclusive.
WT3="$TMP/wt-authz"; mkdir -p "$WT3"
"$REAL_GIT" -C "$WT3" init -q
"$REAL_GIT" -C "$WT3" remote add origin "git@github.com:o/r.git"
: > "$MUTLOG"
RO_TARGET="$WT3" RO_GIT_SSH=authzdenied run_strict "RO_aaa" "" "" denied rejected || true
echo "$RO_OUT" | grep -q 'ambient git push: read-only' && pass "F3: GitHub SSH 'Permission to X denied to Y' -> read-only (auth-rejected)" || fail "F3: SSH authz-denial not classified read-only"

# --- plain doctor prints the read-only section as a labeled reporter (does not require engineer identity to PASS
#     for the read-only verdict to print). We only assert the section + verdict line appear.
PLAIN_OUT=$(PATH="$BIN:$PATH" GH_TOKEN="RO_aaa" READONLY_SMOKE_API=denied READONLY_SMOKE_GIT=rejected \
  WF_READONLY_TOKEN_CMD="" WF_READONLY_TOKEN_INFO_CMD="$INFOCMD" WF_ALLOW_AMBIENT_IDENTITY=1 \
  bash "$WF" doctor claude "$REPO" 2>&1 || true)
echo "$PLAIN_OUT" | grep -q 'read-only ambient credential (#166)' && pass "plain doctor prints the read-only section" || fail "plain doctor missing the read-only section"
echo "$PLAIN_OUT" | grep -q 'read-only ambient verdict:' && pass "plain doctor prints the read-only verdict line" || fail "plain doctor missing the verdict line"

if [ "$fails" -gt 0 ]; then echo "[smoke] FAILED ($fails)"; exit 1; fi
echo "[smoke] all read-only-ambient detector checks passed"
