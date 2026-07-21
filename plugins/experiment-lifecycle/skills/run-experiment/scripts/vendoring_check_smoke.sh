#!/usr/bin/env bash
# Smoke for vendoring_check.sh — the close-time static sys.path-resolution check (#499). Behavior the
# deterministic JSON/syntax checks can't catch: no-scripts-dir N.A., a clean in-tree reference, the exact
# incident pattern (a relative sys.path.insert/append reaching a SIBLING dir), a __file__-relative reference
# that stays inside the tree, an absolute-path reference outside the tree, an unresolvable dynamic argument
# (non-fatal), a syntax-broken script, and argument validation. Fully offline (no network, no real experiment).
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
V="$HERE/vendoring_check.sh"
[ -f "$V" ] || { echo "FAIL: missing $V"; exit 1; }

fails=0
ok(){ echo "ok   $1"; }
no(){ echo "FAIL $1"; fails=1; }

mktemp_d() { local d; d="$(mktemp -d)"; [ -n "$d" ] && [ -d "$d" ] || { echo "FAIL: mktemp -d failed"; exit 1; }; printf '%s\n' "$d"; }

# --- 1. argument validation --------------------------------------------------------------------
if bash "$V" >/dev/null 2>&1; then no missing-arg-rejected; else ok missing-arg-rejected; fi
if bash "$V" /no/such/dir-xyz >/dev/null 2>&1; then no missing-dir-rejected; else ok missing-dir-rejected; fi

# --- 2. no scripts/ dir at all -> OK, N.A. -----------------------------------------------------
T=$(mktemp_d)
OUT=$(bash "$V" "$T"); RC=$?
[ "$RC" = 0 ] && echo "$OUT" | grep -q '^OK:.*N\.A\.' && ok no-scripts-dir-is-na || no "no-scripts-dir-is-na (rc=$RC out=$OUT)"
rm -rf "$T"

# --- 3. scripts/ dir with a clean script (no sys.path calls) -> OK -----------------------------
T=$(mktemp_d); mkdir -p "$T/scripts"
cat > "$T/scripts/clean.py" <<'PY'
print("hello")
PY
OUT=$(bash "$V" "$T"); RC=$?
[ "$RC" = 0 ] && echo "$OUT" | grep -q '^OK:' && ok clean-script-ok || no "clean-script-ok (rc=$RC out=$OUT)"
rm -rf "$T"

# --- 4. the exact incident pattern: sys.path.insert to a SIBLING dir by relative path -> VIOLATION, exit 1 --
T=$(mktemp_d); mkdir -p "$T/exp/scripts" "$T/sibling/scripts"
cat > "$T/exp/scripts/train.py" <<'PY'
import sys
sys.path.insert(0, "../../sibling/scripts")
from render_mask import render
PY
OUT=$(bash "$V" "$T/exp"); RC=$?
[ "$RC" = 1 ] && echo "$OUT" | grep -q 'VIOLATION' && ok sibling-relative-path-violation || no "sibling-relative-path-violation (rc=$RC out=$OUT)"
rm -rf "$T"

# --- 5. sys.path.append to an ABSOLUTE path outside the exp dir -> VIOLATION --------------------
T=$(mktemp_d); mkdir -p "$T/exp/scripts" "$T/elsewhere"
cat > "$T/exp/scripts/gen.py" <<PY
import sys
sys.path.append("$T/elsewhere")
PY
OUT=$(bash "$V" "$T/exp"); RC=$?
[ "$RC" = 1 ] && echo "$OUT" | grep -q 'VIOLATION' && ok absolute-path-outside-violation || no "absolute-path-outside-violation (rc=$RC out=$OUT)"
rm -rf "$T"

# --- 6. sys.path.insert to a SUBDIR of the script's own dir (via __file__) -> OK, stays in-tree ---
T=$(mktemp_d); mkdir -p "$T/exp/scripts/lib"
cat > "$T/exp/scripts/main.py" <<'PY'
import os
import sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "lib"))
PY
touch "$T/exp/scripts/lib/__init__.py"
OUT=$(bash "$V" "$T/exp"); RC=$?
[ "$RC" = 0 ] && echo "$OUT" | grep -q '^OK:' && ok file-relative-subdir-in-tree-ok || no "file-relative-subdir-in-tree-ok (rc=$RC out=$OUT)"
rm -rf "$T"

# --- 7. sys.path.insert to a relative "." (the script's own dir) -> OK -------------------------
T=$(mktemp_d); mkdir -p "$T/exp/scripts"
cat > "$T/exp/scripts/main2.py" <<'PY'
import sys
sys.path.insert(0, ".")
PY
OUT=$(bash "$V" "$T/exp"); RC=$?
[ "$RC" = 0 ] && echo "$OUT" | grep -q '^OK:' && ok relative-dot-in-tree-ok || no "relative-dot-in-tree-ok (rc=$RC out=$OUT)"
rm -rf "$T"

# --- 8. an UNRESOLVABLE dynamic sys.path argument -> UNRESOLVED, but non-fatal (exit 0) ----------
T=$(mktemp_d); mkdir -p "$T/exp/scripts"
cat > "$T/exp/scripts/dynamic.py" <<'PY'
import sys
some_var = compute_path()
sys.path.insert(0, some_var)
PY
OUT=$(bash "$V" "$T/exp"); RC=$?
[ "$RC" = 0 ] && echo "$OUT" | grep -q 'UNRESOLVED' && ok dynamic-argument-unresolved-nonfatal || no "dynamic-argument-unresolved-nonfatal (rc=$RC out=$OUT)"
rm -rf "$T"

# --- 9. one clean file + one violating file -> overall exit 1, violation named -------------------
T=$(mktemp_d); mkdir -p "$T/exp/scripts" "$T/other"
cat > "$T/exp/scripts/clean.py" <<'PY'
print("fine")
PY
cat > "$T/exp/scripts/bad.py" <<PY
import sys
sys.path.append("$T/other")
PY
OUT=$(bash "$V" "$T/exp"); RC=$?
[ "$RC" = 1 ] && echo "$OUT" | grep -q 'bad.py' && ok mixed-files-violation-named || no "mixed-files-violation-named (rc=$RC out=$OUT)"
rm -rf "$T"

# --- 10b. a BARE relative literal that stays in-tree when resolved from script_dir, but escapes when
# resolved from the experiment root (the process's CWD when invoked as `python scripts/main.py` from the
# experiment root, the review's exact #499 P0 repro) -> VIOLATION (fail closed on the CWD-anchored read,
# not just the script_dir-anchored one) ------------------------------------------------------------------
T=$(mktemp_d); mkdir -p "$T/exp/scripts"
cat > "$T/exp/scripts/main.py" <<'PY'
import sys
sys.path.insert(0, "..")
PY
OUT=$(bash "$V" "$T/exp"); RC=$?
[ "$RC" = 1 ] && echo "$OUT" | grep -q 'VIOLATION' && ok cwd-anchored-relative-escape-violation || no "cwd-anchored-relative-escape-violation (rc=$RC out=$OUT)"
rm -rf "$T"

# --- 10. a script with a syntax error -> reported as a violation (fail closed, not silently skipped) ---
T=$(mktemp_d); mkdir -p "$T/exp/scripts"
cat > "$T/exp/scripts/broken.py" <<'PY'
def f(:
    pass
PY
OUT=$(bash "$V" "$T/exp"); RC=$?
[ "$RC" = 1 ] && echo "$OUT" | grep -q 'could not parse' && ok syntax-error-fails-closed || no "syntax-error-fails-closed (rc=$RC out=$OUT)"
rm -rf "$T"

[ "$fails" = 0 ] && { echo "vendoring_check smoke PASS"; exit 0; } || { echo "vendoring_check smoke FAIL"; exit 1; }
