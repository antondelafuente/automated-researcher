#!/usr/bin/env bash
# update_site_smoke.sh — behavior smoke for the update-site skill (#365, #369; renamed from
# visualize-results by #484).
# Deterministic, fully offline: exercises resolve_visualization_recipe.sh's fail-closed resolution,
# the explicit-publish boundary, and the distinct-destinations no-cross-resolution guarantee between
# [recipes.visualization_publish] and [recipes.viewer], plus a static instance-leak check on the
# skill's own shipped files. Skill DISCOVERY itself (install into a virgin HOME, frontmatter present)
# is already covered by the generic .aar-ci/fake_home_smoke.sh for any plugin/skill change; this smoke
# covers what that one can't: the recipe-resolution + publish-boundary BEHAVIOR. Exit non-zero on any
# failure.
set -uo pipefail
ROOT=${1:?repo root}
SKILL_DIR="$ROOT/plugins/experiment-lifecycle/skills/update-site"
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

# All three recipes point at DISTINCT repos/paths/git_refs on purpose (an instance where the
# dashboard viewer and the editorial visualization-publish destination genuinely diverge, #369) so a
# cross-resolution (publish leaking viewer's values, or vice versa) is mechanically detectable.
complete_profile() {
  cat > "$1" <<'EOF'
schema_version = 1
[recipes.visualization_preview]
kind = "repo"
repo = "owner/preview-repo"
path = "recipes/visualization-preview.md"
git_ref = "aaaa111"
[recipes.visualization_publish]
kind = "repo"
repo = "owner/editorial-repo"
path = "recipes/visualization-publish.md"
git_ref = "bbbb222"
[recipes.viewer]
kind = "repo"
repo = "owner/dashboard-repo"
path = "recipes/viewer.md"
git_ref = "cccc333"
EOF
}

# 1. Complete-recipe resolution (preview mode): succeeds, prints preview fields.
complete_profile "$T/complete.toml"
out=$(AAR_PROFILE="$T/complete.toml" bash "$RESOLVE" 2>"$T/err1")
rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '^VISUALIZATION_PREVIEW_GIT_REF=aaaa111$'; then
  ok "complete-recipe resolution succeeds and prints preview fields"
else
  err "complete-recipe resolution failed (rc=$rc): $(cat "$T/err1")"
fi
# and must NOT leak either publish-side recipe's fields in default (non-publish) mode
if printf '%s\n' "$out" | grep -qE '^(VIEWER_|VISUALIZATION_PUBLISH_)'; then
  err "default (preview) mode leaked VIEWER_*/VISUALIZATION_PUBLISH_* fields — publish boundary is not being enforced"
else
  ok "default (preview) mode never resolves/emits [recipes.viewer] or [recipes.visualization_publish] fields"
fi

# 2. Missing profile entirely: BLOCKs.
if AAR_PROFILE="$T/does-not-exist.toml" bash "$RESOLVE" >/dev/null 2>"$T/err2"; then
  err "resolver succeeded with no profile present at all"
else
  grep -qi 'no instance profile found' "$T/err2" && ok "missing profile BLOCKs with a clear message" \
    || err "missing profile failed but without the expected message: $(cat "$T/err2")"
fi

# 3. Profile present, but recipes.visualization_preview table absent: BLOCKs (even though [recipes.viewer]
#    is configured — proves preview resolution never falls back to reading an unrelated recipe key).
cat > "$T/no-recipe.toml" <<'EOF'
schema_version = 1
[recipes.viewer]
kind = "repo"
repo = "owner/dashboard-repo"
path = "recipes/viewer.md"
git_ref = "cccc333"
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
repo = "owner/preview-repo"
path = "recipes/visualization-preview.md"
EOF
if AAR_PROFILE="$T/incomplete.toml" bash "$RESOLVE" >/dev/null 2>"$T/err4"; then
  err "resolver succeeded with an incomplete recipe (missing git_ref)"
else
  grep -qi "missing required field 'git_ref'" "$T/err4" && ok "incomplete recipe BLOCKs with a clear message" \
    || err "incomplete recipe failed but without the expected message: $(cat "$T/err4")"
fi

# 4b. Field-format validation: a bare 'owner' repo (no slash) is rejected — not just presence-checked
#     (code-review F3). Isolated from the absolute-path case (4b2 below) so a broken absolute-path
#     validator can't pass undetected behind the repo check alone already blocking (#368 finding 4).
cat > "$T/malformed-repo.toml" <<'EOF'
schema_version = 1
[recipes.visualization_preview]
kind = "repo"
repo = "owner"
path = "recipes/visualization-preview.md"
git_ref = "abc1234"
EOF
if AAR_PROFILE="$T/malformed-repo.toml" bash "$RESOLVE" >/dev/null 2>"$T/err4b"; then
  err "resolver accepted a repo without an owner/repo slash"
else
  ok "a non-owner/repo 'repo' value is rejected, not just presence-checked"
fi

# 4b2. An absolute path is rejected on its own, independent of 4b's repo check (#368 finding 4).
cat > "$T/malformed-path.toml" <<'EOF'
schema_version = 1
[recipes.visualization_preview]
kind = "repo"
repo = "owner/preview-repo"
path = "/etc/passwd"
git_ref = "abc1234"
EOF
if AAR_PROFILE="$T/malformed-path.toml" bash "$RESOLVE" >/dev/null 2>"$T/err4b2"; then
  err "resolver accepted an absolute path"
else
  ok "an absolute path is rejected, not just presence-checked"
fi

# 4c. A kind=uri value containing shell metacharacters is rejected outright (code-review F2). The
#     charset reduces shell-metacharacter exposure but deliberately keeps '&' in-band, so it does NOT
#     make sourcing/eval of resolver output safe — the actual safeguard is the resolver header's
#     prohibition on ever sourcing/eval'ing this output (#585 P1).
cat > "$T/uri-metachars.toml" <<'EOF'
schema_version = 1
[recipes.visualization_preview]
kind = "uri"
uri = "https://example.com/x;touch pwned"
sha256 = "abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd"
EOF
if AAR_PROFILE="$T/uri-metachars.toml" bash "$RESOLVE" >/dev/null 2>"$T/err4c"; then
  err "resolver accepted a URI containing a shell metacharacter"
else
  ok "a URI containing shell metacharacters is rejected by the safe charset"
fi

# 4d. A kind=uri value with a port, a query string, and a fragment — all ordinary, all rejected by the
#     prior narrow allow-list — is now accepted (#368 finding 1: the charset must not be stricter than
#     the schema's own supported-scheme semantics require).
cat > "$T/uri-query-fragment.toml" <<'EOF'
schema_version = 1
[recipes.visualization_preview]
kind = "uri"
uri = "https://example.com:8443/recipes/visualization-preview.md?rev=3&lang=en#section-2"
sha256 = "abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd"
EOF
if out4d=$(AAR_PROFILE="$T/uri-query-fragment.toml" bash "$RESOLVE" 2>"$T/err4d") \
  && printf '%s\n' "$out4d" | grep -qF 'VISUALIZATION_PREVIEW_URI=https://example.com:8443/recipes/visualization-preview.md?rev=3&lang=en#section-2'; then
  ok "a URI with a port, query string, and fragment is accepted (#368 finding 1)"
else
  err "a URI with a port/query/fragment was wrongly rejected: $(cat "$T/err4d")"
fi

# 4e. A repo-relative path with ordinary punctuation outside the prior narrow allow-list is accepted
#     (#368 finding 1), while still going through the same traversal/absolute-path/unsafe-char checks.
cat > "$T/path-punctuation.toml" <<'EOF'
schema_version = 1
[recipes.visualization_preview]
kind = "repo"
repo = "owner/preview-repo"
path = "recipes/notes,v2+final@home!.md"
git_ref = "abc1234"
EOF
if out4e=$(AAR_PROFILE="$T/path-punctuation.toml" bash "$RESOLVE" 2>"$T/err4e") \
  && printf '%s\n' "$out4e" | grep -qF 'VISUALIZATION_PREVIEW_PATH=recipes/notes,v2+final@home!.md'; then
  ok "a repo-relative path with ordinary punctuation outside the old narrow charset is accepted (#368 finding 1)"
else
  err "a repo-relative path with ordinary punctuation was wrongly rejected: $(cat "$T/err4e")"
fi

# 4f. A kind=repo table that ALSO sets a kind=uri-only field ('uri') fails closed instead of silently
#     ignoring the stray field (#368 finding 2, direction 1).
cat > "$T/repo-with-stray-uri-field.toml" <<'EOF'
schema_version = 1
[recipes.visualization_preview]
kind = "repo"
repo = "owner/preview-repo"
path = "recipes/visualization-preview.md"
git_ref = "abc1234"
uri = "https://example.com/should-not-be-here"
EOF
if AAR_PROFILE="$T/repo-with-stray-uri-field.toml" bash "$RESOLVE" >/dev/null 2>"$T/err4f"; then
  err "resolver accepted a kind=repo table with a stray 'uri' field instead of failing closed (#368 finding 2)"
else
  ok "kind=repo table with a stray kind=uri-only field ('uri') fails closed"
fi

# 4g. A kind=uri table that ALSO sets a kind=repo-only field ('path') fails closed (#368 finding 2,
#     direction 2).
cat > "$T/uri-with-stray-repo-field.toml" <<'EOF'
schema_version = 1
[recipes.visualization_preview]
kind = "uri"
uri = "https://example.com/recipes/visualization-preview.md"
sha256 = "abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd"
path = "recipes/visualization-preview.md"
EOF
if AAR_PROFILE="$T/uri-with-stray-repo-field.toml" bash "$RESOLVE" >/dev/null 2>"$T/err4g"; then
  err "resolver accepted a kind=uri table with a stray 'path' field instead of failing closed (#368 finding 2)"
else
  ok "kind=uri table with a stray kind=repo-only field ('path') fails closed"
fi

# 4h. schema_version=true must not be accepted via Python's bool/int equality (True == 1) (#368 finding 3).
cat > "$T/schema-version-bool.toml" <<'EOF'
schema_version = true
[recipes.visualization_preview]
kind = "repo"
repo = "owner/preview-repo"
path = "recipes/visualization-preview.md"
git_ref = "abc1234"
EOF
if AAR_PROFILE="$T/schema-version-bool.toml" bash "$RESOLVE" >/dev/null 2>"$T/err4h"; then
  err "resolver accepted schema_version=true instead of requiring the integer 1 (#368 finding 3)"
else
  ok "schema_version=true is rejected, not accepted via Python's bool/int equality"
fi

# 4i. schema_version=1.0 must not be accepted via Python's float/int equality (1.0 == 1) (#368 finding 3).
cat > "$T/schema-version-float.toml" <<'EOF'
schema_version = 1.0
[recipes.visualization_preview]
kind = "repo"
repo = "owner/preview-repo"
path = "recipes/visualization-preview.md"
git_ref = "abc1234"
EOF
if AAR_PROFILE="$T/schema-version-float.toml" bash "$RESOLVE" >/dev/null 2>"$T/err4i"; then
  err "resolver accepted schema_version=1.0 instead of requiring the integer 1 (#368 finding 3)"
else
  ok "schema_version=1.0 is rejected, not accepted via Python's float/int equality"
fi

# 4j. A repo-relative path with a traversal segment hidden after a '?' is still rejected — the
#     traversal check must not strip query/fragment text for repo paths, which have no such syntax
#     of their own (#585 P0, review round 1).
cat > "$T/path-traversal-after-query.toml" <<'EOF'
schema_version = 1
[recipes.visualization_preview]
kind = "repo"
repo = "owner/preview-repo"
path = "recipes/x?/../../secret"
git_ref = "abc1234"
EOF
if AAR_PROFILE="$T/path-traversal-after-query.toml" bash "$RESOLVE" >/dev/null 2>"$T/err4j"; then
  err "resolver accepted a repo path with a traversal segment hidden after '?' (#585 P0)"
else
  ok "a repo path with a traversal segment hidden after '?' is rejected"
fi

# 4k. A kind=uri value with an empty authority (no host/bucket before the query string) is rejected
#     (#585 P0, review round 1).
cat > "$T/uri-no-authority.toml" <<'EOF'
schema_version = 1
[recipes.visualization_preview]
kind = "uri"
uri = "https://?query=yes"
sha256 = "abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd"
EOF
if AAR_PROFILE="$T/uri-no-authority.toml" bash "$RESOLVE" >/dev/null 2>"$T/err4k"; then
  err "resolver accepted a URI with no authority/host (#585 P0)"
else
  ok "a URI with an empty authority (no host/bucket) is rejected"
fi

# 4l. A kind=uri https:// value with a non-empty but host-less authority (a bare ':port') is rejected —
#     the round-1 fix (4k) only caught an authority starting with '/', '?', or '#'; 'https://:8443/recipe'
#     has a non-empty authority (':8443') with no hostname before the colon (#585 P0, review round 2).
cat > "$T/uri-authority-no-host.toml" <<'EOF'
schema_version = 1
[recipes.visualization_preview]
kind = "uri"
uri = "https://:8443/recipe"
sha256 = "abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd"
EOF
if AAR_PROFILE="$T/uri-authority-no-host.toml" bash "$RESOLVE" >/dev/null 2>"$T/err4l"; then
  err "resolver accepted a URI whose authority has a port but no host (#585 P0, round 2)"
else
  ok "a URI with a port but no host in its authority is rejected"
fi

# 4m. The host/bucket requirement applies to every scheme, not just https — the round-2 fix checked
#     https only, so 'r2://:8443/recipe' (port, no bucket) and 's3://@/recipe' (userinfo, no bucket)
#     still passed (#585 P0, review round 3).
for bad_uri in "r2://:8443/recipe" "s3://@/recipe"; do
  cat > "$T/uri-hostless-scheme.toml" <<EOF
schema_version = 1
[recipes.visualization_preview]
kind = "uri"
uri = "$bad_uri"
sha256 = "abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd"
EOF
  if AAR_PROFILE="$T/uri-hostless-scheme.toml" bash "$RESOLVE" >/dev/null 2>"$T/err4m"; then
    err "resolver accepted hostless URI '$bad_uri' (#585 P0, round 3)"
  else
    ok "hostless URI '$bad_uri' is rejected (host/bucket check is scheme-independent)"
  fi
done

# 5. Explicit publish boundary: --publish on the complete profile resolves [recipes.visualization_publish]
#    — its OWN publish-destination recipe — and never [recipes.viewer].
out5=$(AAR_PROFILE="$T/complete.toml" bash "$RESOLVE" --publish 2>"$T/err5")
rc5=$?
if [ "$rc5" -eq 0 ] && printf '%s\n' "$out5" | grep -q '^VISUALIZATION_PUBLISH_GIT_REF=bbbb222$'; then
  ok "--publish resolves [recipes.visualization_publish] (the explicit boundary, opt-in)"
else
  err "--publish did not resolve visualization_publish fields (rc=$rc5): $(cat "$T/err5")"
fi

# 5a. Distinct-destinations regression (#369): on a profile where [recipes.viewer] and
#     [recipes.visualization_publish] point at genuinely different repos/paths/git_refs, --publish's
#     output must carry ONLY the visualization_publish recipe's values and must NEVER contain a VIEWER_
#     line — proving the two destinations cannot cross-resolve even when both are configured.
if printf '%s\n' "$out5" | grep -q '^VISUALIZATION_PUBLISH_REPO=owner/editorial-repo$' \
  && printf '%s\n' "$out5" | grep -q '^VISUALIZATION_PUBLISH_PATH=recipes/visualization-publish.md$' \
  && ! printf '%s\n' "$out5" | grep -q '^VIEWER_'; then
  ok "--publish emits ONLY visualization_publish's own repo/path/git_ref, never [recipes.viewer] — distinct destinations do not cross-resolve"
else
  err "--publish output crossed destinations or leaked viewer fields: $out5"
fi

# 6. --publish fails closed (with ZERO stdout leakage) if [recipes.visualization_preview] is missing
#    entirely (even though [recipes.viewer] is configured) — preview resolution blocks first.
if out6=$(AAR_PROFILE="$T/no-recipe.toml" bash "$RESOLVE" --publish 2>"$T/err6"); then
  err "--publish succeeded with no recipes.visualization_preview table at all"
else
  : # expected: no visualization_preview means preview resolution itself already blocks first
fi

# 6a. --publish fails closed (with ZERO stdout leakage) if [recipes.visualization_publish] is absent,
#    even though [recipes.visualization_preview] alone is complete AND [recipes.viewer] IS configured —
#    proves the boundary can't be worked around by falling back to [recipes.viewer].
cat > "$T/preview-and-viewer-only.toml" <<'EOF'
schema_version = 1
[recipes.visualization_preview]
kind = "repo"
repo = "owner/preview-repo"
path = "recipes/visualization-preview.md"
git_ref = "aaaa111"
[recipes.viewer]
kind = "repo"
repo = "owner/dashboard-repo"
path = "recipes/viewer.md"
git_ref = "cccc333"
EOF
if out7=$(AAR_PROFILE="$T/preview-and-viewer-only.toml" bash "$RESOLVE" --publish 2>"$T/err7"); then
  err "--publish succeeded with no recipes.visualization_publish configured (viewer-only-for-publish profile)"
else
  [ -z "$out7" ] && grep -qi 'recipes.visualization_publish.*not configured' "$T/err7" \
    && ok "--publish BLOCKs (no stdout leak) when [recipes.visualization_publish] is unconfigured, even with [recipes.viewer] present" \
    || err "--publish-without-visualization_publish failure lacked the expected message or leaked stdout: out=[$out7] err=[$(cat "$T/err7")]"
fi

# 7. Hardcoded-instance-path absence: static grep over this skill's own shipped files (excluding this
#    smoke script itself, whose own source necessarily quotes the forbidden literals as the pattern).
LEAK_PATTERN='research-lab|/home/anton|cloudflare|\.trycloudflare\.com|:[0-9]{4,5}\b'
leaked=$(grep -RinE "$LEAK_PATTERN" "$SKILL_DIR" --include='*.md' --include='*.sh' \
  2>/dev/null | grep -v '/scripts/update_site_smoke\.sh:' || true)
if [ -n "$leaked" ]; then
  err "instance-specific value(s) found in update-site skill source:"
  printf '%s\n' "$leaked" >&2
else
  ok "no hardcoded research-lab/home-anton/hostname-port/cloudflare values in update-site"
fi

[ "$fail" = 0 ] && { echo "  smoke ok: update-site recipe resolution + publish boundary + distinct-destinations + no instance leak" >&2; exit 0; } || exit 1
