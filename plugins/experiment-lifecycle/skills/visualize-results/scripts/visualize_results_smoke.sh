#!/usr/bin/env bash
# visualize_results_smoke.sh — behavior smoke for the visualize-results skill (#365).
# Deterministic, fully offline: exercises resolve_visualization_recipe.sh's fail-closed resolution
# and the explicit-publish boundary, plus a static instance-leak check on the skill's own shipped
# files. Skill DISCOVERY itself (install into a virgin HOME, frontmatter present) is already covered
# by the generic .aar-ci/fake_home_smoke.sh for any plugin/skill change; this smoke covers what that
# one can't: the recipe-resolution + publish-boundary BEHAVIOR. Exit non-zero on any failure.
set -uo pipefail
ROOT=${1:?repo root}
SKILL_DIR="$ROOT/plugins/experiment-lifecycle/skills/visualize-results"
RESOLVE="$SKILL_DIR/scripts/resolve_visualization_recipe.sh"

fail=0
err(){ echo "  SMOKE-FAIL: $*" >&2; fail=1; }
ok(){ echo "  smoke ok: $*" >&2; }

[ -x "$RESOLVE" ] || [ -f "$RESOLVE" ] || { echo "  SMOKE-FAIL: resolver missing: $RESOLVE" >&2; exit 1; }

T=$(mktemp -d "${TMPDIR:-/tmp}/vizsmoke.XXXXXX") || { echo "  SMOKE-FAIL: mktemp failed" >&2; exit 1; }
cleanup(){ rm -rf "$T"; }
trap cleanup EXIT
# Isolate from any REAL instance profile on this box — both lookup legs must miss.
export XDG_CONFIG_HOME="$T/xdg-empty"

complete_profile() {
  cat > "$1" <<'EOF'
schema_version = 1
[recipes.visualization_preview]
kind = "repo"
repo = "owner/viewer-repo"
path = "recipes/visualization-preview.md"
git_ref = "abc1234"
[recipes.viewer]
kind = "repo"
repo = "owner/viewer-repo"
path = "recipes/viewer.md"
git_ref = "def56789"
EOF
}

# 1. Complete-recipe resolution (preview mode): succeeds, prints preview fields.
complete_profile "$T/complete.toml"
out=$(AAR_PROFILE="$T/complete.toml" bash "$RESOLVE" 2>"$T/err1")
rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '^VISUALIZATION_PREVIEW_GIT_REF=abc1234$'; then
  ok "complete-recipe resolution succeeds and prints preview fields"
else
  err "complete-recipe resolution failed (rc=$rc): $(cat "$T/err1")"
fi
# and must NOT leak viewer fields in default (non-publish) mode
if printf '%s\n' "$out" | grep -q '^VIEWER_'; then
  err "default (preview) mode leaked VIEWER_* fields — publish boundary is not being enforced"
else
  ok "default (preview) mode never resolves/emits [recipes.viewer] fields"
fi

# 2. Missing profile entirely: BLOCKs.
if AAR_PROFILE="$T/does-not-exist.toml" bash "$RESOLVE" >/dev/null 2>"$T/err2"; then
  err "resolver succeeded with no profile present at all"
else
  grep -qi 'no instance profile found' "$T/err2" && ok "missing profile BLOCKs with a clear message" \
    || err "missing profile failed but without the expected message: $(cat "$T/err2")"
fi

# 3. Profile present, but recipes.visualization_preview table absent: BLOCKs.
cat > "$T/no-recipe.toml" <<'EOF'
schema_version = 1
[recipes.viewer]
kind = "repo"
repo = "owner/viewer-repo"
path = "recipes/viewer.md"
git_ref = "def56789"
EOF
if AAR_PROFILE="$T/no-recipe.toml" bash "$RESOLVE" >/dev/null 2>"$T/err3"; then
  err "resolver succeeded with no recipes.visualization_preview table"
else
  grep -qi 'visualization_preview.*not configured' "$T/err3" && ok "absent recipe table BLOCKs with a clear message" \
    || err "absent recipe table failed but without the expected message: $(cat "$T/err3")"
fi

# 4. Profile present, recipe table present but INCOMPLETE (missing git_ref): BLOCKs.
cat > "$T/incomplete.toml" <<'EOF'
schema_version = 1
[recipes.visualization_preview]
kind = "repo"
repo = "owner/viewer-repo"
path = "recipes/visualization-preview.md"
EOF
if AAR_PROFILE="$T/incomplete.toml" bash "$RESOLVE" >/dev/null 2>"$T/err4"; then
  err "resolver succeeded with an incomplete recipe (missing git_ref)"
else
  grep -qi "missing required field 'git_ref'" "$T/err4" && ok "incomplete recipe BLOCKs with a clear message" \
    || err "incomplete recipe failed but without the expected message: $(cat "$T/err4")"
fi

# 5. Explicit publish boundary: --publish on the complete profile ALSO resolves [recipes.viewer].
out5=$(AAR_PROFILE="$T/complete.toml" bash "$RESOLVE" --publish 2>"$T/err5")
rc5=$?
if [ "$rc5" -eq 0 ] && printf '%s\n' "$out5" | grep -q '^VIEWER_GIT_REF=def56789$'; then
  ok "--publish resolves [recipes.viewer] (the explicit boundary, opt-in)"
else
  err "--publish did not resolve viewer fields (rc=$rc5): $(cat "$T/err5")"
fi

# 6. --publish fails closed (with ZERO stdout leakage) if [recipes.viewer] is absent, even though
#    [recipes.visualization_preview] alone is complete — proves the boundary can't be worked around
#    by a preview-only profile.
if out6=$(AAR_PROFILE="$T/no-recipe.toml" bash "$RESOLVE" --publish 2>"$T/err6"); then
  err "--publish succeeded with no recipes.visualization_preview table at all"
else
  : # expected: no visualization_preview means preview resolution itself already blocks first
fi
cat > "$T/preview-only.toml" <<'EOF'
schema_version = 1
[recipes.visualization_preview]
kind = "repo"
repo = "owner/viewer-repo"
path = "recipes/visualization-preview.md"
git_ref = "abc1234"
EOF
if out7=$(AAR_PROFILE="$T/preview-only.toml" bash "$RESOLVE" --publish 2>"$T/err7"); then
  err "--publish succeeded with no recipes.viewer configured (preview-only profile)"
else
  [ -z "$out7" ] && grep -qi 'recipes.viewer.*not configured' "$T/err7" \
    && ok "--publish BLOCKs (no stdout leak) when [recipes.viewer] is unconfigured" \
    || err "--publish-without-viewer failure lacked the expected message or leaked stdout: out=[$out7] err=[$(cat "$T/err7")]"
fi

# 7. Hardcoded-instance-path absence: static grep over this skill's own shipped files (excluding this
#    smoke script itself, whose own source necessarily quotes the forbidden literals as the pattern).
LEAK_PATTERN='research-lab|/home/anton|cloudflare|\.trycloudflare\.com|:[0-9]{4,5}\b'
leaked=$(grep -RinE "$LEAK_PATTERN" "$SKILL_DIR" --include='*.md' --include='*.sh' \
  2>/dev/null | grep -v '/scripts/visualize_results_smoke\.sh:' || true)
if [ -n "$leaked" ]; then
  err "instance-specific value(s) found in visualize-results skill source:"
  printf '%s\n' "$leaked" >&2
else
  ok "no hardcoded research-lab/home-anton/hostname-port/cloudflare values in visualize-results"
fi

[ "$fail" = 0 ] && { echo "  smoke ok: visualize-results recipe resolution + publish boundary + no instance leak" >&2; exit 0; } || exit 1
