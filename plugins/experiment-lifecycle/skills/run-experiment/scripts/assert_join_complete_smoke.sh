#!/usr/bin/env bash
# Smoke for assert_join_complete.py — the fail-closed join-completeness assertion (#731). Behavior the
# deterministic py-compile check can't catch: the incident shape itself (a judged cell that came out
# BLANK because the join missed) blocking, the per-battery tier NOT mis-firing on legitimately
# interval-free rows (the #731 near-miss, where a first hand-rolled version demanded an interval on
# every judged row), the fail-closed cases (empty table, missing flag column, unrecognized flag token),
# the legitimate all-skipped-battery pass (#728's spend tripwire), and CLI argument validation.
# Fully offline (pure CSV arithmetic; no network).
set -uo pipefail
# Never write __pycache__ into live skill source — the same drift-guard footgun audit_data.py's header
# records (an untracked run artifact dropped into the source dir trips the SessionStart drift guard).
export PYTHONDONTWRITEBYTECODE=1

HERE=$(cd "$(dirname "$0")" && pwd)
A="$HERE/assert_join_complete.py"
[ -f "$A" ] || { echo "FAIL: missing $A"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fails=0
ok(){ echo "ok   $1"; }
no(){ echo "FAIL $1"; fails=1; }

# --- 1. CLI argument validation (exit 2 = usage) --------------------------------------------------
printf 'judged,mean\ntrue,0.5\n' > "$TMP/min.csv"
python3 "$A" >/dev/null 2>&1;                            [ $? = 2 ] && ok missing-args-rejected || no missing-args-rejected
python3 "$A" "$TMP/min.csv" >/dev/null 2>&1;             [ $? = 2 ] && ok missing-flag-field-rejected || no missing-flag-field-rejected
python3 "$A" "$TMP/min.csv" --flag-field judged >/dev/null 2>&1
[ $? = 2 ] && ok no-value-field-rejected || no no-value-field-rejected
python3 "$A" "$TMP/min.csv" --flag-field judged --per-group-field interval >/dev/null 2>&1
[ $? = 2 ] && ok per-group-without-group-field-rejected || no per-group-without-group-field-rejected
python3 "$A" "$TMP/nope.csv" --flag-field judged --value-field mean >/dev/null 2>&1
[ $? = 2 ] && ok unreadable-table-rejected || no unreadable-table-rejected

# --- 2. the #731 incident shape: judged cells blank because the join missed -> BLOCKED (exit 1) ----
# Rows sourced from a working file populate; the four canonical judged cells joined on the wrong key
# and came out blank. Exactly the table that shipped a plausible-but-wrong figure.
cat > "$TMP/dose.csv" <<'CSV'
subject,arm,battery,judged,mean
manu200-d10,rejection,rejection,true,0.41
manu200-d20,rejection,rejection,true,0.38
manu200-d40-s4,dose,dose,true,
manu200-d40-s5,dose,dose,true,
manu200-d80-s4,dose,dose,true,
manu200-d80-s5,dose,dose,true,
CSV
OUT=$(python3 "$A" "$TMP/dose.csv" --flag-field judged --value-field mean 2>&1); RC=$?
[ "$RC" = 1 ] && echo "$OUT" | grep -q '^BLOCKED:' && echo "$OUT" | grep -q '4 blank' \
  && ok blank-judged-cells-blocked || no "blank-judged-cells-blocked (rc=$RC out=$OUT)"

# --- 3. the fixed table (same rows, join key repaired) -> OK (exit 0) ------------------------------
cat > "$TMP/dose_fixed.csv" <<'CSV'
subject,arm,battery,judged,mean
manu200-d10,rejection,rejection,true,0.41
manu200-d20,rejection,rejection,true,0.38
manu200-d40,dose,dose,true,0.22
manu200-d80,dose,dose,true,0.19
CSV
OUT=$(python3 "$A" "$TMP/dose_fixed.csv" --flag-field judged --value-field mean 2>&1); RC=$?
[ "$RC" = 0 ] && echo "$OUT" | grep -q '^OK:' && ok repaired-join-passes || no "repaired-join-passes (rc=$RC out=$OUT)"

# --- 4. the #731 NEAR-MISS: per-battery interval must not fire on interval-free coherence rows -----
# `bootstrap` carries intervals on every judged row; `coherence` legitimately carries none anywhere.
# A whole-table "every judged row needs an interval" rule would (wrongly) block this.
cat > "$TMP/per_battery.csv" <<'CSV'
battery,judged,mean,interval
bootstrap,true,0.51,0.04
bootstrap,true,0.47,0.03
coherence,true,0.88,
coherence,true,0.91,
CSV
OUT=$(python3 "$A" "$TMP/per_battery.csv" --flag-field judged --value-field mean \
      --group-field battery --per-group-field interval 2>&1); RC=$?
[ "$RC" = 0 ] && echo "$OUT" | grep -q '^OK:' && ok interval-free-battery-not-misfired \
  || no "interval-free-battery-not-misfired (rc=$RC out=$OUT)"

# --- 5. ...but a battery that DEMONSTRATES the field must carry it on every judged row -------------
cat > "$TMP/per_battery_hole.csv" <<'CSV'
battery,judged,mean,interval
bootstrap,true,0.51,0.04
bootstrap,true,0.47,
coherence,true,0.88,
CSV
OUT=$(python3 "$A" "$TMP/per_battery_hole.csv" --flag-field judged --value-field mean \
      --group-field battery --per-group-field interval 2>&1); RC=$?
[ "$RC" = 1 ] && echo "$OUT" | grep -q "battery='bootstrap'" && echo "$OUT" | grep -q '1 blank' \
  && ok per-group-hole-blocked || no "per-group-hole-blocked (rc=$RC out=$OUT)"

# --- 6. unjudged rows are never required to carry values ------------------------------------------
cat > "$TMP/skipped.csv" <<'CSV'
battery,judged,mean
rejection,true,0.41
collapsed_a,false,
collapsed_b,false,
CSV
OUT=$(python3 "$A" "$TMP/skipped.csv" --flag-field judged --value-field mean 2>&1); RC=$?
[ "$RC" = 0 ] && ok unjudged-rows-exempt || no "unjudged-rows-exempt (rc=$RC out=$OUT)"

# --- 7. #728's spend tripwire skipping EVERY battery is legitimate, not a violation ----------------
cat > "$TMP/all_skipped.csv" <<'CSV'
battery,judged,mean
collapsed_a,false,
collapsed_b,false,
CSV
OUT=$(python3 "$A" "$TMP/all_skipped.csv" --flag-field judged --value-field mean 2>&1); RC=$?
[ "$RC" = 0 ] && ok all-skipped-passes || no "all-skipped-passes (rc=$RC out=$OUT)"

# --- 8. fail-closed: empty table, missing flag column, unrecognized flag token ---------------------
printf 'battery,judged,mean\n' > "$TMP/empty.csv"
OUT=$(python3 "$A" "$TMP/empty.csv" --flag-field judged --value-field mean 2>&1); RC=$?
[ "$RC" = 1 ] && echo "$OUT" | grep -q 'empty' && ok empty-table-blocked || no "empty-table-blocked (rc=$RC out=$OUT)"

printf 'battery,scored,mean\nrejection,true,0.41\n' > "$TMP/noflag.csv"
OUT=$(python3 "$A" "$TMP/noflag.csv" --flag-field judged --value-field mean 2>&1); RC=$?
[ "$RC" = 1 ] && echo "$OUT" | grep -q "no 'judged' column" && ok missing-flag-column-blocked \
  || no "missing-flag-column-blocked (rc=$RC out=$OUT)"

printf 'battery,judged,mean\nrejection,maybe,0.41\n' > "$TMP/badflag.csv"
OUT=$(python3 "$A" "$TMP/badflag.csv" --flag-field judged --value-field mean 2>&1); RC=$?
[ "$RC" = 1 ] && echo "$OUT" | grep -q 'recognized true/false token' && ok bad-flag-token-blocked \
  || no "bad-flag-token-blocked (rc=$RC out=$OUT)"

# --- 9. a non-numeric (not merely blank) judged value is also a violation --------------------------
printf 'battery,judged,mean\nrejection,true,n/a\n' > "$TMP/nonnumeric.csv"
OUT=$(python3 "$A" "$TMP/nonnumeric.csv" --flag-field judged --value-field mean 2>&1); RC=$?
[ "$RC" = 1 ] && ok non-numeric-value-blocked || no "non-numeric-value-blocked (rc=$RC out=$OUT)"

# --- 10. NaN is not a number for this purpose (a blank cell that survived a float() cast) ----------
printf 'battery,judged,mean\nrejection,true,NaN\n' > "$TMP/nan.csv"
OUT=$(python3 "$A" "$TMP/nan.csv" --flag-field judged --value-field mean 2>&1); RC=$?
[ "$RC" = 1 ] && ok nan-value-blocked || no "nan-value-blocked (rc=$RC out=$OUT)"

# --- 11. the importable function is the primary interface (native types, not CSV strings) ----------
ASSERT_DIR="$HERE" python3 - <<'PY' && ok python-api-contract || no python-api-contract
import os, sys
sys.path.insert(0, os.environ["ASSERT_DIR"])
from assert_join_complete import assert_join_complete, JoinIncompleteError

rows = [
    {"battery": "bootstrap", "judged": True, "mean": 0.51, "interval": 0.04},
    {"battery": "coherence", "judged": True, "mean": 0.88, "interval": None},
]
assert_join_complete(rows, "judged", ["mean"], group_field="battery", per_group_fields=["interval"])

bad = [{"battery": "bootstrap", "judged": True, "mean": None}]
try:
    assert_join_complete(bad, "judged", ["mean"])
except JoinIncompleteError:
    pass
else:
    raise SystemExit("expected JoinIncompleteError for a judged row with mean=None")

try:
    assert_join_complete(rows, "judged", [], per_group_fields=["interval"])
except ValueError:
    pass
else:
    raise SystemExit("expected ValueError for per_group_fields without group_field")

# max_report caps the enumeration but never the reported count
many = [{"judged": "true", "mean": ""} for _ in range(25)]
try:
    assert_join_complete(many, "judged", ["mean"], max_report=3)
except JoinIncompleteError as exc:
    msg = str(exc)
    assert msg.startswith("25 blank"), msg
    assert "+22 more" in msg, msg
else:
    raise SystemExit("expected JoinIncompleteError for 25 blank judged rows")
PY

[ "$fails" = 0 ] && { echo "PASS assert_join_complete smoke"; exit 0; } || { echo "FAIL assert_join_complete smoke"; exit 1; }
