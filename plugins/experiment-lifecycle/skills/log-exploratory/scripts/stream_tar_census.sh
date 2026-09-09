#!/bin/bash
# stream_tar_census.sh — read a remote tar archive's MEMBER LIST from the stream. The archive's bytes are
# never written to this box: they flow curl -> tar -t and are discarded as they pass.
#
# INCIDENT (automated-researcher#857, 2026-09-09): a "LoRA target census" over six exploratory runs needed
# nothing but the tensor NAMES inside each Tinker adapter tar. The probe
# (`get_checkpoint_archive_url` -> `urlretrieve` -> `tarfile.open`) downloaded every archive in full to read
# them: 41.5 GB of 0.35 GB tars landed under `~/work`, were then hardlinked into an `archive/` tree, and were
# uploaded a SECOND time (R2 held 104 objects for 50 unique tars). The box was a staging hop for artifacts
# that never needed to touch it, and 10-34 h after the notes landed the tars were still there. The names were
# always available from the stream — a tar member list is header records interleaved with the data, so `tar
# -t` yields them without ever materializing a member.
#
# THE RULE THIS HELPER IMPLEMENTS (`log-exploratory`'s artifact-staging rule): an artifact produced elsewhere
# (a pod, Tinker) goes producer -> store DIRECTLY, and the box holds pointers. When you need to read
# something ABOUT such an artifact rather than the artifact itself, read it from the stream. Nothing >1 GB is
# written under the work dir unless it is on its way to the store or deleted by the same script.
#
# WHAT IT DOES NOT DO: it does not fetch member CONTENT, and it never writes the archive (only the member
# NAMES, into a temp file it removes). Bytes still cross the network — the saving is the disk hop, the
# second upload, and the residue, not the transfer. `--max-members N` cuts the transfer short as well: the
# reader closing the pipe tears curl down mid-stream, so a census that only needs the first few members
# never pulls the tail of the archive.
#
# USAGE:
#   stream_tar_census.sh [--max-members N] [--label L] <url> [<url>...]
#   stream_tar_census.sh [--max-members N] -            # read URLs from stdin, one per line
#
# OUTPUT (stdout, one line per member, a close report / NOTE.md table is written from it):
#   <label><TAB><member-path>
# `--label` names a single URL; without it the label is the URL's last path component. Diagnostics and the
# per-archive `CENSUS:` summary line go to stderr.
#
# EXIT: 0 every URL censused; 1 any URL failed (a failed census prints no member lines for that URL, so a
# partial run can never read as a complete census).
set -uo pipefail

die(){ echo "stream_tar_census: $*" >&2; exit 1; }
say(){ echo "stream_tar_census: $*" >&2; }

command -v curl >/dev/null 2>&1 || die "curl is not on PATH — the census reads the archive from the stream, so there is nothing to fall back to"
command -v tar  >/dev/null 2>&1 || die "tar is not on PATH"

MAX=""
LABEL=""
urls=()
while [ $# -gt 0 ]; do
  case "$1" in
    --max-members)
      [ -n "${2:-}" ] || die "--max-members requires a value"
      case "$2" in *[!0-9]*|"") die "--max-members must be a positive integer (got '$2')";; esac
      [ "$2" -gt 0 ] || die "--max-members must be a positive integer (got '$2')"
      MAX=$2; shift 2 ;;
    --label) [ -n "${2:-}" ] || die "--label requires a value"; LABEL=$2; shift 2 ;;
    -)  while IFS= read -r line; do [ -n "$line" ] && urls+=("$line"); done; shift ;;
    --) shift; while [ $# -gt 0 ]; do urls+=("$1"); shift; done ;;
    -*) die "unknown option '$1' (usage: stream_tar_census.sh [--max-members N] [--label L] <url>...)" ;;
    *)  urls+=("$1"); shift ;;
  esac
done
[ "${#urls[@]}" -gt 0 ] || die "usage: stream_tar_census.sh [--max-members N] [--label L] <url>... (or '-' for stdin)"
[ -z "$LABEL" ] || [ "${#urls[@]}" -eq 1 ] || die "--label names ONE archive; with ${#urls[@]} URLs the labels are derived per URL instead"

fails=0

# census_one <label> <url> — stream the archive through `tar -t` and print its member list.
census_one(){
  local label=$1 url=$2
  # Only http(s). A LOCAL path is already on the box, which is the hop this helper exists to remove — reading
  # it here would silently bless the staging pattern instead of replacing it.
  case "$url" in
    http://*|https://*) : ;;
    *) say "REFUSING '$url': only http(s) URLs are censused (a local path is already on this box — that hop is what this helper exists to remove)"; fails=1; return 1 ;;
  esac
  # The member NAMES land in a temp file; the archive itself never does. Names are the whole product here,
  # and they are kilobytes even for an archive that is gigabytes.
  local tmp; tmp=$(mktemp) || die "mktemp failed — refusing to census without somewhere to put the member list"
  local st n
  if [ -n "$MAX" ]; then
    curl -fsS --location --retry 2 -- "$url" | tar -tf - | head -n "$MAX" > "$tmp"
  else
    curl -fsS --location --retry 2 -- "$url" | tar -tf - > "$tmp"
  fi
  st=("${PIPESTATUS[@]}")
  n=$(wc -l < "$tmp" | tr -d '[:space:]')
  # A CAPPED census tears the transfer down on purpose: `head` closes the pipe, so curl dies on a write error
  # (23) or SIGPIPE (141) and tar on the same signal. Those statuses ARE the mechanism, so the success
  # criterion there is "the cap was reached" rather than "every stage exited 0". An UNCAPPED census has no
  # such teardown, so both stages must exit 0 — a truncated stream must never read as a complete census.
  if [ -n "$MAX" ] && [ "$n" -ge "$MAX" ]; then
    :
  elif [ "${st[0]}" != 0 ] || [ "${st[1]}" != 0 ]; then
    rm -f "$tmp"
    say "CENSUS FAILED for '$url' (curl exited ${st[0]}, tar exited ${st[1]}) — no member lines are printed for it, so a partial run cannot read as a complete census"
    fails=1
    return 1
  fi
  # Printed only after the archive is known to have been read end-to-end (or the cap reached) — see above.
  sed "s#^#${label}\t#" < "$tmp"
  rm -f "$tmp"
  say "CENSUS: label=$label members=$n${MAX:+ capped_at=$MAX} archive_written_to_disk=no url=$url"
  return 0
}

for u in "${urls[@]}"; do
  l=$LABEL
  [ -n "$l" ] || { l=${u%%\?*}; l=${l##*/}; [ -n "$l" ] || l=$u; }
  census_one "$l" "$u" || true
done

exit "$fails"
