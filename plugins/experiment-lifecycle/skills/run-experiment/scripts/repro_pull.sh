#!/bin/bash
# repro_pull.sh — the ONE lifecycle for the close's FRESH-PULL REPRODUCTION directory (#447's gate): mint it
# under the run's OWN scratch at a fixed, statically-bounded path, and delete it again the moment the
# reproduction verdict is written. The fresh-pull sibling of audit_checkout.sh (automated-researcher#840,
# shipped in #842) — same disease, same cure, one directory over: a tree with an obvious end of life that
# nothing created and so nothing removed.
#
# INCIDENT (automated-researcher#843, 2026-09-06): while `depv1-negemo-qwen-chat-row4-factorial-1` was in
# its close leg the run's artifacts existed on the box THREE times as real copies (distinct inodes, not
# links). 13 unique adapter tars of 0.35 GB appeared 39 times: the run's own `target_probes/`, a second copy
# staged under `artifacts/`, and `fresh_reproduction/pull/target_probes/` pulled back down by THIS gate.
# 15 GB on disk for one close, while the canonical 4.65 GB copy already sat in the artifact store. The box
# went 82% -> 92% full in three hours from that one close, and #842's `reap_scratch.sh` only runs at the very
# END of the close — so the peak stands for the whole audit, and a close that starts with <20 GB free can
# fail mid-audit. The fresh pull's end of life is NOT reap-scratch time: it is the moment the reproduction
# verdict is written, exactly as #842 established for the audit checkout on `AUDIT.md`.
#
# The path is therefore not the caller's choice: it is "<EXPERIMENT_SCRATCH_ROOT>/<run-id>/fresh_reproduction"
# — one fixed shape derived from the seam reap_scratch.sh already binds its own delete to, so the close reaps
# it directly and a crashed close leaves it INSIDE the scratch dir that reap_scratch.sh archives and removes
# anyway (a leak degrades to the pre-#843 cost, never to an unowned tree at an ad-hoc name — the second half
# of #840's two-failure pattern).
#
# USAGE
#   repro_pull.sh create <run-id>
#       Creates the directory and prints its absolute path on STDOUT — and nothing else, so `$( )` capture is
#       exact. Every log line goes to stderr. Records the run's PRE-PULL local footprint (below).
#   repro_pull.sh reap <run-id> <path>
#       Removes the directory this helper created, once its caller has made the verdict durable. Records the
#       PEAK local footprint on the way out. Refuses anything but the one derived path (see the bound below).
#
# THE DELETE SCOPE IS STATICALLY BOUNDED, and that is the whole safety story for `reap` (the same shape
# reap_scratch.sh gate 2 states for its own `rm -rf`): the target is DERIVED from (EXPERIMENT_SCRATCH_ROOT,
# run-id) plus the fixed `fresh_reproduction` name, and the <path> argument is CHECKED AGAINST that
# derivation rather than trusted. It must additionally be a real directory (never a symlink, never resolving
# through one), never the calling shell's cwd or an ancestor of it, and it must not BE or CONTAIN a mount
# point — `rm -rf` unlinks a bind mount's contents THROUGH the mount and only then fails with EBUSY, so a
# non-zero exit is no protection at all (reap_scratch.sh gate 3c, round-3 code-review Finding 1). Anything
# failing any of those is REPORTED and left alone, never deleted.
#
# THE FOOTPRINT RECORD (#843's third bullet: put the number on the record). Neither the close checklist nor
# reap_scratch.sh can measure the close's PEAK by itself — reap_scratch runs after the pull is already gone,
# so by then the high-water mark is unobservable. This helper is the only thing standing at both moments, so
# it writes them into "<scratch>/<FOOTPRINT_FILE>", which reap_scratch.sh reads (and then deletes with the
# rest of the scratch) to print `peak_bytes=` on its SCRATCH-REAP-RECLAIMED line. The file name is a
# CROSS-SCRIPT CONVENTION: change it here and in reap_scratch.sh together.
#
# WHAT THE INSTANCE SUPPLIES: nothing new. The one input is the scratch root reap_scratch.sh already needs.
#   EXPERIMENT_SCRATCH_ROOT — the absolute LOCAL directory this instance creates per-run scratch dirs under.
#   Unset -> a LOUD no-op (a `REPRO-PULL-GAP:` line on stdout + exit 3, #804's shape), never a guess: without
#   it there is no bounded path to mint and none to delete. The gate still runs — pull by hand and remove the
#   tree by hand — but the record says the lifecycle was not wired instead of silently dropping it.
#   REPRO_PULL_MOUNTINFO — test seam for the mount table (default: /proc/self/mountinfo).
#
# EXIT CODES (all three are outcomes a close report states):
#   0  created / reaped (or nothing was there to reap)
#   1  a REAL failure — a gate refused, or the delete failed. The directory is still on disk.
#   3  WIRING/PLATFORM GAP — EXPERIMENT_SCRATCH_ROOT unset, or no readable mount table. Nothing was created
#      and nothing was deleted; a single `REPRO-PULL-GAP:` line on stdout is the line for the close report.
set -uo pipefail

# The fixed name shape, stated ONCE. `<scratch>/fresh_reproduction` is the path run-experiment/SKILL.md
# documents for the #447 gate; a change here is a change to that documented convention.
PULL_DIRNAME="fresh_reproduction"
# Read by reap_scratch.sh (see the FOOTPRINT RECORD block above) — a cross-script convention, not a local.
FOOTPRINT_FILE=".close_footprint"

GAP_EXIT=3

say(){ echo "repro_pull: $*" >&2; }
die(){ echo "repro_pull: $*" >&2; exit 1; }
gap(){
  local cause=$1; shift
  printf 'REPRO-PULL-GAP: run=%s cause=%s — %s\n' "${id:-unknown}" "$cause" "$*"
  say "WIRING GAP [$cause]: $* Nothing was created and nothing was deleted; put the REPRO-PULL-GAP line on the close report; exit $GAP_EXIT."
  exit "$GAP_EXIT"
}

# tree_bytes <path>... — total apparent bytes, or the empty string when it cannot be measured. Same
# GNU-then-portable shape (and the same "UNKNOWN is printed as unknown, never as a made-up 0") as
# reap_scratch.sh's copy: a fabricated 0 would read on the record as "the close cost nothing".
tree_bytes(){
  local out
  out=$(du -sb -- "$@" 2>/dev/null | awk '{t+=$1} END{if (NR) print t}') && [ -n "$out" ] && { printf '%s' "$out"; return 0; }
  out=$(du -sk -- "$@" 2>/dev/null | awk '{t+=$1} END{if (NR) print t*1024}') && [ -n "$out" ] && { printf '%s' "$out"; return 0; }
  return 1
}

# footprint_set <scratch> <key> <value> — rewrite ONE key in the footprint record, atomically (write a temp
# file in the same directory, then rename). A partially-written record would be read by reap_scratch.sh as a
# number, so it is replaced whole or not at all. A write failure is NOT fatal anywhere: the footprint is a
# measurement for the record, and losing a measurement must never cost the close its actual work.
footprint_set(){
  local scratch=$1 key=$2 val=$3 f="$1/$FOOTPRINT_FILE" tmp
  tmp=$(mktemp "$scratch/.close_footprint.XXXXXX" 2>/dev/null) || { say "NOTE: could not write the footprint record in '$scratch' (mktemp failed) — the close's peak footprint will read 'unmeasured' on the reap line."; return 0; }
  {
    [ -f "$f" ] && grep -v "^$key=" -- "$f" 2>/dev/null
    printf '%s=%s\n' "$key" "$val"
  } > "$tmp" 2>/dev/null
  mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; say "NOTE: could not update the footprint record '$f' — the close's peak footprint will read 'unmeasured' on the reap line."; }
  return 0
}

# resolve_scratch — bind `root_real` and `scratch` from (EXPERIMENT_SCRATCH_ROOT, run-id). The derivation is
# byte-identical to reap_scratch.sh's gate 2 on purpose: two scripts deriving the SAME run's scratch dir by
# two different rules is how one of them ends up bounded to a path the other never meant.
resolve_scratch(){
  [ -n "$id" ] || die "run-id must not be empty"
  case "$id" in
    */*|.|..) die "run-id '$id' must not contain '/' and must not be '.' or '..' — it becomes a path segment in the derived target" ;;
  esac
  local root=${EXPERIMENT_SCRATCH_ROOT:-}
  if [ -z "${root// /}" ]; then
    gap EXPERIMENT_SCRATCH_ROOT-unset "EXPERIMENT_SCRATCH_ROOT is unset, so the fresh-pull directory has no bounded path to be minted at or deleted from — wire the instance's scratch root (the same seam reap_scratch.sh needs)."
  fi
  case "$root" in
    /*) : ;;
    *) die "EXPERIMENT_SCRATCH_ROOT must be an ABSOLUTE path (got '$root') — a relative root would make the target depend on the caller's cwd" ;;
  esac
  root_real=$(cd "$root" 2>/dev/null && pwd -P) || die "EXPERIMENT_SCRATCH_ROOT '$root' is not a readable directory — refusing to derive a target from a root that does not resolve"
  [ "$root_real" != "/" ] || die "refusing to use '/' as EXPERIMENT_SCRATCH_ROOT: a scratch root is never the filesystem root"
  scratch="$root_real/$id"
  [ -d "$scratch" ] || die "run '$id''s scratch dir '$scratch' does not exist (derived from EXPERIMENT_SCRATCH_ROOT + the run-id) — the fresh pull belongs INSIDE the run's own scratch, so that a close which dies before reaping leaves it where reap_scratch.sh will still archive and remove it"
  local scratch_resolved
  scratch_resolved=$(cd "$scratch" && pwd -P) || die "could not resolve '$scratch'"
  [ "$scratch_resolved" = "$scratch" ] || die "refusing to use '$scratch': it resolves through a symlink to '$scratch_resolved' — the delete bound below is a PATH bound, so it must be checked against the path actually named"
  target="$scratch/$PULL_DIRNAME"
}

VERB=${1:-}
[ -n "$VERB" ] || die "usage: repro_pull.sh create <run-id> | repro_pull.sh reap <run-id> <path>"
shift

case "$VERB" in
create)
  [ $# -eq 1 ] || die "usage: repro_pull.sh create <run-id>"
  id=$1
  resolve_scratch
  # An existing tree is REFUSED, never reused or silently emptied: it is either a live pull someone else is
  # reading or a crashed close's residue, and both of those are answers a human gives. Reusing it would also
  # make the pre-pull measurement below a lie (it would already include the earlier pull's bytes).
  [ -e "$target" ] && die "'$target' already exists — refusing to reuse or overwrite it. If it is an earlier close attempt's residue, reap it first ('repro_pull.sh reap $id $target'); if something is still reading it, wait."
  # Measured BEFORE the directory exists, so `before_bytes` is the run's footprint without the fresh pull —
  # the other half of the peak the reap records (#843: `du` before the fresh pull vs after).
  before=$(tree_bytes "$scratch") || before=unknown
  mkdir "$target" || die "could not create the fresh-pull directory '$target'"
  footprint_set "$scratch" before_bytes "$before"
  say "fresh-pull directory created: '$target' (pre-pull footprint of '$scratch': $before bytes). REAP IT the moment the reproduction verdict is written: repro_pull.sh reap '$id' '$target' — or hand it to close_record.sh's --reap-repro-pull, which reaps it once REPRODUCTION.md is in the record."
  printf '%s\n' "$target"
  ;;

reap)
  [ $# -eq 2 ] || die "usage: repro_pull.sh reap <run-id> <path>"
  id=$1
  path=$2
  [ -n "$path" ] || die "reap requires a path"
  resolve_scratch
  [ "$path" = "$target" ] || die "refusing to reap '$path': run '$id''s fresh-pull directory is '$target' (derived from EXPERIMENT_SCRATCH_ROOT + the run-id + the fixed '$PULL_DIRNAME' name) and this path is not it — this helper only ever removes the one derived path, never a caller-supplied one"
  if [ ! -e "$target" ]; then
    say "nothing to reap: '$target' does not exist (already removed)"
    exit 0
  fi
  [ -L "$target" ] && die "refusing to reap '$target': it is a symlink — removing it would leave the tree it points at while claiming the space came back"
  [ -d "$target" ] || die "refusing to reap '$target': not a directory"
  real=$(cd "$target" && pwd -P) || die "could not resolve '$target'"
  [ "$real" = "$target" ] || die "refusing to reap '$target': it resolves through a symlinked ancestor to '$real'"
  pwd_real=$(pwd -P 2>/dev/null) || pwd_real=""
  case "${pwd_real:-/dev/null}" in
    "$real"|"$real"/*) die "refusing to reap '$real': the calling shell is standing inside it — cd out first, then re-run" ;;
  esac
  # NEVER DELETE THROUGH A MOUNT POINT (reap_scratch.sh gate 3c). The bound above is a PATH bound, and a
  # mount underneath the derived path escapes it: a same-filesystem bind mount has an IDENTICAL st_dev on
  # both sides, so `--one-file-system` and every `ismount` check read it as ordinary scratch. An unreadable
  # table establishes nothing, and UNKNOWN never reaches a delete.
  mountinfo=${REPRO_PULL_MOUNTINFO:-/proc/self/mountinfo}
  if [ -r "$mountinfo" ]; then
    while read -r _ _ _ _ mp _; do
      printf -v mp '%b' "$mp"   # mountinfo octal-escapes spaces/tabs/newlines/backslashes in mount points
      case "$mp" in
        /*) : ;;
        *) die "refusing to reap '$real': '$mountinfo' has a line whose mount-point field is not an absolute path — mount-freedom cannot be established from a table that does not parse, and nothing is deleted without it" ;;
      esac
      case "$mp" in
        "$real"|"$real"/*)
          die "refusing to reap '$real': it is, or contains, a mount point ('$mp') — deleting through a mount destroys the mounted data, not the fresh pull. Record this on the run's ledger line." ;;
      esac
    done < "$mountinfo"
  else
    gap mountinfo-unreadable "cannot enumerate mount points on this platform ('$mountinfo' unreadable), so mount-freedom cannot be established and nothing may be deleted without it."
  fi

  # Measured BEFORE the delete — afterwards there is nothing left to measure. The PEAK is the whole scratch
  # tree WITH the fresh pull still in it, which is the close's local high-water mark and the number #843
  # wants on the record; `pull_bytes` is what this reap actually gave back.
  pull_bytes=$(tree_bytes "$real") || pull_bytes=unknown
  peak_bytes=$(tree_bytes "$scratch") || peak_bytes=unknown
  rm -rf -- "$real" || die "'rm -rf $real' FAILED — the fresh pull is still on disk; remove it by hand and say so on the close report"
  footprint_set "$scratch" pull_bytes "$pull_bytes"
  footprint_set "$scratch" peak_bytes "$peak_bytes"
  printf 'REPRO-PULL-REAPED: run=%s pull_bytes=%s peak_bytes=%s path=%s\n' "$id" "$pull_bytes" "$peak_bytes" "$real"
  say "fresh-pull directory reaped: '$real' ($pull_bytes bytes back; the close's peak local footprint was $peak_bytes bytes, recorded for reap_scratch.sh's SCRATCH-REAP-RECLAIMED line)"
  ;;

*) die "unknown verb '$VERB' — expected 'create' or 'reap'" ;;
esac
