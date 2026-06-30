#!/bin/bash
# automated-researcher deterministic checks + behavior smoke. TRACKED check profile (run by ship_change.sh).
# Args: the changed paths being shipped. Runs from the repo root. Exit non-zero on ANY failure.
# The pyramid: cheap deterministic checks first, then the fake-HOME behavior smoke for plugin/skill changes.
set -uo pipefail
PATHS=("$@")
fail=0
err(){ echo "  CHECK-FAIL: $*" >&2; fail=1; }
ok(){ echo "  ok: $*" >&2; }

changed_under(){ local pfx=$1; printf '%s\n' "${PATHS[@]}" | grep -q "^$pfx" ; }

ROOT="$(git rev-parse --show-toplevel)"

echo "[checks] automated-researcher — ${#PATHS[@]} path(s)" >&2

# 1. JSON validity (manifests/marketplace)
for p in "${PATHS[@]}"; do case "$p" in
  *.json) [ -f "$p" ] && { python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$p" 2>/dev/null && ok "json $p" || err "invalid JSON: $p"; } ;;
esac; done

# 1b. README install namespace must match marketplace.json:name. The fake-HOME smoke reads the namespace
#     from the manifest, so it cannot catch docs that teach `plugin install <plugin>@wrong-name`.
if printf '%s\n' "${PATHS[@]}" | grep -Eq '^(README\.md|\.claude-plugin/marketplace\.json)$'; then
  if CHECK_ROOT="$ROOT" python3 - <<'PY'
import json
import os
import pathlib
import re
import sys

root = pathlib.Path(os.environ["CHECK_ROOT"])
market = json.loads((root / ".claude-plugin/marketplace.json").read_text())["name"]
readme = (root / "README.md").read_text()
names = sorted(set(re.findall(r"(?:^|\s)/?(?:claude\s+)?plugin\s+install\s+\S+@([A-Za-z0-9._-]+)", readme)))
bad = [name for name in names if name != market]
if bad:
    print(f"README plugin-install namespace(s) {bad} != marketplace name {market}", file=sys.stderr)
    sys.exit(1)
if not names:
    print("README contains no plugin install namespace examples", file=sys.stderr)
    sys.exit(1)
PY
  then ok "README install namespace matches marketplace.json:name"
  else err "README install namespace drift"
  fi
fi

# 1c. Disposition references and executable gate labels must stay synced with the canonical AGENTS.md section.
#     Plugin-only installs cannot rely on repo-root AGENTS.md being present, but the product still needs one
#     editorial home for the issue disposition contract. Dependent plugins therefore ship synced references, and
#     wf.sh enforces the same label set at merge time.
if printf '%s\n' "${PATHS[@]}" | grep -Eq '^(AGENTS\.md|plugins/[^/]+/skills/[^/]+/references/DISPOSITIONS\.md)$'; then
  if CHECK_ROOT="$ROOT" python3 - <<'PY'
import os
import pathlib
import sys

root = pathlib.Path(os.environ["CHECK_ROOT"])
agents = (root / "AGENTS.md").read_text()
start = "<!-- DISPOSITIONS:START -->"
end = "<!-- DISPOSITIONS:END -->"

def extract(text: str, label: str) -> str:
    if text.count(start) != 1 or text.count(end) != 1:
        print(f"{label} must contain exactly one disposition reference block", file=sys.stderr)
        sys.exit(1)
    body = text.split(start, 1)[1].split(end, 1)[0]
    return f"{start}{body}{end}\n"

# The ship-change driver + its packaged DISPOSITIONS.md (and the wf.sh label cross-check) moved to
# agentic-engineering with the aar-engineering plugin (#270); that repo's checks own that sync now.
# Here we keep the editorial guarantee for the product's REMAINING packaged disposition references
# (feedback-loop's), which must still match AGENTS.md's canonical block.
canonical = extract(agents, "AGENTS.md")
refs = sorted(root.glob("plugins/*/skills/*/references/DISPOSITIONS.md"))
# Assert the product's REMAINING packaged disposition references still exist — otherwise deleting them
# would let this check vacuously pass (empty glob) while feedback-loop skills reference missing files
# (#270 code-review F2). feedback-loop ships these in both its independently-installed skill dirs.
required = [
    root / "plugins/feedback-loop/skills/file-feedback/references/DISPOSITIONS.md",
    root / "plugins/feedback-loop/skills/triage-feedback/references/DISPOSITIONS.md",
]
missing = [str(r.relative_to(root)) for r in required if r not in refs]
if missing:
    print("missing required packaged disposition reference(s): " + ", ".join(missing), file=sys.stderr)
    sys.exit(1)
bad = []
for ref in refs:
    if ref.read_text() != canonical:
        bad.append(str(ref.relative_to(root)))
if bad:
    print("packaged disposition reference drift: " + ", ".join(bad), file=sys.stderr)
    sys.exit(1)
PY
  then ok "packaged disposition references match AGENTS.md"
  else err "disposition reference sync check failed"
  fi
fi

# 1d. feedback-loop exposes two independently installed skills, so its init helper is packaged in both skill dirs.
#     Keep the copies byte-identical; unlike DISPOSITIONS.md there is no separate editorial source.
if printf '%s\n' "${PATHS[@]}" | grep -Eq '^plugins/feedback-loop/skills/(file-feedback|triage-feedback)/scripts/feedback_loop_init\.sh$'; then
  FF_INIT="$ROOT/plugins/feedback-loop/skills/file-feedback/scripts/feedback_loop_init.sh"
  TF_INIT="$ROOT/plugins/feedback-loop/skills/triage-feedback/scripts/feedback_loop_init.sh"
  if [ -f "$FF_INIT" ] && [ -f "$TF_INIT" ] && cmp -s "$FF_INIT" "$TF_INIT"; then
    ok "feedback-loop init copies match"
  else
    err "feedback_loop_init.sh copies drift; keep file-feedback and triage-feedback copies byte-identical"
  fi
fi

# 1e. experiment-lifecycle ships the aar-profile SCHEMA.md reference in both independently-installed skill dirs
#     (design-experiment + run-experiment), same per-skill-copy precedent as feedback-loop's init helper (#153).
#     Keep the copies byte-identical AND assert each carries exactly one integer SCHEMA_VERSION marker — the
#     product schema_version constant later helpers extract; a drift-only check would pass two identical but
#     marker-less docs.
if printf '%s\n' "${PATHS[@]}" | grep -Eq '^plugins/experiment-lifecycle/skills/(design-experiment|run-experiment)/references/SCHEMA\.md$'; then
  DE_SCHEMA="$ROOT/plugins/experiment-lifecycle/skills/design-experiment/references/SCHEMA.md"
  RE_SCHEMA="$ROOT/plugins/experiment-lifecycle/skills/run-experiment/references/SCHEMA.md"
  if [ -f "$DE_SCHEMA" ] && [ -f "$RE_SCHEMA" ] && cmp -s "$DE_SCHEMA" "$RE_SCHEMA"; then
    ok "aar-profile SCHEMA.md copies match"
  else
    err "aar-profile SCHEMA.md copies drift; keep design-experiment and run-experiment copies byte-identical"
  fi
  for s in "$DE_SCHEMA" "$RE_SCHEMA"; do
    [ -f "$s" ] || continue
    n=$(grep -cE '^<!-- SCHEMA_VERSION: [0-9]+ -->$' "$s")
    if [ "$n" = 1 ]; then ok "SCHEMA_VERSION marker in $(basename "$(dirname "$(dirname "$s")")")/references/SCHEMA.md"
    else err "SCHEMA.md must carry exactly one integer SCHEMA_VERSION marker (found $n in $s)"; fi
  done
fi

# 2. shell syntax — *.sh AND extensionless shell scripts (e.g. .githooks/* hooks) detected by shebang
for p in "${PATHS[@]}"; do
  [ -f "$p" ] || continue
  is_sh=0
  case "$p" in
    *.sh) is_sh=1 ;;
    *) head -1 "$p" 2>/dev/null | grep -qE '^#!.*(bash|/sh|env +sh)\b' && is_sh=1 ;;
  esac
  [ "$is_sh" = 1 ] && { bash -n "$p" 2>/dev/null && ok "bash -n $p" || err "bash syntax: $p"; }
done

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
  [ -f "$pj" ] || { ok "plugin $plugdir removed (no version check)"; continue; }   # deleted plugin dir: nothing to version-bump
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
SMOKE="$ROOT/.aar-ci/fake_home_smoke.sh"
SMOKE_PLUGS=$(printf '%s\n' "${PATHS[@]}" | grep '^plugins/' | sed -E 's#plugins/([^/]+)/.*#\1#')
MP_DECLARED=""   # plugins DECLARED in marketplace.json (when it changed) — these MUST exist, never skipped
if printf '%s\n' "${PATHS[@]}" | grep -q '^\.claude-plugin/marketplace.json$'; then
  if MP_DECLARED=$(python3 -c "import json;print('\n'.join(p['name'] for p in json.load(open('$ROOT/.claude-plugin/marketplace.json'))['plugins']))" 2>/dev/null); then
    SMOKE_PLUGS="$SMOKE_PLUGS
$MP_DECLARED"
  else
    err "marketplace.json changed but its plugin list could not be parsed (schema broken?) — cannot smoke discovery"
  fi
fi
for plug in $(printf '%s\n' "$SMOKE_PLUGS" | grep -v '^$' | sort -u); do
  # An absent plugin dir is only OK when it was DELETED in this changeset (came from a changed plugins/ path);
  # a plugin DECLARED in marketplace.json but missing is a broken marketplace and must FAIL (#270 code-review F1).
  if [ ! -d "$ROOT/plugins/$plug" ]; then
    if printf '%s\n' "$MP_DECLARED" | grep -qxF "$plug"; then
      err "marketplace.json declares plugin '$plug' but plugins/$plug is missing — discovery would break"
    else
      ok "plugin $plug removed (no smoke)"
    fi
    continue
  fi
  if [ -f "$SMOKE" ]; then
    echo "[checks] behavior smoke: $plug" >&2
    bash "$SMOKE" "$(git rev-parse --show-toplevel)" "$plug" && ok "smoke $plug" || err "fake-HOME smoke FAILED for $plug"
  else
    err "behavior smoke required for plugin change ($plug) but fake_home_smoke.sh missing — auto-merge must not proceed without it"
  fi
done

# 7-8. ship-change driver smokes (locate_audit / identity / fd_state / issue_verbs / gh-guard static+behavior /
#       readonly-ambient / disposition_gate) moved to agentic-engineering with the aar-engineering plugin (#270).
#       That repo's .aar-ci profile owns the ship-change composition smokes now; this product profile keeps only
#       the checks for the plugins it still ships.

# 10. run-supervision-record smoke (#168): the monotonic state machine + fail-closed is-desired-active +
#     atomic writes + the update-vs-stop/close race — behavior the JSON/syntax checks can't cover. Runs
#     when the helper or its smoke changed.
if printf '%s\n' "${PATHS[@]}" | grep -Eq '^plugins/experiment-lifecycle/skills/run-experiment/scripts/run_supervision_record(_smoke)?\.sh$'; then
  RSR_SMOKE="$ROOT/plugins/experiment-lifecycle/skills/run-experiment/scripts/run_supervision_record_smoke.sh"
  if [ -f "$RSR_SMOKE" ]; then
    echo "[checks] run-supervision-record smoke" >&2
    bash "$RSR_SMOKE" >&2 && ok "run_supervision_record smoke" || err "run_supervision_record smoke FAILED"
  else
    err "run_supervision_record.sh changed but run_supervision_record_smoke.sh missing — cannot verify the record helper"
  fi
fi

# 11. pod-lease + reaper smoke (#169): the 3-phase create + expiry-driven is-reapable + the locked
#     reap (refresh-vs-reap race) + report-unknown-never-delete + unresolved-key report-only + legacy
#     keepalive (future/inconclusive/past) + dry-run — behavior the JSON/syntax checks can't cover.
#     Runs when either helper or its smoke changed.
if printf '%s\n' "${PATHS[@]}" | grep -Eq '^plugins/gpu-job/skills/gpu-job/scripts/(pod_lease|pod_lease_smoke|pod_reaper|pod_reaper_smoke)\.sh$'; then
  PL_SMOKE="$ROOT/plugins/gpu-job/skills/gpu-job/scripts/pod_lease_smoke.sh"
  if [ -f "$PL_SMOKE" ]; then
    echo "[checks] pod-lease smoke" >&2
    bash "$PL_SMOKE" >&2 && ok "pod_lease smoke" || err "pod_lease smoke FAILED"
  else
    err "pod_lease.sh changed but pod_lease_smoke.sh missing — cannot verify the lease helper"
  fi
  PR_SMOKE="$ROOT/plugins/gpu-job/skills/gpu-job/scripts/pod_reaper_smoke.sh"
  if [ -f "$PR_SMOKE" ]; then
    echo "[checks] pod-reaper smoke" >&2
    bash "$PR_SMOKE" >&2 && ok "pod_reaper smoke" || err "pod_reaper smoke FAILED"
  else
    err "pod_reaper.sh changed but pod_reaper_smoke.sh missing — cannot verify the reaper logic"
  fi
fi

[ "$fail" = 0 ] && { echo "[checks] PASS" >&2; exit 0; } || { echo "[checks] FAIL" >&2; exit 1; }
