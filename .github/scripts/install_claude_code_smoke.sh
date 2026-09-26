#!/usr/bin/env bash
# Behavior smoke for .github/scripts/install-claude-code.sh (automated-researcher#872).
#
# The installer's whole reason to exist is the FALLBACK path: #384/#385 shipped a CLI that installed
# cleanly and then crashed at SDK launch, and every CLI-running leg of the pipeline now depends on this
# script catching that and degrading to the known-good version instead of taking the whole pipeline down.
# That path is, by construction, the one a healthy CI run never exercises — so it gets a deterministic
# test here, driven entirely by stub `npm`/`claude` binaries on PATH (no network, no API key, no npm
# registry), the same offline-testability property .github/scripts/blocked-state.sh's smoke has.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INSTALLER="$SCRIPT_DIR/install-claude-code.sh"
FALLBACK_VERSION="2.1.282"   # must match the installer's single constant; asserted below

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok: %s\n' "$*" >&2; }

[ -x "$INSTALLER" ] || fail "install-claude-code.sh missing or not executable at $INSTALLER"
grep -q "FALLBACK_VERSION=\"$FALLBACK_VERSION\"" "$INSTALLER" \
  || fail "installer's FALLBACK_VERSION no longer matches this smoke's expectation ($FALLBACK_VERSION)"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# --- stub toolchain -------------------------------------------------------------------------------
# `npm install -g @anthropic-ai/claude-code@<spec>` fails for any spec listed in STUB_BAD_INSTALL, and
# otherwise materializes a stub `claude` that records which spec it came from.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/npm" <<'NPM_STUB'
#!/usr/bin/env bash
set -euo pipefail
pkg=""
for arg in "$@"; do
  case "$arg" in @anthropic-ai/claude-code@*) pkg="$arg" ;; esac
done
[ -n "$pkg" ] || { echo "npm stub: no @anthropic-ai/claude-code@<spec> in: $*" >&2; exit 2; }
spec="${pkg##*@}"
echo "$spec" >> "$STUB_STATE/installs"
case " ${STUB_BAD_INSTALL:-} " in
  *" $spec "*) echo "npm ERR! No matching version found for @anthropic-ai/claude-code@$spec" >&2; exit 1 ;;
esac
printf '%s' "$spec" > "$STUB_STATE/installed_spec"
NPM_STUB

# The stub CLI mimics the real launch contract: `--version` always works (that is exactly why a version
# check could not catch #384), while the stream-json launch fails for any spec listed in STUB_BAD_LAUNCH.
cat > "$WORK/bin/claude" <<'CLAUDE_STUB'
#!/usr/bin/env bash
set -euo pipefail
spec=$(cat "$STUB_STATE/installed_spec")
if [ "${1:-}" = "--version" ]; then
  echo "$spec (Claude Code)"
  exit 0
fi
cat > /dev/null   # drain the stream-json prompt on stdin
echo "$spec" >> "$STUB_STATE/launches"
case " ${STUB_BAD_LAUNCH:-} " in
  *" $spec "*) echo "SDK execution error" >&2; exit 1 ;;
esac
printf '{"type":"assistant","message":{"model":"stub-model-for-%s"}}\n' "$spec"
printf '{"type":"result","subtype":"success","is_error":false}\n'
CLAUDE_STUB
chmod +x "$WORK/bin/npm" "$WORK/bin/claude"

# --- harness --------------------------------------------------------------------------------------
# Runs the installer against the stubs and leaves its parsed outputs in OUT_* / the captured log.
run_installer() {
  local state="$WORK/state" rc=0
  rm -rf "$state"; mkdir -p "$state"
  : > "$state/installs"
  : > "$state/launches"
  : > "$state/gh_output"
  printf 'none' > "$state/installed_spec"

  GITHUB_OUTPUT="$state/gh_output" GITHUB_STEP_SUMMARY="$state/gh_summary" \
  STUB_STATE="$state" PATH="$WORK/bin:$PATH" \
    "$INSTALLER" > "$state/stdout" 2> "$state/stderr" || rc=$?

  RC=$rc
  STATE=$state
  OUT_SOURCE=$(sed -n 's/^source=//p' "$state/gh_output" | tail -n1 || true)
  OUT_VERSION=$(sed -n 's/^version=//p' "$state/gh_output" | tail -n1 || true)
  OUT_PATH=$(sed -n 's/^path=//p' "$state/gh_output" | tail -n1 || true)
  INSTALLS=$(tr '\n' ' ' < "$state/installs")
}

# 1. Healthy @latest: installed once, smoked, kept. No fallback install at all.
( export ANTHROPIC_API_KEY=stub-key; unset AAR_CLAUDE_CODE_VERSION STUB_BAD_INSTALL STUB_BAD_LAUNCH
  run_installer
  [ "$RC" -eq 0 ] || fail "healthy latest: expected exit 0, got $RC"
  [ "$OUT_SOURCE" = "requested" ] || fail "healthy latest: source=$OUT_SOURCE (want requested)"
  [ "$INSTALLS" = "latest " ] || fail "healthy latest: installs=[$INSTALLS] (want just latest)"
  [ "$OUT_PATH" = "$WORK/bin/claude" ] || fail "healthy latest: path=$OUT_PATH"
  grep -q 'Claude Code CLI' "$STATE/gh_summary" || fail "healthy latest: no job-summary record written"
  grep -q 'version: `latest (Claude Code)`' "$STATE/gh_summary" || fail "healthy latest: version missing from summary"
  pass "healthy @latest is kept and recorded"
)

# 2. The #384 class: @latest installs fine and then dies at SDK launch -> known-good fallback.
( export ANTHROPIC_API_KEY=stub-key STUB_BAD_LAUNCH="latest"
  run_installer
  [ "$RC" -eq 0 ] || fail "crashing latest: expected exit 0 (degrade, never fail), got $RC"
  [ "$OUT_SOURCE" = "fallback" ] || fail "crashing latest: source=$OUT_SOURCE (want fallback)"
  [ "$INSTALLS" = "latest $FALLBACK_VERSION " ] || fail "crashing latest: installs=[$INSTALLS]"
  [ "$OUT_VERSION" = "$FALLBACK_VERSION (Claude Code)" ] || fail "crashing latest: version=$OUT_VERSION"
  grep -q '::warning::.*failed its launch smoke test' "$STATE/stdout" \
    || fail "crashing latest: no warning annotation naming the rejected version"
  pass "a CLI that crashes at SDK launch falls back to the known-good version"
)

# 3. The issue's own acceptance check: a bogus requested version (npm install itself fails) -> fallback,
#    and the step still succeeds.
( export ANTHROPIC_API_KEY=stub-key AAR_CLAUDE_CODE_VERSION="99.99.99-bogus" STUB_BAD_INSTALL="99.99.99-bogus"
  run_installer
  [ "$RC" -eq 0 ] || fail "bogus version: expected exit 0, got $RC"
  [ "$OUT_SOURCE" = "fallback" ] || fail "bogus version: source=$OUT_SOURCE (want fallback)"
  [ "$INSTALLS" = "99.99.99-bogus $FALLBACK_VERSION " ] || fail "bogus version: installs=[$INSTALLS]"
  pass "a bogus requested version falls back and the step still passes"
)

# 4. No API key (fork-PR checks.yml): the launch path is unprovable, so never gamble on @latest.
( unset ANTHROPIC_API_KEY
  run_installer
  [ "$RC" -eq 0 ] || fail "no key: expected exit 0, got $RC"
  [ "$OUT_SOURCE" = "fallback" ] || fail "no key: source=$OUT_SOURCE (want fallback)"
  [ "$INSTALLS" = "$FALLBACK_VERSION " ] || fail "no key: installs=[$INSTALLS] (latest must not be tried)"
  [ ! -s "$STATE/launches" ] || fail "no key: smoke must not run without a key"
  pass "a missing API key installs the known-good version instead of an unverified one"
)

# 5. Fallback also fails its smoke: still usable, but flagged -- never a hard failure on a transient blip.
( export ANTHROPIC_API_KEY=stub-key STUB_BAD_LAUNCH="latest $FALLBACK_VERSION"
  run_installer
  [ "$RC" -eq 0 ] || fail "both fail smoke: expected exit 0, got $RC"
  [ "$OUT_SOURCE" = "fallback-unverified" ] || fail "both fail smoke: source=$OUT_SOURCE"
  pass "a fallback that also fails its smoke is flagged, not fatal"
)

# 6. No usable CLI at all is the one hard failure.
( export ANTHROPIC_API_KEY=stub-key STUB_BAD_INSTALL="latest $FALLBACK_VERSION"
  run_installer
  [ "$RC" -ne 0 ] || fail "no CLI: expected a non-zero exit when even the known-good install fails"
  grep -q '::error::' "$STATE/stdout" || fail "no CLI: expected an error annotation"
  pass "a runner with no installable CLI fails loudly"
)

printf 'install-claude-code smoke: all scenarios passed\n' >&2
