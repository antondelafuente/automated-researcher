#!/bin/bash
# aar-skills deterministic checks + behavior smoke. TRACKED check profile (run by ship_change.sh).
# Args: the changed paths being shipped. Runs from the repo root. Exit non-zero on ANY failure.
# The pyramid: cheap deterministic checks first, then the fake-HOME behavior smoke for plugin/skill changes.
set -uo pipefail
PATHS=("$@")
fail=0
err(){ echo "  CHECK-FAIL: $*" >&2; fail=1; }
ok(){ echo "  ok: $*" >&2; }

changed_under(){ local pfx=$1; printf '%s\n' "${PATHS[@]}" | grep -q "^$pfx" ; }

echo "[checks] aar-skills — ${#PATHS[@]} path(s)" >&2

# 1. JSON validity (manifests/marketplace)
for p in "${PATHS[@]}"; do case "$p" in
  *.json) [ -f "$p" ] && { python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$p" 2>/dev/null && ok "json $p" || err "invalid JSON: $p"; } ;;
esac; done

# 2. shell syntax
for p in "${PATHS[@]}"; do case "$p" in
  *.sh) [ -f "$p" ] && { bash -n "$p" 2>/dev/null && ok "bash -n $p" || err "bash syntax: $p"; } ;;
esac; done

# 3. python compiles
for p in "${PATHS[@]}"; do case "$p" in
  *.py) [ -f "$p" ] && { python3 -c "import sys; compile(open(sys.argv[1]).read(), sys.argv[1], 'exec')" "$p" 2>/dev/null && ok "py-syntax $p" || err "py-syntax: $p"; } ;;   # in-memory: no __pycache__ written (keeps the tree clean)
esac; done

# 4. instance-leak / secrets: NOT re-implemented here. The repo's pre-commit secrets hook
#    (.githooks/pre-commit) is the deterministic backstop for instance specifics + secrets, and the
#    cross-family --code review is the judgment-based catch. Hardcoding instance patterns in a product
#    check would itself be instance-coupling (and trips the secrets hook on its own regex).

# 5. version bump: if a plugin's non-manifest file changed, its plugin.json version must have moved
# Compare against the INTEGRATION BASE (merge-base with main), not HEAD: the change may be uncommitted on
# main (old flow → base==HEAD==main) OR already committed on a branch (worktree-from-the-start flow → HEAD
# already has the new version; only the merge-base holds the prior one). Using HEAD broke the committed flow
# (it compared the new version against itself). Falls back to HEAD when there's no main (e.g. a fresh repo).
BASE=$(git merge-base HEAD origin/main 2>/dev/null || git merge-base HEAD main 2>/dev/null || git rev-parse HEAD 2>/dev/null || echo HEAD)
for plugdir in $(printf '%s\n' "${PATHS[@]}" | grep '^plugins/' | sed -E 's#(plugins/[^/]+)/.*#\1#' | sort -u); do
  nonmanifest=$(printf '%s\n' "${PATHS[@]}" | grep "^$plugdir/" | grep -v '\.claude-plugin/plugin.json' || true)
  [ -n "$nonmanifest" ] || continue
  pj="$plugdir/.claude-plugin/plugin.json"
  oldv=$(git show "$BASE:$pj" 2>/dev/null | python3 -c "import json,sys;print(json.load(sys.stdin).get('version',''))" 2>/dev/null)
  newv=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('version',''))" "$pj" 2>/dev/null)
  if [ -z "$oldv" ]; then ok "new plugin manifest $pj (v${newv:-?})"; continue; fi   # new plugin: no prior version to bump
  # require the version to actually INCREASE (an added/moved/reformatted/downgraded version line is not a bump)
  if [ -n "$newv" ] && python3 -c "import sys; o=[int(x) for x in sys.argv[1].split('.')]; n=[int(x) for x in sys.argv[2].split('.')]; sys.exit(0 if n>o else 1)" "$oldv" "$newv" 2>/dev/null; then ok "version bumped $oldv -> $newv: $pj"
  else err "$plugdir changed but $pj version not INCREASED ($oldv -> ${newv:-?}); consumers would miss the change"; fi
done

# 6. behavior smoke (fake-HOME install -> skill discovery) — gates auto-merge for plugin/skill changes (deterministic
#    checks can't catch an install/discovery break). Smoke the changed plugins; AND if the root marketplace.json
#    changed, smoke every plugin it declares (a marketplace edit can break discovery for any of them).
ROOT="$(git rev-parse --show-toplevel)"
SMOKE="$ROOT/.aar-ci/fake_home_smoke.sh"
SMOKE_PLUGS=$(printf '%s\n' "${PATHS[@]}" | grep '^plugins/' | sed -E 's#plugins/([^/]+)/.*#\1#')
if printf '%s\n' "${PATHS[@]}" | grep -q '^\.claude-plugin/marketplace.json$'; then
  if mp=$(python3 -c "import json;print('\n'.join(p['name'] for p in json.load(open('$ROOT/.claude-plugin/marketplace.json'))['plugins']))" 2>/dev/null); then
    SMOKE_PLUGS="$SMOKE_PLUGS
$mp"
  else
    err "marketplace.json changed but its plugin list could not be parsed (schema broken?) — cannot smoke discovery"
  fi
fi
for plug in $(printf '%s\n' "$SMOKE_PLUGS" | grep -v '^$' | sort -u); do
  if [ -f "$SMOKE" ]; then
    echo "[checks] behavior smoke: $plug" >&2
    bash "$SMOKE" "$(git rev-parse --show-toplevel)" "$plug" && ok "smoke $plug" || err "fake-HOME smoke FAILED for $plug"
  else
    err "behavior smoke required for plugin change ($plug) but fake_home_smoke.sh missing — auto-merge must not proceed without it"
  fi
done

[ "$fail" = 0 ] && { echo "[checks] PASS" >&2; exit 0; } || { echo "[checks] FAIL" >&2; exit 1; }
