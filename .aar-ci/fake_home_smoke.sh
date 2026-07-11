#!/bin/bash
# fake_home_smoke.sh — behavior test: a plugin must INSTALL into a virgin HOME and its skills must RESOLVE.
# Deterministic checks (JSON/syntax) can't catch an install/discovery break; this can. Gates auto-merge.
# Args: <marketplace-source-repo> <plugin-name>.  Exit non-zero on any failure. Destroys the fake HOME after.
set -uo pipefail
REPO=${1:?marketplace source repo}; PLUG=${2:?plugin name}
# validate the plugin name before it ever touches a path or CLI arg (no traversal/injection)
[[ "$PLUG" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "  SMOKE-FAIL: invalid plugin name: $PLUG" >&2; exit 1; }
# fail fast and unambiguously if the CLI itself is missing, rather than letting every invocation below
# die at command-not-found with its output swallowed by >/dev/null (automated-researcher#407)
command -v claude >/dev/null 2>&1 || { echo "  SMOKE-FAIL: claude CLI not installed" >&2; exit 1; }
V=$(mktemp -d "${TMPDIR:-/tmp}/smoke.XXXXXX") || { echo "  SMOKE-FAIL: mktemp failed" >&2; exit 1; }   # private dir, independent of $PLUG
cleanup(){ rm -rf "$V"; }
trap cleanup EXIT
fail=0; err(){ echo "  SMOKE-FAIL: $*" >&2; fail=1; }

mkdir -p "$V/.claude" "$V/proj" || { echo "  SMOKE-FAIL: mkdir failed in $V" >&2; exit 1; }
# seed the minimum to run `claude plugin` headlessly (creds only; everything else virgin).
# Prefer the box's local OAuth creds (box runs keep working unchanged); when absent, fall back to
# ANTHROPIC_API_KEY (GitHub runners have no OAuth creds but do have this repo secret) -- it's already
# in this process's environment, so it carries through the `HOME="$V" claude plugin ...` invocations
# below unchanged (they only override HOME, not the rest of the env). Fail closed when NEITHER is
# available: this smoke must never silently no-op.
if [ -f "$HOME/.claude/.credentials.json" ]; then
  cp "$HOME/.claude/.credentials.json" "$V/.claude/.credentials.json" || err "could not seed credentials.json"
  cp "$HOME/.git-credentials" "$V/.git-credentials" 2>/dev/null || true
  python3 -c "import json,os;s=json.load(open(os.path.expanduser('~/.claude.json')));json.dump({k:s[k] for k in ('oauthAccount','userID','hasCompletedOnboarding','firstStartTime') if k in s},open('$V/.claude.json','w'))" 2>/dev/null || err "could not seed .claude.json"
elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  # API-key auth needs no credentials.json on disk; just enough .claude.json to skip onboarding.
  python3 -c "import json;json.dump({'hasCompletedOnboarding': True}, open('$V/.claude.json','w'))" 2>/dev/null || err "could not seed .claude.json"
else
  err "no credentials to seed"
fi

cd "$V/proj" || { echo "  SMOKE-FAIL: cd into fake HOME failed" >&2; exit 1; }
# marketplace NAME comes from the manifest, not the dir basename (a worktree/checkout may not match it)
MKT=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['name'])" "$REPO/.claude-plugin/marketplace.json" 2>/dev/null) || err "could not read marketplace name"
# capture combined output to a log instead of >/dev/null so a real failure's cause is visible in
# SMOKE-FAIL rather than requiring a separate debugging round (automated-researcher#407)
MKTLOG="$V/marketplace-add.log"; INSTLOG="$V/plugin-install.log"
HOME="$V" claude plugin marketplace add "$REPO" >"$MKTLOG" 2>&1 || err "marketplace add failed: $(tail -n 5 "$MKTLOG")"
HOME="$V" claude plugin install "$PLUG@${MKT:-$(basename "$REPO")}" >"$INSTLOG" 2>&1 || err "plugin install failed: $PLUG: $(tail -n 5 "$INSTLOG")"

# installed cache for this plugin (highest version)
PDIR=$(find "$V/.claude/plugins/cache" -maxdepth 3 -type d -path "*/$PLUG/*" 2>/dev/null | sort -V | tail -1)
[ -n "$PDIR" ] && [ -d "$PDIR" ] || err "plugin did not land in the install cache: $PLUG"

if [ -n "${PDIR:-}" ]; then
  # plugin.json valid + every skill resolves (SKILL.md present) + no instance-leak in installed skill files
  python3 -c "import json;json.load(open('$PDIR/.claude-plugin/plugin.json'))" 2>/dev/null || err "installed plugin.json invalid"
  found=0
  for sk in "$PDIR"/skills/*/SKILL.md; do
    [ -f "$sk" ] || continue; found=1
    fm=$(awk 'NR==1&&$0=="---"{infm=1;next} infm&&$0=="---"{exit} infm' "$sk")   # only the YAML frontmatter block
    printf '%s\n' "$fm" | grep -qiE '^name:' || err "skill missing 'name:' in frontmatter: $sk"
    printf '%s\n' "$fm" | grep -qiE '^description:' || err "skill missing 'description:' in frontmatter: $sk"
  done
  [ "$found" = 1 ] || err "no resolvable skills (skills/*/SKILL.md) in installed $PLUG"
fi
# (leak-scanning is NOT a behavior test — it lives in the deterministic checks on the diff, and the
#  cross-family --code review is the judgment-based catch. A blunt grep over-flags doc-examples.)

[ "$fail" = 0 ] && { echo "  smoke ok: $PLUG installs + resolves in a virgin HOME" >&2; exit 0; } || exit 1
