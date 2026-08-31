#!/bin/bash
# launch_record.sh — the two MECHANICAL operations the launch side performs on a merged design-stage
# record, so neither is done by hand or by an ad-hoc `sed` (automated-researcher#813).
#
# WHY A SCRIPT (the incident, RGBH1 2026-08-31): the designing session and the launching session were
# different sessions (and different model families). Everything at that seam was hand-done, and two of the
# three failures were failures of hand-doing it:
#   * the launcher hand-edited the designing family's DESIGN.md/START.md to move designer-of-record —
#     an unreviewed edit to a MERGED record, with no check that it landed on the one line that matters;
#   * the Presentation lock — a DESIGN artifact recording the researcher's explicit in-chat word on what
#     gets plotted — was flipped from the launch side on the strength of "launch it", because the design
#     had been parked at "say *lock it*" when the launch was handed over.
# So: `preflight` refuses to launch anything that is not a merged, Presentation-LOCKED record (and never
# writes that lock itself), and `bind-designer` does the one designer-of-record edit deterministically,
# idempotently, and fails closed when the line it must rewrite is missing or ambiguous.
#
# VERBS
#   preflight <record-dir> --base-ref <ref>
#       Fail closed unless DESIGN.md + START.md + CHECKLIST.md all exist AT <ref> (i.e. the design-stage PR
#       merged), the working copy of each matches <ref> (you are not launching something the cross-family
#       design gate never saw — exception: START.md's designer-address lines, which are this script's own
#       `bind-designer` output, so the check stays re-runnable after a bind), and DESIGN.md AT <ref> carries
#       the researcher's Presentation lock header. Read-only: no writes, no network, no git mutation.
#   bind-designer <START.md path> <session-name>
#       Write designer-of-record = the LAUNCHING session's own harness session name into the record's seed
#       line (`- **Designer-of-record:** …`), plus any remaining `<designer_session>` placeholder. Exactly
#       one seed line must match. Atomic (tmp + mv, mode preserved) and idempotent (a re-run with the same
#       name is a no-op). The reserved literal `record-only` is accepted verbatim — it is the honest value
#       for a substrate with no addressable session (automated-researcher#796).
#
# NOT THIS SCRIPT'S JOB: the record is only the SEED. The address OF RECORD is the run-supervision record's
# `designer_session` field, which the executor binds at `start` and the launcher verifies with
# `run_supervision_record.sh verify-bootstrap --designer-session <name>` (that helper lives in
# run-experiment, which owns the record). A later move of the role is published by `checkpoint
# --designer-session <new name>` alone — never by reissuing the brief.
set -euo pipefail

die(){ echo "BLOCKED: $*" >&2; exit 1; }
note(){ echo "  ok: $*" >&2; }

usage(){
  cat >&2 <<'EOF'
usage:
  launch_record.sh preflight <record-dir> --base-ref <ref>
  launch_record.sh bind-designer <START.md path> <session-name>
EOF
  exit 2
}

# The Presentation-lock header, byte-for-byte the same convention log-experiment's design-stage gate
# enforces before the design PR may merge (one canonical semantic; this side only READS it).
LOCK_RE='^#{1,6}[[:space:]]*Presentation[[:space:]]*\(locked with the researcher [0-9]{4}-[0-9]{2}-[0-9]{2}\)'

# The lines of START.md the LAUNCH side owns (the designer-of-record address and the executor's bind
# argument for it) — dropped before preflight's working-copy-vs-merged-ref comparison. Nothing else in the
# brief is the launcher's to change. `|| true`: an all-filtered (or empty) input is not an error here.
LAUNCHER_OWNED_RE='Designer-of-record:|--designer-session'
launcher_owned_filter(){ grep -vE "$LAUNCHER_OWNED_RE" || true; }

cmd_preflight(){
  local dir="" ref=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --base-ref) [ $# -ge 2 ] || die "--base-ref needs a value"; ref=$2; shift 2 ;;
      -*) die "unknown option: $1" ;;
      *) [ -z "$dir" ] || die "unexpected extra argument: $1"; dir=$1; shift ;;
    esac
  done
  [ -n "$dir" ] || usage
  [ -n "$ref" ] || die "--base-ref is required — pass the ref your instance's records merge into (the profile's [github].base_branch, e.g. origin/main). This check exists to prove the design-stage PR MERGED, so it can never default to your own branch."
  [ -d "$dir" ] || die "no such record dir: $dir"

  local abs prefix root exp
  abs=$(cd "$dir" && pwd -P)
  root=$(git -C "$abs" rev-parse --show-toplevel 2>/dev/null) || die "not inside a git checkout: $abs"
  prefix=$(git -C "$abs" rev-parse --show-prefix)   # repo-relative, trailing slash (empty at the root)
  [ -n "$prefix" ] || die "record dir is the repo root ($abs) — pass the experiment's own registry dir"
  exp=$(basename "$abs")

  git -C "$root" rev-parse --verify --quiet "$ref^{commit}" >/dev/null \
    || die "base ref not found: $ref (fetch it first — a missing ref is not the same as an unmerged record)"

  local f rel
  for f in DESIGN.md START.md CHECKLIST.md; do
    rel="$prefix$f"
    git -C "$root" cat-file -e "$ref:$rel" 2>/dev/null \
      || die "$rel is not present at $ref — the design-stage PR has not merged, so there is nothing pre-registered to launch (finish design-experiment's design-stage logging first)"
    [ -f "$root/$rel" ] || die "$rel exists at $ref but not in this working tree — check the record out (a sparse checkout needs this record in its cone) before launching"
    if [ "$f" = START.md ]; then
      # The designer-address lines are the LAUNCHER's to write (`bind-designer`, below), so they are the one
      # legitimate difference from the merged ref — otherwise re-running this check after a bind (a relaunch,
      # a second read) would flag the launcher's own edit as unreviewed drift. Everything else in the brief
      # still has to match.
      cmp -s <(git -C "$root" show "$ref:$rel" | launcher_owned_filter) <(launcher_owned_filter < "$root/$rel") \
        || die "$rel differs from $ref outside the designer-of-record lines — you would be launching a brief the cross-family design gate never saw; commit + merge the change through log-experiment, or drop it"
    else
      git -C "$root" show "$ref:$rel" | cmp -s - "$root/$rel" \
        || die "$rel differs from $ref — you would be launching a brief the cross-family design gate never saw; commit + merge the change through log-experiment, or drop it"
    fi
    note "$f matches $ref"
  done

  local lock
  lock=$(git -C "$root" show "$ref:${prefix}DESIGN.md" | grep -m1 -E "$LOCK_RE" || true)
  [ -n "$lock" ] || die "DESIGN.md at $ref has no locked Presentation header — expected '## Presentation (locked with the researcher <ISO date>)'. The lock is a DESIGN artifact recording the researcher's explicit word on what gets plotted: NEVER add it from the launch side. Send this back to design-experiment."
  note "presentation locked: $lock"

  echo "PREFLIGHT OK $exp @ $ref"
}

cmd_bind_designer(){
  [ $# -eq 2 ] || usage
  local start=$1 name=$2

  [ -f "$start" ] || die "no such file: $start"
  case "$name" in
    "") die "empty session name" ;;
    *[[:space:]]*) die "session name must not contain whitespace: '$name' — this is the harness's own session NAME (Claude Code: what ListAgents shows), not a description" ;;
    '<'*) die "'$name' is still a placeholder — resolve your OWN harness session name by lookup (automated-researcher#796), never a guessed or example name" ;;
    *'`'*) die "session name must not contain a backtick: '$name'" ;;
  esac
  [ ${#name} -le 200 ] || die "session name is implausibly long (${#name} chars)"

  command -v python3 >/dev/null 2>&1 || die "python3 is required for the record edit (a literal, escape-free rewrite — deliberately not a sed one-liner)"

  local out
  out=$(START_MD="$start" DESIGNER_NAME="$name" python3 - <<'PY'
import os, re, sys, tempfile

path = os.environ["START_MD"]
name = os.environ["DESIGNER_NAME"]
with open(path, encoding="utf-8") as fh:
    original = fh.read()

lines = original.split("\n")
seed = [i for i, ln in enumerate(lines) if re.match(r"^\s*[-*]\s+\*\*Designer-of-record:\*\*", ln)]
if len(seed) != 1:
    sys.stderr.write(
        "expected exactly ONE '- **Designer-of-record:**' seed line in %s, found %d — this brief was not "
        "written from design-experiment's START template, or the line was already hand-edited; fix the "
        "record so there is exactly one address slot rather than guessing which one the executor reads\n"
        % (path, len(seed))
    )
    sys.exit(1)

i = seed[0]
line = lines[i]
marker = "harness session name"
replacement = "harness session name **`%s`**." % name
# whatever address the seed line carried before this bind — either the template's placeholder or a name a
# previous bind wrote. Re-running the bind with a corrected name must not leave the old one behind further
# down the brief, where the executor would read it as its `--designer-session` argument.
prev = re.search(r"harness session name\s+\*\*`([^`]*)`\*\*", line)
prev = prev.group(1) if prev else ""
if marker in line:
    # keep the human-readable WHO prefix the designer wrote; replace only the address tail
    lines[i] = line[: line.index(marker)] + replacement
else:
    indent = re.match(r"^\s*", line).group(0)
    lines[i] = "%s- **Designer-of-record:** the launching session, %s" % (indent, replacement)

updated = "\n".join(lines).replace("<designer_session>", name)
if prev and prev != name:
    # narrow on purpose: only the argument slot, never a free-text occurrence of the old name
    updated = re.sub(
        r"(--designer-session[ \t]+)" + re.escape(prev) + r"(?![\w.-])",
        lambda m: m.group(1) + name,
        updated,
    )
if updated == original:
    print("UNCHANGED " + lines[i].strip())
    sys.exit(0)

d = os.path.dirname(os.path.abspath(path))
fd, tmp = tempfile.mkstemp(dir=d, prefix=".launch_record.")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(updated)
    os.chmod(tmp, os.stat(path).st_mode & 0o7777)
    os.replace(tmp, path)          # atomic within the dir
except BaseException:
    if os.path.exists(tmp):
        os.unlink(tmp)
    raise
print("BOUND " + lines[i].strip())
PY
  ) || die "designer-of-record bind failed on $start (see above) — nothing was written"

  case "$out" in
    UNCHANGED*) note "designer-of-record already bound: ${out#UNCHANGED }" ;;
    *)          note "designer-of-record bound: ${out#BOUND }" ;;
  esac
  echo "$out"
}

[ $# -ge 1 ] || usage
verb=$1; shift
case "$verb" in
  preflight)      cmd_preflight "$@" ;;
  bind-designer)  cmd_bind_designer "$@" ;;
  -h|--help)      usage ;;
  *)              die "unknown verb: $verb (expected preflight | bind-designer)" ;;
esac
