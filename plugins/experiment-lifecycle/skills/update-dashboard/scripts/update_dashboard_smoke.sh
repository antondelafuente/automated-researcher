#!/usr/bin/env bash
# update_dashboard_smoke.sh — behavior smoke for the update-dashboard skill (#484).
# Deterministic, fully offline: exercises resolve_viewer_recipe.sh's fail-closed resolution of
# [recipes.viewer] (missing profile / missing recipe table / incomplete recipe / malformed fields all
# BLOCK), plus a static instance-leak check on the skill's own shipped files. Skill DISCOVERY itself
# (install into a virgin HOME, frontmatter present) is already covered by the generic
# .aar-ci/fake_home_smoke.sh for any plugin/skill change; this smoke covers what that one can't: the
# recipe-resolution BEHAVIOR. Exit non-zero on any failure.
set -uo pipefail
ROOT=${1:?repo root}
SKILL_DIR="$ROOT/plugins/experiment-lifecycle/skills/update-dashboard"
RESOLVE="$SKILL_DIR/scripts/resolve_viewer_recipe.sh"

fail=0
err(){ echo "  SMOKE-FAIL: $*" >&2; fail=1; }
ok(){ echo "  smoke ok: $*" >&2; }

[ -x "$RESOLVE" ] || [ -f "$RESOLVE" ] || { echo "  SMOKE-FAIL: resolver missing: $RESOLVE" >&2; exit 1; }

T=$(mktemp -d "${TMPDIR:-/tmp}/dashsmoke.XXXXXX") || { echo "  SMOKE-FAIL: mktemp failed" >&2; exit 1; }
cleanup(){ rm -rf "$T"; }
trap cleanup EXIT
# Isolate from any REAL instance profile on this box — both lookup legs must miss.
export XDG_CONFIG_HOME="$T/xdg-empty"

# 1. Complete-recipe resolution: succeeds, prints VIEWER_ fields.
cat > "$T/complete.toml" <<'EOF'
schema_version = 1
[recipes.viewer]
kind = "repo"
repo = "owner/dashboard-repo"
path = "recipes/viewer.md"
git_ref = "cccc333"
EOF
out=$(AAR_PROFILE="$T/complete.toml" bash "$RESOLVE" 2>"$T/err1")
rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '^VIEWER_GIT_REF=cccc333$' \
  && printf '%s\n' "$out" | grep -q '^VIEWER_REPO=owner/dashboard-repo$'; then
  ok "complete-recipe resolution succeeds and prints viewer fields (including the recipe revision)"
else
  err "complete-recipe resolution failed (rc=$rc): $(cat "$T/err1")"
fi

# 2. Missing profile entirely: BLOCKs.
if AAR_PROFILE="$T/does-not-exist.toml" bash "$RESOLVE" >/dev/null 2>"$T/err2"; then
  err "resolver succeeded with no profile present at all"
else
  grep -qi 'no instance profile found' "$T/err2" && ok "missing profile BLOCKs with a clear message" \
    || err "missing profile failed but without the expected message: $(cat "$T/err2")"
fi

# 3. Profile present, but recipes.viewer table absent: BLOCKs (even though an unrelated recipe is
#    configured — proves resolution never falls back to reading an unrelated recipe key).
cat > "$T/no-recipe.toml" <<'EOF'
schema_version = 1
[recipes.visualization_preview]
kind = "repo"
repo = "owner/preview-repo"
path = "recipes/visualization-preview.md"
git_ref = "aaaa111"
EOF
if AAR_PROFILE="$T/no-recipe.toml" bash "$RESOLVE" >/dev/null 2>"$T/err3"; then
  err "resolver succeeded with no recipes.viewer table"
else
  grep -qi 'viewer.*not configured' "$T/err3" && ok "absent recipe table BLOCKs with a clear message" \
    || err "absent recipe table failed but without the expected message: $(cat "$T/err3")"
fi

# 4. Profile present, recipe table present but INCOMPLETE (missing git_ref): BLOCKs.
cat > "$T/incomplete.toml" <<'EOF'
schema_version = 1
[recipes.viewer]
kind = "repo"
repo = "owner/dashboard-repo"
path = "recipes/viewer.md"
EOF
if AAR_PROFILE="$T/incomplete.toml" bash "$RESOLVE" >/dev/null 2>"$T/err4"; then
  err "resolver succeeded with an incomplete recipe (missing git_ref)"
else
  grep -qi "missing required field 'git_ref'" "$T/err4" && ok "incomplete recipe BLOCKs with a clear message" \
    || err "incomplete recipe failed but without the expected message: $(cat "$T/err4")"
fi

# 4b. Field-format validation: a bare 'owner' repo (no slash) and an absolute path are both rejected —
#     not just presence-checked (same guard as update-site's resolver).
cat > "$T/malformed-fields.toml" <<'EOF'
schema_version = 1
[recipes.viewer]
kind = "repo"
repo = "owner"
path = "/etc/passwd"
git_ref = "abc1234"
EOF
if AAR_PROFILE="$T/malformed-fields.toml" bash "$RESOLVE" >/dev/null 2>"$T/err4b"; then
  err "resolver accepted a repo without an owner/repo slash"
else
  ok "a non-owner/repo 'repo' value is rejected, not just presence-checked"
fi

# 4c. A kind=uri value containing shell metacharacters is rejected outright — the safe charset, not
#     caller-side quoting, is what prevents injection if this output is ever naively sourced.
cat > "$T/uri-metachars.toml" <<'EOF'
schema_version = 1
[recipes.viewer]
kind = "uri"
uri = "https://example.com/x;touch pwned"
sha256 = "abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd"
EOF
if AAR_PROFILE="$T/uri-metachars.toml" bash "$RESOLVE" >/dev/null 2>"$T/err4c"; then
  err "resolver accepted a URI containing a shell metacharacter"
else
  ok "a URI containing shell metacharacters is rejected by the safe charset"
fi

# 5. Unknown argument BLOCKs (no silent ignore of a typo'd flag).
if bash "$RESOLVE" --publish >/dev/null 2>"$T/err5"; then
  err "resolver accepted an unknown argument (--publish; this resolver takes none)"
else
  grep -qi 'unknown argument' "$T/err5" && ok "an unknown argument BLOCKs with a clear message" \
    || err "unknown-argument rejection lacked the expected message: $(cat "$T/err5")"
fi

# 6. Hardcoded-instance-path absence: static grep over this skill's own shipped files (excluding this
#    smoke script itself, whose own source necessarily quotes the forbidden literals as the pattern).
LEAK_PATTERN='research-lab|/home/anton|cloudflare|\.trycloudflare\.com|:[0-9]{4,5}\b'
leaked=$(grep -RinE "$LEAK_PATTERN" "$SKILL_DIR" --include='*.md' --include='*.sh' \
  2>/dev/null | grep -v '/scripts/update_dashboard_smoke\.sh:' || true)
if [ -n "$leaked" ]; then
  err "instance-specific value(s) found in update-dashboard skill source:"
  printf '%s\n' "$leaked" >&2
else
  ok "no hardcoded research-lab/home-anton/hostname-port/cloudflare values in update-dashboard"
fi

[ "$fail" = 0 ] && { echo "  smoke ok: update-dashboard viewer-recipe resolution + no instance leak" >&2; exit 0; } || exit 1
