#!/bin/bash
# vendoring_check.sh — close-time static check that every committed script's local-module resolution stays
# WITHIN this experiment's own committed tree (#499).
#
# Incident: csp1-gemma4-mistral4-v3-transfer-1's CHECKLIST.md claimed (in prose) that train_gemma4_lora.py was
# "the unmodified parent script... byte-identical copy... not forked", and that render_mask.py was vendored --
# but neither file was ever actually copied into this experiment's own scripts/ dir. Both resolved at execution
# time only because a sys.path.insert()/append() pointed at a SIBLING experiment's directory that happened to
# be reachable in the same shared local worktree -- an environment-specific accident a fresh clone of just this
# experiment's registry dir could not rely on. The executor's own self-audit never caught it (the scripts DID
# run correctly), and it surfaced only via an independent cross-family close audit (HIGH severity).
#
# This closes the mechanical gap: for every committed *.py under <exp-dir>/scripts/ (recursively), statically
# scan for sys.path.insert()/sys.path.append() calls and flag any whose target -- resolved relative to the
# script's OWN directory, or via a simple __file__-relative expression -- lands OUTSIDE <exp-dir>. A
# "byte-identical vendored copy" claim in CHECKLIST/RESULTS prose is not evidence; this is.
#
# USAGE: vendoring_check.sh <exp-dir>
# Exits 0 (prints OK) if <exp-dir> has no scripts/ dir at all (N.A. -- nothing to scan) or every sys.path
# reference found resolves inside <exp-dir>. Exits 1 (prints one VIOLATION line per hit) if any resolves
# OUTSIDE <exp-dir>. A sys.path argument this script cannot statically resolve (any expression beyond a string
# literal or a simple __file__-relative os.path.dirname/os.path.join chain) is printed as UNRESOLVED and is
# non-fatal on its own -- a static scan can't assert it either way, so it's surfaced for human review rather
# than silently passed or falsely blocked.
set -euo pipefail

die(){ echo "vendoring_check: $*" >&2; exit 1; }

[ $# -eq 1 ] || die "usage: vendoring_check.sh <exp-dir>"
EXP_DIR_ARG="$1"
[ -d "$EXP_DIR_ARG" ] || die "not a directory: $EXP_DIR_ARG"
EXP_DIR="$(cd "$EXP_DIR_ARG" && pwd)"
SCRIPTS_DIR="$EXP_DIR/scripts"

if [ ! -d "$SCRIPTS_DIR" ]; then
  echo "OK: no scripts/ dir under $EXP_DIR -- nothing to scan (N.A.)"
  exit 0
fi

set +e
EXP_DIR="$EXP_DIR" python3 - "$SCRIPTS_DIR" <<'PY'
import ast
import os
import sys

exp_dir = os.path.realpath(os.environ["EXP_DIR"])
scripts_dir = sys.argv[1]


# resolve_expr returns (value, exact) where exact=True means the value is anchored to the script's OWN
# directory regardless of the process's runtime CWD (a __file__-derived expression), and exact=False means
# it's a bare string literal -- Python resolves that against the process's CWD at invocation time, which a
# static scan cannot know, so callers must check it against every plausible invocation CWD (#499 P0 review:
# `sys.path.insert(0, "..")` invoked as `python scripts/main.py` from the experiment root resolves against
# the experiment root, NOT the script's own directory -- anchoring a bare literal to script_dir alone missed
# exactly this case).


def resolve_dirname_file(node, script_dir):
    # os.path.dirname(__file__) -> the script's own directory (exact, CWD-independent)
    if (isinstance(node, ast.Call)
            and isinstance(node.func, ast.Attribute)
            and node.func.attr == "dirname"
            and len(node.args) == 1
            and isinstance(node.args[0], ast.Name)
            and node.args[0].id == "__file__"):
        return script_dir
    return None


def resolve_join(node, script_dir):
    # os.path.join(<resolvable>, "literal", "literal", ...)
    if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == "join"):
        return None
    if not node.args:
        return None
    base, exact = resolve_expr(node.args[0], script_dir)
    if base is None:
        return None
    parts = [base]
    for a in node.args[1:]:
        if isinstance(a, ast.Constant) and isinstance(a.value, str):
            parts.append(a.value)
        else:
            return None
    return os.path.join(*parts), exact


def resolve_expr(node, script_dir):
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value, False
    if isinstance(node, ast.Name) and node.id == "__file__":
        return script_dir, True
    r = resolve_dirname_file(node, script_dir)
    if r is not None:
        return r, True
    r = resolve_join(node, script_dir)
    if r is not None:
        return r
    return None, False


violations = []
unresolved = []
scanned = 0

for root, _dirs, files in os.walk(scripts_dir):
    for fn in files:
        if not fn.endswith(".py"):
            continue
        path = os.path.join(root, fn)
        scanned += 1
        script_dir = os.path.dirname(os.path.realpath(path))
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                src = f.read()
            tree = ast.parse(src, filename=path)
        except SyntaxError as e:
            violations.append((path, getattr(e, "lineno", 0), f"could not parse: {e}"))
            continue
        for node in ast.walk(tree):
            if not isinstance(node, ast.Call):
                continue
            func = node.func
            if not (isinstance(func, ast.Attribute) and func.attr in ("insert", "append")):
                continue
            # sys.path.insert(...)/sys.path.append(...): the attribute's own value must be `sys.path`
            # (covers `import sys; sys.path.insert(...)`); anything else with a same-named method is ignored.
            val = func.value
            if not (isinstance(val, ast.Attribute) and val.attr == "path"
                    and isinstance(val.value, ast.Name) and val.value.id == "sys"):
                continue
            if not node.args:
                continue
            # insert(idx, target) vs append(target) -- the target is always the LAST positional arg.
            target_node = node.args[-1]
            target, exact = resolve_expr(target_node, script_dir)
            if target is None:
                unresolved.append((path, node.lineno, ast.dump(target_node)))
                continue
            if os.path.isabs(target):
                anchors = [None]  # absolute path, no anchor needed
            elif exact:
                anchors = [script_dir]
            else:
                # A bare relative string literal: Python resolves it against the process's CWD at
                # invocation time, which this static scan cannot know. Check every plausible invocation
                # CWD -- the script's own directory, and the experiment root (the common CWD when a
                # script is invoked as `python scripts/main.py` from the experiment root) -- and flag a
                # violation if EITHER anchor escapes, fail-closed rather than trusting one guessed anchor.
                anchors = sorted({script_dir, exp_dir})
            for anchor in anchors:
                resolved = target if anchor is None else os.path.normpath(os.path.join(anchor, target))
                resolved = os.path.realpath(resolved)
                if not (resolved == exp_dir or resolved.startswith(exp_dir + os.sep)):
                    anchor_note = "" if anchor is None else f" (resolved from CWD={anchor})"
                    violations.append((path, node.lineno, f"{target!r} -> {resolved}{anchor_note} (outside {exp_dir})"))
                    break

for path, lineno, msg in unresolved:
    print(f"UNRESOLVED: {path}:{lineno}: sys.path target could not be statically resolved ({msg}) -- review by hand")

if violations:
    for path, lineno, msg in violations:
        print(f"VIOLATION: {path}:{lineno}: {msg}")
    print(f"vendoring_check: {len(violations)} violation(s) across {scanned} scanned file(s)")
    sys.exit(1)

print(f"OK: {scanned} script(s) scanned under {scripts_dir}, no external sys.path resolutions")
sys.exit(0)
PY
code=$?
set -e
exit "$code"
