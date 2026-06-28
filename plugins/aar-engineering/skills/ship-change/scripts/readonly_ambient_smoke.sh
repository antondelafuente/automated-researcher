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
# also clear any inherited ambient credential / fixture vars so the DIRECT `bash "$WF" doctor` invocations
# (the ones not routed through run_strict) can't pass/fail against an unintended ambient credential (#166 r17).
unset GH_TOKEN GITHUB_TOKEN READONLY_SMOKE_STORED_TOKEN READONLY_SMOKE_API READONLY_SMOKE_GIT_HTTPS READONLY_SMOKE_GIT_SSH

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
  # classify SSH vs HTTPS — the push url may be userinfo-stripped (#166 r18c): ssh://… , git@host:… , or a
  # bare scp-style host:path (has ':' but no '://' and not https://). Everything else (https://…) is HTTPS.
  case "\$purl" in
    https://*)              outcome=\${READONLY_SMOKE_GIT_HTTPS:-rejected} ;;
    ssh://*|git@*)          outcome=\${READONLY_SMOKE_GIT_SSH:-rejected} ;;
    *://*)                  outcome=\${READONLY_SMOKE_GIT_HTTPS:-rejected} ;;
    *:*)                    outcome=\${READONLY_SMOKE_GIT_SSH:-rejected} ;;   # bare scp-style host:path
    *)                      outcome=\${READONLY_SMOKE_GIT_HTTPS:-rejected} ;;
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

# fixture 7 (ASYMMETRIC): a not-accepted git push is ADVISORY ONLY — it does NOT certify read-only and does
# NOT block the PASS (the read-only-provenance API token still PASSes). The git surface never grants a PASS.
: > "$MUTLOG"
if run_strict "RO_aaa" "" "" denied rejected; then
  echo "$RO_OUT" | grep -q 'no ambient push credential was accepted' && pass "git-push not-accepted -> advisory note, PASS unaffected (asymmetric)" || fail "git-push advisory note not reported"
else
  fail "git-push not-accepted must NOT block the PASS (provenance is the gate)"
fi

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
# and the same worktree with SSH REJECTED + HTTPS REJECTED -> advisory (not accepted); PASS unaffected.
: > "$MUTLOG"
if RO_TARGET="$WT" RO_GIT_SSH=rejected run_strict "RO_aaa" "" "" denied rejected; then
  echo "$RO_OUT" | grep -q 'no ambient push credential was accepted' && pass "F1: SSH+HTTPS both rejected -> advisory (PASS unaffected, asymmetric)" || fail "F1: both-rejected advisory note not reported"
else
  fail "F1: both-rejected must NOT block the PASS"
fi

# fixture 8b (F1 r4): an owner/repo-ONLY target (no worktree) must STILL probe the canonical SSH surface — an
# ambient SSH key that can push must FAIL even without a worktree origin. SSH accepts, HTTPS rejects -> FAIL.
: > "$MUTLOG"
RO_GIT_SSH=accepted run_strict "RO_aaa" "" "" denied rejected
if [ $? -eq 0 ]; then
  fail "owner/repo-only target with an accepting SSH surface must FAIL (F1 r4: synthesize SSH url too)"
else
  echo "$RO_OUT" | grep -q 'ambient git push: FAIL' && pass "F1 r4: owner/repo target probes canonical SSH url -> FAIL" || fail "F1 r4: SSH url not synthesized for owner/repo target"
fi

# fixture 9 (F1 r3, ASYMMETRIC): a PRE-AUTH transport failure (host key verification) is NOT-ACCEPTED ->
# advisory; it never certifies read-only AND never blocks the PASS (the surface is fail-only; only an ACCEPTED
# push matters). So a hostkey outcome leaves the PASS intact.
: > "$MUTLOG"
if RO_TARGET="$WT" RO_GIT_SSH=hostkey run_strict "RO_aaa" "" "" denied rejected; then
  echo "$RO_OUT" | grep -q 'no ambient push credential was accepted' && pass "F1 r3: pre-auth host-key failure -> advisory (not accepted; never certifies read-only)" || fail "F1 r3: hostkey advisory note not reported"
else
  fail "F1 r3: a pre-auth transport failure must NOT block the PASS (only an accepted push fails)"
fi

# fixture 9b (F2/422): the advisory probe classifies HTTP 422 as WRITABLE. Token whose provenance says
# read-only but whose advisory PATCH returns 422 -> the contradiction path FAILs (advisory saw a write).
: > "$MUTLOG"
if run_strict "RWX_zzz" "" "" denied rejected; then
  fail "422 advisory must be treated as writable -> contradiction FAIL"
else
  echo "$RO_OUT" | grep -q 'advisory probe accepted a write' && pass "F2: HTTP 422 advisory classified writable (contradiction FAIL)" || fail "F2: 422 not treated as writable"
fi

# fixture 10b (F1 r6 -> ASYMMETRIC): a skipped/absent git-push surface does NOT fail closed — the surface only
# ever ADDS a FAIL, so its absence leaves the provenance-decided PASS intact. With a read-only-provenance token
# and the live probes skipped, strict --readonly still PASSes.
: > "$MUTLOG"
if PATH="$BIN:$PATH" GH_TOKEN="RO_aaa" WF_DOCTOR_SKIP_LIVE_PROBES=1 \
   WF_READONLY_TOKEN_CMD="" WF_READONLY_TOKEN_INFO_CMD="$INFOCMD" \
   bash "$WF" doctor claude "$REPO" --readonly >/dev/null 2>&1; then
  pass "F1 r6/asymmetric: skipped git surface does NOT fail closed (provenance decides the PASS)"
else
  fail "F1 r6/asymmetric: a skipped git surface must not block a provenance-read-only PASS"
fi

# fixture 10 (ASYMMETRIC): strict --readonly with WF_DOCTOR_SKIP_LIVE_PROBES=1 and a read-only-provenance token
# PASSes (the git surface is an advisory alarm; skipping it never blocks the provenance PASS).
: > "$MUTLOG"
RO_OUT=$(PATH="$BIN:$PATH" GH_TOKEN="RO_aaa" WF_DOCTOR_SKIP_LIVE_PROBES=1 \
  WF_READONLY_TOKEN_CMD="" WF_READONLY_TOKEN_INFO_CMD="$INFOCMD" \
  bash "$WF" doctor claude "$REPO" --readonly 2>&1); rc=$?
if [ "$rc" = 0 ]; then
  echo "$RO_OUT" | grep -q 'advisory alarm only' && pass "F1 r5/asymmetric: skip-live-probes -> git surface advisory, provenance PASS holds" || fail "F1 r5: expected advisory-alarm note in skip mode"
else
  fail "F1 r5/asymmetric: skip-live-probes must not block a provenance-read-only PASS"
fi
# AND: a WRITE-capable token with live probes skipped still FAILs (provenance gate independent of the git surface).
: > "$MUTLOG"
if PATH="$BIN:$PATH" GH_TOKEN="RW_bbb" WF_DOCTOR_SKIP_LIVE_PROBES=1 \
   WF_READONLY_TOKEN_CMD="" WF_READONLY_TOKEN_INFO_CMD="$INFOCMD" \
   bash "$WF" doctor claude "$REPO" --readonly >/dev/null 2>&1; then
  fail "write-capable token must FAIL even with the git surface skipped (provenance gate)"
else
  pass "provenance gate stands alone: write-capable token FAILs even when the git surface is skipped"
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
# F1 r11 (asymmetric): credential resolution runs in the TARGET WORKTREE context (credctx -C "$wt") so a
# worktree-local credential helper is honored. We DON'T force credential.useHttpPath (git's default path
# behavior is what a real push uses, so a host-wide credential-store entry is resolved too — the host-vs-path
# tension is moot under the asymmetric design). Structural.
if grep -q 'credctx=(-C "\$wt")' "$WF" \
   && grep -q 'git "${credctx\[@\]}" credential fill' "$WF" \
   && ! grep -q 'useHttpPath=true' "$WF"; then
  pass "F1 r11/asymmetric: credential fill runs in the worktree context, no forced useHttpPath (host-wide creds resolved)"
else
  fail "F1 r11/asymmetric: credential fill context/useHttpPath handling is wrong"
fi
# F1 r12 (structural): the advisory `gh api` probe is bounded by `timeout` (no unbounded hang).
if grep -q 'timeout "$to" env GH_TOKEN="$tok" WF_GH_INTERNAL=1 gh api -X PATCH' "$WF"; then
  pass "F1 r12: advisory gh api probe is timeout-bounded (no unbounded hang)"
else
  fail "F1 r12: advisory gh api probe is not timeout-bounded"
fi
# F2 r12 (behavioral): a worktree whose origin is a NON-GitHub remote is NOT dry-run-probed (no arbitrary
# remote helper executed); the probe notes it and falls back to the synthesized GitHub URLs.
WT12="$TMP/wt-nongithub"; mkdir -p "$WT12"
"$REAL_GIT" -C "$WT12" init -q
# a CREDENTIAL-BEARING non-GitHub origin: the token must NOT leak into the doctor output (#166 F1 r13).
"$REAL_GIT" -C "$WT12" remote add origin "https://user:SUPERSECRETTOKEN@gitlab.example.com/o/r.git"
: > "$MUTLOG"
RO_TARGET="$WT12" run_strict "RO_aaa" "" "" denied rejected || true
# F1 r13: the non-GitHub-origin note must NOT echo the raw URL / its userinfo token.
if echo "$RO_OUT" | grep -q 'SUPERSECRETTOKEN'; then
  fail "F1 r13: the non-GitHub origin note LEAKED the userinfo token into the output"
else
  pass "F1 r13: non-GitHub origin note does not leak the remote URL / token"
fi
# F1 r14: PLAIN doctor's read-only verdict ADVICE lines must also redact a credential-bearing target.
PLAIN12=$(PATH="$BIN:$PATH" GH_TOKEN="RO_aaa" WF_DOCTOR_SKIP_LIVE_PROBES=1 WF_ALLOW_AMBIENT_IDENTITY=1 \
  WF_READONLY_TOKEN_CMD="" WF_READONLY_TOKEN_INFO_CMD="$INFOCMD" \
  bash "$WF" doctor claude "$WT12" 2>&1 || true)
if echo "$PLAIN12" | grep -q 'SUPERSECRETTOKEN'; then
  fail "F1 r14: plain doctor verdict advice leaked the credential-bearing target"
else
  pass "F1 r14: plain doctor verdict advice redacts the credential-bearing target"
fi
# F2 r14 (structural): credential fill is keyed on the PARSED authority host (url_host), and a username is
# passed when present — so a username-qualified remote keys on host=github.com, not user@host.
if grep -q 'parsed_host=\$(url_host "\$url")' "$WF" \
   && grep -q 'username=%s' "$WF"; then
  pass "F2 r14: credential fill keyed on parsed authority host + passes username (structural)"
else
  fail "F2 r14: credential fill host/username handling is wrong"
fi
# F1 r16b (HIGH): an authority-spoof remote `https://evil.example/path@github.com/o/r` has TRUE host
# evil.example — it must be rejected by the parsed allowlist (NOT treated as github.com), so a github.com
# credential is never handed to the attacker host. Unit-check url_host/is_github_remote_url on the spoof + the
# behavioral path (the spoof origin is skipped, not probed).
SPOOF_OK=1
eval "$(awk '/^url_host\(\)\{/,/^\}$/' "$WF")" 2>/dev/null || SPOOF_OK=0
eval "$(awk '/^is_github_remote_url\(\)\{/,/^\}$/' "$WF")" 2>/dev/null || SPOOF_OK=0
if [ "$SPOOF_OK" = 1 ] \
   && [ "$(url_host 'https://evil.example/path@github.com/o/r.git')" = evil.example ] \
   && ! is_github_remote_url 'https://evil.example/path@github.com/o/r.git' \
   && is_github_remote_url 'https://user@github.com/o/r.git'; then
  pass "F1 r16b: authority-spoof (evil/path@github.com) parsed as host=evil.example -> rejected (no cred exfil)"
else
  fail "F1 r16b: authority-spoof not correctly rejected by the parsed host allowlist"
fi
# behavioral: a worktree whose origin is the spoof must be skipped (not dry-run-probed against the attacker host)
WT16c="$TMP/wt-spoof"; mkdir -p "$WT16c"
"$REAL_GIT" -C "$WT16c" init -q
"$REAL_GIT" -C "$WT16c" remote add origin "https://evil.example/path@github.com/o/r.git"
: > "$MUTLOG"
RO_TARGET="$WT16c" RO_GIT_HTTPS=accepted run_strict "RO_aaa" "" "" denied rejected || true
if grep 'GIT_PUSH_ATTEMPT' "$MUTLOG" | grep -q 'evil.example'; then
  fail "F1 r16b: the authority-spoof origin was dry-run-probed (cred-exfil risk)"
else
  pass "F1 r16b: authority-spoof origin skipped (not probed against the attacker host)"
fi

# F1 r17b: a URL-shaped / credential-bearing TARGET must NEVER be embedded into the advisory `gh api
# repos/<slug>` path (token leak). The fake gh records every api call; assert none carries a URL-shaped repo.
# DREPO for a worktree with a credential-bearing origin would be the full URL — is_clean_repo_slug must reject
# it so the advisory probe is skipped.
APILOG="$TMP/api-calls.log"; : > "$APILOG"
cat > "$BIN/gh" <<EOF
#!/bin/bash
for a in "\$@"; do [ "\$a" = credential ] && { cat>/dev/null 2>&1||true; exit 0; }; done
sub=""; for a in "\$@"; do case "\$a" in -*) ;; *) sub=\$a; break;; esac; done
if [ "\$sub" = api ]; then echo "API_CALL: \$*" >> "$APILOG"; fi
case "\$sub" in
  auth) [ "\$2" = token ] && { printf '%s\n' "\${READONLY_SMOKE_STORED_TOKEN:-}"; exit 0; }; exit 1 ;;
  api) printf 'HTTP/2.0 403 Forbidden\n'; exit 1 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$BIN/gh"
WT17="$TMP/wt-credurl"; mkdir -p "$WT17"
"$REAL_GIT" -C "$WT17" init -q
"$REAL_GIT" -C "$WT17" remote add origin "https://user:SUPERSECRETTOKEN@gitlab.example.com/o/r.git"
: > "$MUTLOG"
RO_TARGET="$WT17" run_strict "RO_aaa" "" "" denied rejected || true
if grep 'API_CALL' "$APILOG" | grep -Eq 'repos/(https|.*@|.*//)' ; then
  fail "F1 r17b: a URL-shaped repo target was embedded into a gh api path (token leak)"
else
  pass "F1 r17b: advisory gh api never embeds a URL-shaped target (only clean owner/repo slugs)"
fi
echo "$RO_OUT" | grep -q 'SUPERSECRETTOKEN' && fail "F1 r17b: credential-bearing target leaked into output" || pass "F1 r17b: credential-bearing target not leaked anywhere"
write_fake_git "$BIN/git"   # restore the standard fake git
# restore the standard fake gh (the smoke's main one)
cat > "$BIN/gh" <<EOF
#!/bin/bash
sub=""; verb=""; args=("\$@"); i=0; n=\${#args[@]}
while [ "\$i" -lt "\$n" ]; do a=\${args[\$i]}; case "\$a" in -R|--repo|-H|--hostname) i=\$((i+2));; -*) i=\$((i+1));; *) sub=\$a; verb=\${args[\$((i+1))]:-}; break;; esac; done
case "\$sub" in
  auth) case "\$verb" in token) printf '%s\n' "\${READONLY_SMOKE_STORED_TOKEN:-}"; exit 0;; status) [ -n "\${READONLY_SMOKE_STORED_TOKEN:-}" ] && exit 0 || exit 1;; *) exit 0;; esac;;
  api)
    method="GET"; j=0; m=\${#args[@]}
    while [ "\$j" -lt "\$m" ]; do case "\${args[\$j]}" in -X|--method) method=\${args[\$((j+1))]:-GET};; -X*) method=\${args[\$j]#-X};; --method=*) method=\${args[\$j]#--method=};; esac; j=\$((j+1)); done
    mu=\$(printf '%s' "\$method" | tr '[:lower:]' '[:upper:]')
    if [ "\$mu" != GET ] && [ "\$mu" != HEAD ]; then
      body=""; for f in "\${args[@]}"; do [ "\$f" = "--input" ] && body=\$(cat); done
      echo "API_WRITE_ATTEMPT: args=[\$*] body=[\$body]" >> "\$READONLY_SMOKE_MUTLOG"
      case "\${GH_TOKEN:-}" in RW_*) printf 'HTTP/2.0 200 OK\n'; exit 0;; RWX_*) printf 'HTTP/2.0 422 Unprocessable Entity\n'; exit 1;; *) printf 'HTTP/2.0 403 Forbidden\n'; exit 1;; esac
    fi
    exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$BIN/gh"

# F2 r17b (structural): the provenance seam commands (info + minter) are run under `timeout` and fail closed.
if grep -q 'timeout "$to" bash -c "$info_cmd"' "$WF" \
   && grep -q 'timeout "${WF_GIT_PROBE_TIMEOUT:-20}" bash -c "$(readonly_token_cmd)"' "$WF"; then
  pass "F2 r17b: provenance info + minter seams run under timeout (no unbounded hang)"
else
  fail "F2 r17b: provenance seam commands are not timeout-bounded"
fi
if echo "$RO_OUT" | grep -q 'not a GitHub remote'; then
  # assert NO push targeted the non-GitHub origin URL (the push-target is the arg right after `push` + flags);
  # a push whose remote URL is a `https://gitlab…`/non-github scheme would mean the non-GitHub origin was probed
  # (arbitrary remote-helper risk). The synthesized fallback URLs all start with github.com, so a clean run has
  # no push whose URL token begins with a non-github scheme.
  if grep 'GIT_PUSH_ATTEMPT' "$MUTLOG" | grep -Eq -- ' (https://gitlab|ssh://gitlab|git@gitlab)'; then
    fail "F2 r12: a non-GitHub origin URL was dry-run-probed (arbitrary remote helper risk)"
  else
    pass "F2 r12: non-GitHub origin skipped (not probed); synthesized GitHub URLs used instead"
  fi
else
  fail "F2 r12: non-GitHub origin not flagged/skipped"
fi

# F1 r18b (behavioral): a credential-bearing GitHub HTTPS origin must NOT expose its token in the `git push`
# child argv — the push URL is userinfo-stripped (the credential is supplied via the shim). The fake git logs
# every push argv; assert no push argv carries the token.
WT18="$TMP/wt-credgithub"; mkdir -p "$WT18"
"$REAL_GIT" -C "$WT18" init -q
"$REAL_GIT" -C "$WT18" remote add origin "https://user:PUSHARGVTOKEN@github.com/o/r.git"
: > "$MUTLOG"
RO_TARGET="$WT18" run_strict "RO_aaa" "" "" denied rejected || true
if grep 'GIT_PUSH_ATTEMPT' "$MUTLOG" | grep -q 'PUSHARGVTOKEN'; then
  fail "F1 r18b: a credential-bearing origin exposed its token in the git push argv"
else
  pass "F1 r18b: git push argv is userinfo-stripped (token not in child argv)"
fi

# F1/F2 r18c: an SSH/scp credential-bearing GitHub origin must ALSO be userinfo-stripped in the push argv.
for spec in "ssh://git:SSHURLSECRET@github.com/o/r.git:SSHURLSECRET" "git@github.com:o/r.git:n/a" "git:SCPSECRET@github.com:o/r.git:SCPSECRET"; do
  ourl=${spec%:*}; tok=${spec##*:}
  WTx="$TMP/wt-ssh-$RANDOM"; mkdir -p "$WTx"
  "$REAL_GIT" -C "$WTx" init -q
  "$REAL_GIT" -C "$WTx" remote add origin "$ourl"
  : > "$MUTLOG"
  RO_TARGET="$WTx" run_strict "RO_aaa" "" "" denied rejected || true
  if [ "$tok" != "n/a" ] && grep 'GIT_PUSH_ATTEMPT' "$MUTLOG" | grep -q "$tok"; then
    fail "F1/F2 r18c: SSH credential-bearing origin leaked '$tok' into the push argv"
  else
    pass "F1/F2 r18c: $ourl -> push argv userinfo-stripped"
  fi
  # F1 r18d: the SSH username `git` (required, not a secret) MUST be retained — a username-less github SSH push
  # would auth as the local Unix user and false-negative a writable key.
  if grep 'GIT_PUSH_ATTEMPT' "$MUTLOG" | grep -Eq -- '(git@github.com:|ssh://git@github.com)'; then
    pass "F1 r18d: $ourl -> push argv keeps the required git@ SSH username"
  else
    fail "F1 r18d: SSH push argv dropped the required git@ username (would auth as local user)"
  fi
done

# F3 r18c/r18f (structural): doctor_token never sends a URL-shaped target to `gh api` — it uses a clean slug
# only (derived if needed) and redacts userinfo in the skip message; it never prints/sends a raw tokenized repo.
if grep -q 'is_clean_repo_slug "$repo"; then apirepo=$repo' "$WF" \
   && grep -q 'gh api "repos/$apirepo"' "$WF" \
   && grep -q 'repo-access NOT verified (target is not a bare owner/repo: $(redact_userinfo "$repo"))' "$WF"; then
  pass "F3 r18f/g: doctor_token uses a clean slug for gh api, redacts userinfo, and does NOT count an unverified token as OK"
else
  fail "F3 r18f/g: doctor_token may still send/print a raw repo or count an unverified token OK"
fi
# F1/F3 r18h (unit): is_clean_repo_slug rejects malformed slugs (/repo, owner/, ../user, a/b/c, ., o/..) and
# github_repo_slug REJECTS (empty) extra-segment URLs instead of truncating to a different repo.
SLUG_OK=1
eval "$(awk '/^is_clean_repo_slug\(\)\{/,/^\}$/' "$WF")" 2>/dev/null || SLUG_OK=0
eval "$(awk '/^github_repo_slug\(\)\{/,/^\}$/' "$WF")" 2>/dev/null || SLUG_OK=0
if [ "$SLUG_OK" = 1 ] \
   && is_clean_repo_slug "o/r" \
   && ! is_clean_repo_slug "/r" && ! is_clean_repo_slug "o/" && ! is_clean_repo_slug "../user" \
   && ! is_clean_repo_slug "a/b/c" && ! is_clean_repo_slug "o/.." \
   && [ "$(github_repo_slug 'https://github.com/o/r.git')" = o/r ] \
   && [ -z "$(github_repo_slug 'https://github.com/o/r/extra')" ]; then
  pass "F1/F3 r18h: slug validators reject malformed slugs + extra-segment URLs (no traversal / wrong-repo probe)"
else
  fail "F1/F3 r18h: slug validators accept a malformed slug or truncate an extra-segment URL"
fi

# F1 r18g (structural): redact_userinfo covers the scp-style [user:secret@]host:path form too (not just ://).
if grep -q "s#(\^|\[\[:space:\]\])\[\^/@:\[:space:\]\]+:\[\^/@\[:space:\]\]+@" "$WF"; then
  pass "F1 r18g: redact_userinfo redacts scp-style credential-bearing remotes too"
else
  fail "F1 r18g: redact_userinfo does not cover scp-style remotes"
fi

# F1 r18e: a worktree with an HTTPS GitHub origin must STILL probe the synthesized SSH surface — so an ambient
# SSH key that accepts FAILs even when the (rejecting) origin is HTTPS. The origin's gh_repo can be URL-shaped;
# the slug is derived from the origin URL so both canonical surfaces are synthesized.
WT18e="$TMP/wt-https-origin"; mkdir -p "$WT18e"
"$REAL_GIT" -C "$WT18e" init -q
"$REAL_GIT" -C "$WT18e" remote add origin "https://github.com/o/r.git"
: > "$MUTLOG"
RO_TARGET="$WT18e" RO_GIT_SSH=accepted run_strict "RO_aaa" "" "" denied rejected
if [ $? -eq 0 ]; then
  fail "F1 r18e: HTTPS-origin worktree must still probe the synthesized SSH surface (SSH-accept -> FAIL)"
else
  echo "$RO_OUT" | grep -q 'ambient git push: FAIL' && pass "F1 r18e: HTTPS-origin worktree also probes synthesized SSH surface (SSH-accept -> FAIL)" || fail "F1 r18e: synthesized SSH surface not probed for an HTTPS-origin worktree"
fi

# F1 r18 (behavioral): an ENV-INJECTED credential helper (GIT_CONFIG_COUNT/KEY/VALUE) must be neutralized by
# the probe's full isolation (GIT_CONFIG_COUNT=0 + helper reset + shim) — a real `git push --dry-run` under
# that env must NOT invoke the env helper's store/erase. Mirror the r9 approach against a non-resolving host.
ENVLOG="$TMP/envcfg-ops.log"; : > "$ENVLOG"
ENVHELPER="$TMP/envhelper.sh"
cat > "$ENVHELPER" <<EOF
#!/bin/bash
echo "ENVCFG_OP: \$1" >> "$ENVLOG"
[ "\$1" = get ] && printf 'username=x\npassword=SECRET\n'
exit 0
EOF
chmod +x "$ENVHELPER"
R18TMP=$(mktemp -d); "$REAL_GIT" -C "$R18TMP" init -q
"$REAL_GIT" -C "$R18TMP" -c user.name=t -c user.email=t@t commit -q --allow-empty -m x
R18SHIM="$TMP/r18-shim.sh"
cat > "$R18SHIM" <<EOF
#!/bin/bash
op=\$1; if [ "\$op" != get ]; then cat >/dev/null 2>&1 || true; exit 0; fi
cat >/dev/null 2>&1 || true; printf '\n'
EOF
chmod +x "$R18SHIM"
# run the probe-equivalent push WITH an env-injected helper present, but UNDER the full isolation the probe uses
GIT_TERMINAL_PROMPT=0 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_COUNT=0 \
  GIT_CONFIG_KEY_0="credential.helper" GIT_CONFIG_VALUE_0="$ENVHELPER" \
  timeout 15 "$REAL_GIT" -C "$R18TMP" -c credential.helper= -c "credential.helper=$R18SHIM" \
  -c core.sshCommand='ssh -o BatchMode=yes -o ConnectTimeout=3' \
  push --dry-run --no-verify "https://nonresolve.invalid/o/r.git" HEAD:refs/heads/probe >/dev/null 2>&1
# NOTE: GIT_CONFIG_COUNT=0 makes git IGNORE the GIT_CONFIG_KEY_0/VALUE_0 pair -> the env helper must never run.
if ! grep -qE 'ENVCFG_OP' "$ENVLOG"; then
  pass "F1 r18: env-injected helper (GIT_CONFIG_COUNT=0) neutralized — never invoked (no store/erase)"
else
  fail "F1 r18: env-injected helper still ran (ops: $(tr '\n' ' ' < "$ENVLOG"))"
fi
rm -rf "$R18TMP"
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

# --- F3 (ASYMMETRIC): a GitHub SSH authz-denial is NOT-ACCEPTED -> advisory; PASS unaffected (the surface
# never needs to classify the rejection reason — only an accepted push matters).
WT3="$TMP/wt-authz"; mkdir -p "$WT3"
"$REAL_GIT" -C "$WT3" init -q
"$REAL_GIT" -C "$WT3" remote add origin "git@github.com:o/r.git"
: > "$MUTLOG"
if RO_TARGET="$WT3" RO_GIT_SSH=authzdenied run_strict "RO_aaa" "" "" denied rejected; then
  echo "$RO_OUT" | grep -q 'no ambient push credential was accepted' && pass "F3/asymmetric: SSH authz-denial -> advisory (not accepted), PASS unaffected" || fail "F3: authz-denial advisory note not reported"
else
  fail "F3/asymmetric: an authz-denied (not-accepted) push must NOT block the PASS"
fi

# --- F1 r16: a HOMOGRAPH/suffix host (ssh.github.com.evil) must NOT be treated as GitHub — it is skipped
# (never dry-run-probed, so its remote helper is never executed). An ACCEPTING evil origin therefore does NOT
# produce a FAIL from that origin (only the synthesized real-github URLs are probed, which reject).
WT16="$TMP/wt-homograph"; mkdir -p "$WT16"
"$REAL_GIT" -C "$WT16" init -q
"$REAL_GIT" -C "$WT16" remote add origin "ssh://git@ssh.github.com.evil/o/r.git"
: > "$MUTLOG"
RO_TARGET="$WT16" RO_GIT_SSH=accepted run_strict "RO_aaa" "" "" denied rejected || true
if grep 'GIT_PUSH_ATTEMPT' "$MUTLOG" | grep -q 'ssh.github.com.evil'; then
  fail "F1 r16: a homograph host (ssh.github.com.evil) was dry-run-probed (treated as GitHub)"
else
  echo "$RO_OUT" | grep -q 'not a GitHub remote' && pass "F1 r16: homograph host (ssh.github.com.evil) rejected by strict allowlist (not probed)" || fail "F1 r16: homograph host not flagged as non-GitHub"
fi

# --- F2 r16: MULTIPLE origin push URLs are all probed. A worktree with two pushurls where the SECOND is a
# GitHub remote that ACCEPTS must FAIL (the second url is not missed).
WT16b="$TMP/wt-multipush"; mkdir -p "$WT16b"
"$REAL_GIT" -C "$WT16b" init -q
"$REAL_GIT" -C "$WT16b" remote add origin "https://github.com/o/r.git"
"$REAL_GIT" -C "$WT16b" remote set-url --add --push origin "https://github.com/o/r.git"
"$REAL_GIT" -C "$WT16b" remote set-url --add --push origin "git@github.com:o/r.git"   # second pushurl (SSH)
: > "$MUTLOG"
RO_TARGET="$WT16b" RO_GIT_SSH=accepted run_strict "RO_aaa" "" "" denied rejected
if [ $? -eq 0 ]; then
  fail "F2 r16: a second (SSH) push URL that accepts must FAIL — it was missed"
else
  echo "$RO_OUT" | grep -q 'ambient git push: FAIL' && pass "F2 r16: all origin push URLs probed (second accepting URL -> FAIL)" || fail "F2 r16: multiple push URLs not all probed"
fi

# --- plain doctor prints the read-only section as a labeled reporter (does not require engineer identity to PASS
#     for the read-only verdict to print). We only assert the section + verdict line appear.
PLAIN_OUT=$(PATH="$BIN:$PATH" GH_TOKEN="RO_aaa" READONLY_SMOKE_API=denied READONLY_SMOKE_GIT=rejected \
  WF_READONLY_TOKEN_CMD="" WF_READONLY_TOKEN_INFO_CMD="$INFOCMD" WF_ALLOW_AMBIENT_IDENTITY=1 \
  bash "$WF" doctor claude "$REPO" 2>&1 || true)
echo "$PLAIN_OUT" | grep -q 'read-only ambient credential (#166)' && pass "plain doctor prints the read-only section" || fail "plain doctor missing the read-only section"
echo "$PLAIN_OUT" | grep -q 'read-only ambient verdict:' && pass "plain doctor prints the read-only verdict line" || fail "plain doctor missing the verdict line"

if [ "$fails" -gt 0 ]; then echo "[smoke] FAILED ($fails)"; exit 1; fi
echo "[smoke] all read-only-ambient detector checks passed"
