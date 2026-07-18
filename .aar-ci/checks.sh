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

# 1e. experiment-lifecycle ships the aar-profile SCHEMA.md reference in all three independently-installed
#     skill dirs that need it (design-experiment + run-experiment, same per-skill-copy precedent as
#     feedback-loop's init helper (#153); log-experiment joined them once its aar_profile_snapshot.sh copy
#     started reading the SCHEMA_VERSION marker from its own co-located copy, #472). Keep the copies
#     byte-identical AND assert each carries exactly one integer SCHEMA_VERSION marker — the product
#     schema_version constant later helpers extract; a drift-only check would pass identical but
#     marker-less docs.
if printf '%s\n' "${PATHS[@]}" | grep -Eq '^plugins/experiment-lifecycle/skills/(design-experiment|run-experiment|log-experiment)/references/SCHEMA\.md$'; then
  DE_SCHEMA="$ROOT/plugins/experiment-lifecycle/skills/design-experiment/references/SCHEMA.md"
  RE_SCHEMA="$ROOT/plugins/experiment-lifecycle/skills/run-experiment/references/SCHEMA.md"
  LE_SCHEMA="$ROOT/plugins/experiment-lifecycle/skills/log-experiment/references/SCHEMA.md"
  if [ -f "$DE_SCHEMA" ] && [ -f "$RE_SCHEMA" ] && [ -f "$LE_SCHEMA" ] && cmp -s "$DE_SCHEMA" "$RE_SCHEMA" && cmp -s "$DE_SCHEMA" "$LE_SCHEMA"; then
    ok "aar-profile SCHEMA.md copies match"
  else
    err "aar-profile SCHEMA.md copies drift; keep design-experiment, run-experiment, and log-experiment copies byte-identical"
  fi
  for s in "$DE_SCHEMA" "$RE_SCHEMA" "$LE_SCHEMA"; do
    [ -f "$s" ] || continue
    n=$(grep -cE '^<!-- SCHEMA_VERSION: [0-9]+ -->$' "$s")
    if [ "$n" = 1 ]; then ok "SCHEMA_VERSION marker in $(basename "$(dirname "$(dirname "$s")")")/references/SCHEMA.md"
    else err "SCHEMA.md must carry exactly one integer SCHEMA_VERSION marker (found $n in $s)"; fi
  done
fi

# 1f. experiment-lifecycle ships the aar_profile_snapshot.sh helper (#469) in both independently-installed
#     skill dirs that need it (design-experiment writes the snapshot; log-experiment's design-stage gate
#     reads it back with `check`), same per-skill-copy + drift-check precedent as SCHEMA.md (1e) and
#     feedback-loop's init helper (1d). Keep the copies byte-identical.
if printf '%s\n' "${PATHS[@]}" | grep -Eq '^plugins/experiment-lifecycle/skills/(design-experiment|log-experiment)/scripts/aar_profile_snapshot\.sh$'; then
  DE_SNAP="$ROOT/plugins/experiment-lifecycle/skills/design-experiment/scripts/aar_profile_snapshot.sh"
  LE_SNAP="$ROOT/plugins/experiment-lifecycle/skills/log-experiment/scripts/aar_profile_snapshot.sh"
  if [ -f "$DE_SNAP" ] && [ -f "$LE_SNAP" ] && cmp -s "$DE_SNAP" "$LE_SNAP"; then
    ok "aar_profile_snapshot.sh copies match"
  else
    err "aar_profile_snapshot.sh copies drift; keep design-experiment and log-experiment copies byte-identical"
  fi
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

# 3b. gpu-job deploy_pod.py behavior selftest (offline: region-selection + the #278 mid-create abort
#     trap). A signal trap that DELETEs a billing pod is billing-safety code — compile-only can't catch
#     a broken cleanup. `--selftest` requires no creds/network by construction.
for p in "${PATHS[@]}"; do case "$p" in
  */gpu-job/skills/gpu-job/scripts/deploy_pod.py)
    [ -f "$p" ] && { python3 "$p" --selftest >/dev/null 2>&1 && ok "deploy_pod --selftest ($p)" || err "deploy_pod --selftest FAILED: $p"; } ;;
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
# Parse the CURRENT marketplace declarations ALWAYS — not only when marketplace.json is in the changeset —
# so a PR that DELETES a plugin dir WITHOUT touching marketplace.json still fails loud on a declared-but-
# missing plugin (#274; mirror of the #280 guard on the marketplace-changed path). MP_PARSE_OK tracks
# whether the current file parsed: a MISSING marketplace.json is not a failure (empty list, PARSE_OK=1 —
# a deletion in a repo with no marketplace stays benign), but a PRESENT-yet-unparsable one is (PARSE_OK=0),
# and the missing-dir branch below fails closed on it rather than vacuously passing.
MP_DECLARED=""   # plugins DECLARED in the CURRENT marketplace.json — these MUST exist, never skipped
MP_PARSE_OK=1
MP_JSON="$ROOT/.claude-plugin/marketplace.json"
if [ -f "$MP_JSON" ]; then
  if ! MP_DECLARED=$(MP_JSON="$MP_JSON" python3 -c "import json,os;print('\n'.join(p['name'] for p in json.load(open(os.environ['MP_JSON']))['plugins']))" 2>/dev/null); then
    MP_PARSE_OK=0
    MP_DECLARED=""
  fi
fi
# When marketplace.json ITSELF changed, smoke EVERY declared plugin (a marketplace edit can break discovery
# for any of them). A parse failure on THIS path is fatal — we cannot know what to smoke.
if printf '%s\n' "${PATHS[@]}" | grep -q '^\.claude-plugin/marketplace.json$'; then
  if [ "$MP_PARSE_OK" = 1 ] && [ -f "$MP_JSON" ]; then
    SMOKE_PLUGS="$SMOKE_PLUGS
$MP_DECLARED"
  else
    err "marketplace.json changed but its plugin list could not be parsed (schema broken?) — cannot smoke discovery"
  fi
fi
for plug in $(printf '%s\n' "$SMOKE_PLUGS" | grep -v '^$' | sort -u); do
  # An absent plugin dir is only OK when it was DELETED in this changeset (came from a changed plugins/ path)
  # AND the CURRENT marketplace no longer declares it; a plugin still DECLARED in marketplace.json but missing
  # is a broken marketplace and must FAIL (#270 code-review F1; widened to the marketplace-unchanged path, #274).
  if [ ! -d "$ROOT/plugins/$plug" ]; then
    if printf '%s\n' "$MP_DECLARED" | grep -qxF "$plug"; then
      err "marketplace.json declares plugin '$plug' but plugins/$plug is missing — discovery would break"
    elif [ "$MP_PARSE_OK" != 1 ]; then
      err "plugins/$plug is missing but the current marketplace.json could not be parsed — cannot verify it isn't still declared"
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

# 10b. session self-reap smoke (#282): the clean-close guard (only closed-AND-not-stopped reaps), the
#     no-handle / unset-seam no-ops, and the self-only seam invocation passing the opaque handle — behavior
#     the JSON/syntax checks can't cover. Runs when the helper or its smoke changed.
if printf '%s\n' "${PATHS[@]}" | grep -Eq '^plugins/experiment-lifecycle/skills/run-experiment/scripts/reap_session(_smoke)?\.sh$'; then
  RS_SMOKE="$ROOT/plugins/experiment-lifecycle/skills/run-experiment/scripts/reap_session_smoke.sh"
  if [ -f "$RS_SMOKE" ]; then
    echo "[checks] session self-reap smoke" >&2
    bash "$RS_SMOKE" >&2 && ok "reap_session smoke" || err "reap_session smoke FAILED"
  else
    err "reap_session.sh changed but reap_session_smoke.sh missing — cannot verify the reap helper"
  fi
fi

# 10c. log-experiment secret-scan smoke (#306): the diff-scoped scan (a pre-existing merged file no longer
#     blocks a log that leaves it unchanged; a newly added/modified real key still blocks) + the sk- boundary
#     guard (a hyphenated identifier containing 'sk-' is not a false-positive) + the fail-safe fallback
#     (missing base ref -> full-dir scan) — behavior the JSON/syntax checks can't cover. Runs when the script
#     or its smoke changed.
if printf '%s\n' "${PATHS[@]}" | grep -Eq '^plugins/experiment-lifecycle/skills/log-experiment/scripts/(log-experiment\.sh|log_experiment_secret_scan_smoke\.sh)$'; then
  LE_SMOKE="$ROOT/plugins/experiment-lifecycle/skills/log-experiment/scripts/log_experiment_secret_scan_smoke.sh"
  if [ -f "$LE_SMOKE" ]; then
    echo "[checks] log-experiment secret-scan smoke" >&2
    bash "$LE_SMOKE" >&2 && ok "log-experiment secret-scan smoke" || err "log-experiment secret-scan smoke FAILED"
  else
    err "log-experiment.sh changed but log_experiment_secret_scan_smoke.sh missing — cannot verify the secret scan"
  fi
fi

# 10c2. log-experiment design-stage snapshot-gate smoke (#469): gate_design_stage's addition — a
#      design-stage record's START.md must carry an instance-profile snapshot that is present, parseable,
#      and not stale (aar_profile_snapshot.sh check) — the single deterministic enforcement owner that
#      closes the silent viewer-publish miss (#347). Runs when log-experiment.sh, either
#      aar_profile_snapshot.sh copy, or this smoke changed.
if printf '%s\n' "${PATHS[@]}" | grep -Eq '^plugins/experiment-lifecycle/skills/(log-experiment/scripts/(log-experiment\.sh|aar_profile_snapshot\.sh|log_experiment_design_stage_snapshot_smoke\.sh)|design-experiment/scripts/aar_profile_snapshot\.sh)$'; then
  DS_SMOKE="$ROOT/plugins/experiment-lifecycle/skills/log-experiment/scripts/log_experiment_design_stage_snapshot_smoke.sh"
  if [ -f "$DS_SMOKE" ]; then
    echo "[checks] log-experiment design-stage snapshot-gate smoke" >&2
    bash "$DS_SMOKE" >&2 && ok "log-experiment design-stage snapshot-gate smoke" || err "log-experiment design-stage snapshot-gate smoke FAILED"
  else
    err "log-experiment.sh or aar_profile_snapshot.sh changed but log_experiment_design_stage_snapshot_smoke.sh missing — cannot verify the design-stage snapshot gate"
  fi
fi

# 10c3. aar_profile_snapshot.sh helper smoke (#469): the snapshot/check round-trip itself (write, idempotent
#      re-write, staleness detection, fail-closed on a missing/unknown-schema profile, the
#      [recipes.viewer]-optional manifest-only path, and a tampered-snapshot presence mismatch), independent
#      of the log-experiment gate integration covered above. Runs when either copy or its smoke changed.
if printf '%s\n' "${PATHS[@]}" | grep -Eq '^plugins/experiment-lifecycle/skills/(design-experiment|log-experiment)/scripts/aar_profile_snapshot(_smoke)?\.sh$'; then
  APS_SMOKE="$ROOT/plugins/experiment-lifecycle/skills/design-experiment/scripts/aar_profile_snapshot_smoke.sh"
  if [ -f "$APS_SMOKE" ]; then
    echo "[checks] aar_profile_snapshot smoke" >&2
    bash "$APS_SMOKE" "$ROOT" >&2 && ok "aar_profile_snapshot smoke" || err "aar_profile_snapshot smoke FAILED"
  else
    err "aar_profile_snapshot.sh changed but aar_profile_snapshot_smoke.sh missing — cannot verify the snapshot helper"
  fi
fi

# 10d. update-site recipe-resolution smoke (#365, #369; skill renamed from visualize-results by #484): the
#     fail-closed resolution of [recipes.visualization_preview] (missing profile / missing recipe table /
#     incomplete recipe all BLOCK), the explicit-publish boundary (default mode never resolves/emits
#     [recipes.visualization_publish] or [recipes.viewer]; --publish resolves [recipes.visualization_publish]
#     and fails closed with zero stdout leakage if it's unconfigured, and never resolves [recipes.viewer] in
#     either mode), a distinct-destinations regression proving visualization_publish and viewer never
#     cross-resolve, and a static grep for hardcoded instance values in the skill's own shipped files —
#     behavior the JSON/syntax checks can't cover.
#     Runs on ANY change under the skill dir (not just the scripts), since the instance-leak grep scans
#     SKILL.md/references/ too — a leak added there alone must not bypass the guard (code-review F4).
if printf '%s\n' "${PATHS[@]}" | grep -Eq '^plugins/experiment-lifecycle/skills/update-site/'; then
  VR_SMOKE="$ROOT/plugins/experiment-lifecycle/skills/update-site/scripts/update_site_smoke.sh"
  if [ -f "$VR_SMOKE" ]; then
    echo "[checks] update-site recipe-resolution smoke" >&2
    bash "$VR_SMOKE" "$ROOT" >&2 && ok "update-site recipe-resolution smoke" || err "update-site recipe-resolution smoke FAILED"
  else
    err "resolve_visualization_recipe.sh changed but update_site_smoke.sh missing — cannot verify the recipe resolver"
  fi
fi

# 10e. update-dashboard viewer-recipe resolution smoke (#484): the fail-closed resolution of
#     [recipes.viewer] (missing profile / missing recipe table / incomplete recipe / malformed fields all
#     BLOCK, an unknown argument BLOCKs), and a static grep for hardcoded instance values in the skill's own
#     shipped files — behavior the JSON/syntax checks can't cover. Runs on ANY change under the skill dir
#     (not just the scripts), same instance-leak-scans-docs-too rationale as 10d.
if printf '%s\n' "${PATHS[@]}" | grep -Eq '^plugins/experiment-lifecycle/skills/update-dashboard/'; then
  UD_SMOKE="$ROOT/plugins/experiment-lifecycle/skills/update-dashboard/scripts/update_dashboard_smoke.sh"
  if [ -f "$UD_SMOKE" ]; then
    echo "[checks] update-dashboard viewer-recipe resolution smoke" >&2
    bash "$UD_SMOKE" "$ROOT" >&2 && ok "update-dashboard viewer-recipe resolution smoke" || err "update-dashboard viewer-recipe resolution smoke FAILED"
  else
    err "resolve_viewer_recipe.sh changed but update_dashboard_smoke.sh missing — cannot verify the recipe resolver"
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

# 11b. multi-adapter serve-loop smoke (#296): serve_adapters_eval's per-adapter output ISOLATION (a
#      pre-planted stale cache is wiped, never reused), teardown BETWEEN adapters (ordering), the
#      serve_fn numeric-PID contract (default + custom serve paths), and the distinctness assertion
#      that catches the "identical numbers across adapters" reuse bug (error dies / warn continues) —
#      behavior the JSON/syntax checks can't cover. Fully offline (stubs nvidia-smi/curl/pkill/pgrep/
#      python on PATH). Runs when job_lib.sh or the smoke changed.
if printf '%s\n' "${PATHS[@]}" | grep -Eq '^plugins/gpu-job/skills/gpu-job/scripts/(job_lib|multi_adapter_smoke)\.sh$'; then
  MA_SMOKE="$ROOT/plugins/gpu-job/skills/gpu-job/scripts/multi_adapter_smoke.sh"
  if [ -f "$MA_SMOKE" ]; then
    echo "[checks] multi-adapter serve-loop smoke" >&2
    bash "$MA_SMOKE" >&2 && ok "multi_adapter smoke" || err "multi_adapter smoke FAILED"
  else
    err "job_lib.sh changed but multi_adapter_smoke.sh missing — cannot verify the multi-adapter serve helper"
  fi
fi

# 11c. hardened rclone-helper smoke (#295): r2_copy ALWAYS injects -L and treats a `Can't follow
#      symlink` NOTICE as an INCOMPLETE copy (returns non-zero even when rclone exits 0 — the silent
#      data-loss swallow), propagates rclone's own non-zero exit, forwards extra args; and r2_exists
#      lists the DIRECTORY + `grep -qx` (never single-file lsf). Behavior the JSON/syntax checks can't
#      cover. Fully offline (stubs rclone on PATH). Runs when job_lib.sh or the smoke changed.
if printf '%s\n' "${PATHS[@]}" | grep -Eq '^plugins/gpu-job/skills/gpu-job/scripts/(job_lib|rclone_helper_smoke)\.sh$'; then
  RC_SMOKE="$ROOT/plugins/gpu-job/skills/gpu-job/scripts/rclone_helper_smoke.sh"
  if [ -f "$RC_SMOKE" ]; then
    echo "[checks] hardened rclone-helper smoke" >&2
    bash "$RC_SMOKE" >&2 && ok "rclone_helper smoke" || err "rclone_helper smoke FAILED"
  else
    err "job_lib.sh changed but rclone_helper_smoke.sh missing — cannot verify the hardened rclone helpers"
  fi
fi

# 12. cross-family verifier-selection smoke (#262/#239): audit_experiment.sh derives the auditor from
#     AAR_SUBSTRATE (opposite family), self-corrects a same-family / BASH_ENV-injected AUDIT_VERIFIER_CMD
#     instead of blocking, redirects the claude default to $OUT_TMP, and fails closed on unset/unknown
#     substrate — behavior the JSON/syntax checks can't cover. Offline seam. Runs when the script or its
#     smoke changed.
if printf '%s\n' "${PATHS[@]}" | grep -Eq '^plugins/verify-claims/skills/verify-claims/scripts/(audit_experiment|cross_family_verifier_smoke)\.sh$'; then
  CFV_SMOKE="$ROOT/plugins/verify-claims/skills/verify-claims/scripts/cross_family_verifier_smoke.sh"
  if [ -f "$CFV_SMOKE" ]; then
    echo "[checks] cross-family verifier-selection smoke" >&2
    bash "$CFV_SMOKE" >&2 && ok "cross_family_verifier smoke" || err "cross_family_verifier smoke FAILED"
  else
    err "audit_experiment.sh changed but cross_family_verifier_smoke.sh missing — cannot verify cross-family selection"
  fi
fi

# 13. marketplace missing-plugin cross-check smoke (#274): the step-6 branch that decides whether an absent
#     plugin dir is a benign deletion or a broken marketplace — declared-but-missing FAILs (both when
#     marketplace.json is in the changeset and when it is NOT), undeclared-deleted PASSes, and a present-but-
#     unparsable marketplace with a missing plugin FAILs closed. Deterministic behavior the JSON/syntax checks
#     can't cover, and the exact logic that regressed once (#280). Runs when checks.sh or the smoke changed.
if printf '%s\n' "${PATHS[@]}" | grep -Eq '^\.aar-ci/(checks|checks_marketplace_smoke)\.sh$'; then
  CM_SMOKE="$ROOT/.aar-ci/checks_marketplace_smoke.sh"
  if [ -f "$CM_SMOKE" ]; then
    echo "[checks] marketplace missing-plugin cross-check smoke" >&2
    bash "$CM_SMOKE" >&2 && ok "checks marketplace missing-plugin smoke" || err "checks marketplace missing-plugin smoke FAILED"
  else
    err "checks.sh changed but checks_marketplace_smoke.sh missing — cannot verify the marketplace cross-check"
  fi
fi

# 14. repo-janitor worktree-sweep smoke (#364): the three-tier classification (deterministic/owner/
#     residual), the live-owner tier-1 VETO, fail-closed UNKNOWN facts never reaching tier 1, the silent
#     (in-progress / just-merged-and-fresh) cases, --fetch freshness vs the cached-ref default, --reap-tier1
#     deleting ONLY tier-1 entries (with --dry-run touching nothing), the --json shape, and CLI argument
#     validation — behavior the JSON/syntax/py-compile checks can't cover. Runs when the sweep or its smoke
#     changed.
if printf '%s\n' "${PATHS[@]}" | grep -Eq '^plugins/repo-janitor/skills/repo-janitor/scripts/(worktree_sweep\.py|worktree_sweep_smoke\.sh)$'; then
  RJ_SMOKE="$ROOT/plugins/repo-janitor/skills/repo-janitor/scripts/worktree_sweep_smoke.sh"
  if [ -f "$RJ_SMOKE" ]; then
    echo "[checks] repo-janitor worktree-sweep smoke" >&2
    bash "$RJ_SMOKE" >&2 && ok "worktree_sweep smoke" || err "worktree_sweep smoke FAILED"
  else
    err "worktree_sweep.py changed but worktree_sweep_smoke.sh missing — cannot verify the sweep classifier"
  fi
fi

# 15. canonical-login smoke (#381): canonical_login() maps exactly the two GitHub-observed App-identity
#     representations to the same form WITHOUT collapsing a bare (untrusted) slug into matching the App,
#     plus a static check that implement-on-ready.yml sources the helper AFTER checkout (helper
#     reachability from the real workflow, not just unit correctness). Runs when the helper, its smoke, or
#     either SWE-pipeline workflow changed.
if printf '%s\n' "${PATHS[@]}" | grep -Eq '^(\.github/scripts/canonical(-login|_login_smoke)\.sh|\.github/workflows/(implement-on-ready|review-on-pr)\.yml)$'; then
  CL_SMOKE="$ROOT/.github/scripts/canonical_login_smoke.sh"
  if [ -f "$CL_SMOKE" ]; then
    echo "[checks] canonical-login smoke" >&2
    bash "$CL_SMOKE" >&2 && ok "canonical_login smoke" || err "canonical_login smoke FAILED"
  else
    err "canonical-login.sh or a SWE-pipeline workflow changed but canonical_login_smoke.sh missing — cannot verify login canonicalization"
  fi
fi

# 16. local-job-queue smoke (#402): argument validation, comment/blank-line skipping, and real CAP
#     enforcement (never more than <cap> launched jobs running at once, using REAL background processes —
#     no stub) for the reusable concurrency-capped LOCAL job queue that fixes the "concurrency is free"
#     footgun (remote/provider-side billing concurrency vs a LOCAL controller-box RAM ceiling). Runs when
#     the helper or its smoke changed.
if printf '%s\n' "${PATHS[@]}" | grep -Eq '^plugins/experiment-lifecycle/skills/run-experiment/scripts/local_job_queue(_smoke)?\.sh$'; then
  LJQ_SMOKE="$ROOT/plugins/experiment-lifecycle/skills/run-experiment/scripts/local_job_queue_smoke.sh"
  if [ -f "$LJQ_SMOKE" ]; then
    echo "[checks] local-job-queue smoke" >&2
    bash "$LJQ_SMOKE" >&2 && ok "local_job_queue smoke" || err "local_job_queue smoke FAILED"
  else
    err "local_job_queue.sh changed but local_job_queue_smoke.sh missing — cannot verify the queue helper"
  fi
fi

[ "$fail" = 0 ] && { echo "[checks] PASS" >&2; exit 0; } || { echo "[checks] FAIL" >&2; exit 1; }
