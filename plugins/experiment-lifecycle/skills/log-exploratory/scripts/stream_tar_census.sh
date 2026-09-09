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
#
# TWO INVARIANTS ON CALLER DATA (both from PR #858's round-1 review). A URL and a label are DATA, and this
# script is the only thing between that data and (a) a shell, (b) whatever captured its log:
#   1. CALLER DATA IS NEVER PROGRAM TEXT. The `<label><TAB><member>` prefix was applied with
#      `sed "s#^#$label\t#"`, which made the label part of the sed PROGRAM: a `#` in the label closes the
#      `s###` command, and GNU sed's `e` flag then EXECUTES the pattern space — the replacement text plus
#      the member path — as a shell command. `--label 'touch /tmp/pwn;#e;#'` therefore ran `touch /tmp/pwn`
#      (the `;` makes the appended member path a separate, failing command), confirmed against the old form
#      on GNU sed 4.9. Labels are emitted with `printf` only, and NOTHING anywhere in this file builds a
#      program out of a variable — no `sed`/`awk` program text, no `eval`; the redaction below walks tokens
#      with bash string operators for the same reason.
#   2. NO DIAGNOSTIC EVER EMITS A LIVE URL. This helper exists FOR presigned store URLs, which carry their
#      CREDENTIALS in the query string (`X-Amz-Signature`/`X-Amz-Credential`, a GCS `Signature=`) or, on a
#      userinfo URL, before the `@`. Echoing one verbatim writes a live capability into whatever captured
#      the log — and this script's whole output is meant to be captured (a close report). Every URL that
#      reaches stdout or stderr goes through `redact_url` first: refusals, the failure line, the `CENSUS:`
#      summary, and a derived label. curl's/tar's own error text is not ours to word, so it is replayed
#      through `redact_text`, which redacts every `://`-bearing token in it — a redirect target curl chose
#      to print is covered too, not just the URL this script handed it.
set -uo pipefail

die(){ echo "stream_tar_census: $*" >&2; exit 1; }
say(){ echo "stream_tar_census: $*" >&2; }

# redact_url <url> — the DISPLAY form of a URL: scheme, host, path, nothing else. Userinfo collapses to
# `REDACTED@`; a dropped query/fragment is replaced by a literal `?REDACTED` so a diagnostic never reads as
# if it were showing the whole URL. See invariant 2.
redact_url(){
  local u=$1 scheme="" rest="" dropped=""
  case "$u" in *://*) scheme="${u%%://*}://"; rest=${u#*://} ;; *) rest=$u ;; esac
  case "$rest" in *\?*|*\#*) dropped="?REDACTED" ;; esac
  rest=${rest%%\#*}; rest=${rest%%\?*}
  case "$rest" in *@*) rest="REDACTED@${rest#*@}" ;; esac
  printf '%s%s%s' "$scheme" "$rest" "$dropped"
}

# redact_text <line> — the display form of an arbitrary diagnostic line: every URL-shaped token in it is
# passed through redact_url. Used for curl's/tar's own stderr, whose wording is not ours to control.
# Globbing is off while the tokens are walked (they are data, and `*` in an error message must not expand);
# the prior setting is restored rather than assumed.
redact_text(){
  local out="" tok had_f=0
  case $- in *f*) had_f=1 ;; esac
  set -f
  for tok in $1; do
    case "$tok" in *://*) tok=$(redact_url "$tok") ;; esac
    out="${out:+$out }$tok"
  done
  [ "$had_f" = 1 ] || set +f
  printf '%s' "$out"
}

# label_ok <label> — a label is the FIRST FIELD of each TAB-separated output line, so a control character
# in it (a TAB or newline above all) would silently break that contract for whatever reads the census.
# This is a data-integrity check, NOT the safety mechanism: safety is invariant 1 — the label is never
# program text, whatever it contains.
label_ok(){ case "$1" in ""|*[[:cntrl:]]*) return 1 ;; esac; return 0; }

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
    --label)
      [ -n "${2:-}" ] || die "--label requires a value"
      label_ok "$2" || die "--label must not contain control characters — it is the first field of each TAB-separated output line"
      LABEL=$2; shift 2 ;;
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
  local label=$1 url=$2 display
  display=$(redact_url "$url")   # the ONLY form of the URL that any diagnostic below may print
  # Only http(s). A LOCAL path is already on the box, which is the hop this helper exists to remove — reading
  # it here would silently bless the staging pattern instead of replacing it.
  case "$url" in
    http://*|https://*) : ;;
    *) say "REFUSING '$display': only http(s) URLs are censused (a local path is already on this box — that hop is what this helper exists to remove)"; fails=1; return 1 ;;
  esac
  label_ok "$label" || { say "REFUSING '$display': its label contains a control character, which would break the TAB-separated output contract — pass an explicit --label"; fails=1; return 1; }
  # The member NAMES land in a temp file; the archive itself never does. Names are the whole product here,
  # and they are kilobytes even for an archive that is gigabytes. `errf` holds curl's/tar's own stderr so it
  # can be replayed REDACTED (invariant 2) instead of going straight out with the URL in it.
  local tmp errf
  tmp=$(mktemp)  || die "mktemp failed — refusing to census without somewhere to put the member list"
  errf=$(mktemp) || { rm -f "$tmp"; die "mktemp failed — refusing to census without somewhere to hold curl's error text for redaction"; }
  local st n
  if [ -n "$MAX" ]; then
    curl -fsS --location --retry 2 -- "$url" 2>>"$errf" | tar -tf - 2>>"$errf" | head -n "$MAX" > "$tmp"
  else
    curl -fsS --location --retry 2 -- "$url" 2>>"$errf" | tar -tf - 2>>"$errf" > "$tmp"
  fi
  st=("${PIPESTATUS[@]}")
  n=$(wc -l < "$tmp" | tr -d '[:space:]')
  # A CAPPED census tears the transfer down on purpose: `head` closes the pipe, so curl dies on a write error
  # (23) or SIGPIPE (141) and tar on the same signal. Those statuses ARE the mechanism, so the success
  # criterion there is "the cap was reached" rather than "every stage exited 0". An UNCAPPED census has no
  # such teardown, so both stages must exit 0 — a truncated stream must never read as a complete census.
  if [ -n "$MAX" ] && [ "$n" -ge "$MAX" ]; then
    rm -f "$errf"   # the teardown's own "broken pipe" noise IS the mechanism here, not a diagnostic
  elif [ "${st[0]}" != 0 ] || [ "${st[1]}" != 0 ]; then
    rm -f "$tmp"
    replay_errors "$errf"; rm -f "$errf"
    say "CENSUS FAILED for '$display' (curl exited ${st[0]}, tar exited ${st[1]}) — no member lines are printed for it, so a partial run cannot read as a complete census"
    fails=1
    return 1
  else
    replay_errors "$errf"; rm -f "$errf"
  fi
  # Printed only after the archive is known to have been read end-to-end (or the cap reached) — see above.
  # `printf`, not a sed program built from the label (invariant 1). The `|| [ -n "$member" ]` picks up a
  # final line with no trailing newline, which `head -c`-style truncation of a stream can leave behind.
  local member
  while IFS= read -r member || [ -n "$member" ]; do
    printf '%s\t%s\n' "$label" "$member"
  done < "$tmp"
  rm -f "$tmp"
  say "CENSUS: label=$label members=$n${MAX:+ capped_at=$MAX} archive_written_to_disk=no url=$display"
  return 0
}

# replay_errors <errfile> — surface curl's/tar's own diagnostics, redacted. Their wording is not ours, so
# any URL-shaped token in them is redacted generically rather than by matching the URL we passed.
replay_errors(){
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] && say "$(redact_text "$line")"
  done < "$1"
  return 0
}

for u in "${urls[@]}"; do
  l=$LABEL
  # The derived label is the URL's last path component with the query (i.e. the presigned credentials)
  # already stripped; the whole-URL fallback is redacted, because a label is printed on every member line.
  [ -n "$l" ] || { l=${u%%\?*}; l=${l##*/}; [ -n "$l" ] || l=$(redact_url "$u"); }
  census_one "$l" "$u" || true
done

exit "$fails"
