#!/usr/bin/env bash
# log_experiment_design_stage_snapshot_smoke.sh — behavior smoke for gate_design_stage's #469 addition:
# log-experiment.sh's design-stage gate now also verifies the START.md instance-profile snapshot
# (aar_profile_snapshot.sh check) — the deterministic enforcement owner that closes the silent
# viewer-publish miss (three closed experiments never got a dashboard entry because nothing ever wrote or
# checked this block). Drives the REAL script via `--dry-run` against throwaway git fixtures, the same
# pattern log_experiment_secret_scan_smoke.sh uses. No engineer identity or network needed.
#
# make_design_repo's DESIGN.md carries a locked Presentation header (#470/#471) since gate_design_stage
# checks that BEFORE the #469 snapshot check this smoke targets — without it every case here would BLOCK on
# the lock check instead of reaching the snapshot behavior under test.
#
# Cases 6-8 additionally cover gate_design_stage's #512 addition (a design-stage PR shipped a CHECKLIST.md
# copied verbatim, ticks included, from a closed sibling's completed close checklist): a staged CHECKLIST.md
# with any ticked gate LIST line (☑/☒) BLOCKs, while the unstarted template itself — whose own instruction
# header uses ☑/☒ in PROSE examples and whose gate lines carry non-empty `ev:` hints — must still PASS.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/log-experiment.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: log-experiment.sh not found next to smoke" >&2; exit 1; }

FAILS=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILS=$((FAILS+1)); }

T=$(mktemp -d "${TMPDIR:-/tmp}/dssmoke.XXXXXX") || { echo "FAIL: mktemp failed" >&2; exit 1; }
cleanup(){ rm -rf "$T"; }
trap cleanup EXIT

mkdir -p "$T/xdg/experiment-lifecycle"
cat > "$T/xdg/experiment-lifecycle/aar-profile.toml" <<'EOF'
schema_version = 1
[github]
research_repo = "owner/example-repo"
base_branch = "main"
branch_prefix = "run/"
private = true
[recipes.viewer]
kind = "repo"
repo = "owner/viewer-repo"
path = "recipes/viewer.md"
git_ref = "abc1234"
EOF

fresh_start_md() {
  cat > "$1" <<'EOF'
# START.md — smoke-exp

## Your one job
do a thing

## Constraints
touch only your work dir
EOF
}

# make_design_repo <dir>: a fresh git repo with a design-stage registry entry (DESIGN.md + DESIGN_AUDIT.md
# + START.md), so log-experiment.sh classifies it design-stage and gate_design_stage runs.
make_design_repo() {
  local root="$1"
  git init -q -b main "$root"
  git -C "$root" config user.email smoke@test; git -C "$root" config user.name smoke
  mkdir -p "$root/reg/exp1"
  printf '# DESIGN\npurpose: smoke\n\n## Presentation (locked with the researcher 2026-07-14)\nDetails.\n' > "$root/reg/exp1/DESIGN.md"
  git -C "$root" add -A; git -C "$root" commit -qm base
  git -C "$root" update-ref refs/remotes/origin/main main
  git -C "$root" checkout -q -b change/x
  printf '# DESIGN_AUDIT\nno findings\n' > "$root/reg/exp1/DESIGN_AUDIT.md"
}

# run_dry <dir>: run the gate under the FIXTURE profile (not empty — this gate needs a live profile to
# check against) + BASE_BRANCH=main. LAST_ERR captures combined output; return code is the gate's verdict.
LAST_ERR=""
run_dry() {
  local dir="$1"
  local out; out="$(XDG_CONFIG_HOME="$T/xdg" AAR_PROFILE="" LOG_EXPERIMENT_BASE_BRANCH=main \
      bash "$SCRIPT" "$dir" --dry-run 2>&1)"; local rc=$?
  LAST_ERR="$out"; return $rc
}

echo "[smoke] case 1: DESIGN.md + DESIGN_AUDIT.md + a valid, freshly-snapshotted START.md -> PASS"
T1="$T/repo1"; make_design_repo "$T1"
fresh_start_md "$T1/reg/exp1/START.md"
XDG_CONFIG_HOME="$T/xdg" AAR_PROFILE="" bash "$SELF_DIR/aar_profile_snapshot.sh" snapshot "$T1/reg/exp1/START.md" >/dev/null
git -C "$T1" add -A
if run_dry "$T1/reg/exp1"; then pass "design-stage with a valid snapshot passes the gate"; else fail "valid snapshot was BLOCKED (regression): $LAST_ERR"; fi

echo "[smoke] case 2: design-stage dir missing START.md entirely -> BLOCK with the #469 message"
T2="$T/repo2"; make_design_repo "$T2"
git -C "$T2" add -A
if run_dry "$T2/reg/exp1"; then fail "missing START.md was NOT blocked"; else
  case "$LAST_ERR" in *"missing START.md"*"instance-profile snapshot"*) pass "missing START.md blocked with the expected message";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac
fi

echo "[smoke] case 3: START.md present but with NO instance-profile snapshot block -> BLOCK"
T3="$T/repo3"; make_design_repo "$T3"
fresh_start_md "$T3/reg/exp1/START.md"   # never snapshotted
git -C "$T3" add -A
if run_dry "$T3/reg/exp1"; then fail "START.md with no snapshot block was NOT blocked"; else
  case "$LAST_ERR" in *"no instance-profile snapshot block found"*) pass "missing snapshot block blocked";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac
fi

echo "[smoke] case 4: START.md snapshot is STALE (profile changed after snapshotting) -> BLOCK"
T4="$T/repo4"; make_design_repo "$T4"
fresh_start_md "$T4/reg/exp1/START.md"
XDG_CONFIG_HOME="$T/xdg" AAR_PROFILE="" bash "$SELF_DIR/aar_profile_snapshot.sh" snapshot "$T4/reg/exp1/START.md" >/dev/null
git -C "$T4" add -A
sed -i.bak 's/abc1234/9876543/' "$T/xdg/experiment-lifecycle/aar-profile.toml"   # instance profile drifts
if run_dry "$T4/reg/exp1"; then fail "a stale snapshot was NOT blocked"; else
  case "$LAST_ERR" in *"is stale"*) pass "stale snapshot blocked";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac
fi
mv "$T/xdg/experiment-lifecycle/aar-profile.toml.bak" "$T/xdg/experiment-lifecycle/aar-profile.toml"   # restore for later cases

echo "[smoke] case 5: viewer-less (manifest-only) profile is a LEGITIMATE snapshot and still passes"
mkdir -p "$T/xdg-viewerless/experiment-lifecycle"
cat > "$T/xdg-viewerless/experiment-lifecycle/aar-profile.toml" <<'EOF'
schema_version = 1
[github]
research_repo = "owner/example-repo"
base_branch = "main"
branch_prefix = "run/"
private = true
EOF
T5="$T/repo5"; make_design_repo "$T5"
fresh_start_md "$T5/reg/exp1/START.md"
XDG_CONFIG_HOME="$T/xdg-viewerless" AAR_PROFILE="" bash "$SELF_DIR/aar_profile_snapshot.sh" snapshot "$T5/reg/exp1/START.md" >/dev/null
git -C "$T5" add -A
out5="$(XDG_CONFIG_HOME="$T/xdg-viewerless" AAR_PROFILE="" LOG_EXPERIMENT_BASE_BRANCH=main bash "$SCRIPT" "$T5/reg/exp1" --dry-run 2>&1)"; rc5=$?
if [ "$rc5" -eq 0 ]; then pass "a legitimate viewer-less (manifest-only) snapshot still passes the gate"; else
  fail "manifest-only snapshot was blocked (should be a legitimate instance choice): $out5"; fi

echo "[smoke] case 6: staged CHECKLIST.md has a ticked [BLOCK] gate (☑) -> BLOCK (#512)"
T6="$T/repo6"; make_design_repo "$T6"
fresh_start_md "$T6/reg/exp1/START.md"
XDG_CONFIG_HOME="$T/xdg" AAR_PROFILE="" bash "$SELF_DIR/aar_profile_snapshot.sh" snapshot "$T6/reg/exp1/START.md" >/dev/null
printf '# CHECKLIST\n## UNIVERSAL\n- \xe2\x98\x91 [BLOCK] Experiment CLAIMED. ev: git log abc123\n' > "$T6/reg/exp1/CHECKLIST.md"
git -C "$T6" add -A
if run_dry "$T6/reg/exp1"; then fail "a pre-ticked CHECKLIST.md was NOT blocked"; else
  case "$LAST_ERR" in *"ticked gate marker"*) pass "ticked ☑ gate blocked";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac
fi

echo "[smoke] case 7: staged CHECKLIST.md has a ticked [BLOCK] gate (☒ FAIL) -> BLOCK (#512)"
T7="$T/repo7"; make_design_repo "$T7"
fresh_start_md "$T7/reg/exp1/START.md"
XDG_CONFIG_HOME="$T/xdg" AAR_PROFILE="" bash "$SELF_DIR/aar_profile_snapshot.sh" snapshot "$T7/reg/exp1/START.md" >/dev/null
printf '# CHECKLIST\n## UNIVERSAL\n- \xe2\x98\x92 [BLOCK] Anchor-gate. ev: FAILED, see GAPS\n' > "$T7/reg/exp1/CHECKLIST.md"
git -C "$T7" add -A
if run_dry "$T7/reg/exp1"; then fail "a pre-ticked (☒ FAIL) CHECKLIST.md was NOT blocked"; else
  case "$LAST_ERR" in *"ticked gate marker"*) pass "ticked ☒ gate blocked";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac
fi

echo "[smoke] case 8: staged CHECKLIST.md is UNSTARTED (☐ gates with non-empty ev: hints + the template's own"
echo "         ☑/☒ prose examples in its instruction header) -> PASS (no false-positive, #512)"
T8="$T/repo8"; make_design_repo "$T8"
fresh_start_md "$T8/reg/exp1/START.md"
XDG_CONFIG_HOME="$T/xdg" AAR_PROFILE="" bash "$SELF_DIR/aar_profile_snapshot.sh" snapshot "$T8/reg/exp1/START.md" >/dev/null
cp "$SELF_DIR/../../design-experiment/templates/CHECKLIST_TEMPLATE.md" "$T8/reg/exp1/CHECKLIST.md"
git -C "$T8" add -A
if run_dry "$T8/reg/exp1"; then pass "an unstarted checklist (copied straight from the template) passes the gate"; else
  fail "the unstarted CHECKLIST template was BLOCKED (false positive): $LAST_ERR"; fi

if [ "$FAILS" -eq 0 ]; then echo "[smoke] log-experiment design-stage snapshot gate: ALL PASS"; exit 0; else
  echo "[smoke] log-experiment design-stage snapshot gate: $FAILS FAILURE(S)" >&2; exit 1; fi
