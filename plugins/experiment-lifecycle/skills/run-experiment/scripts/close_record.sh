#!/usr/bin/env bash
# close_record.sh — emit run-experiment's MECHANICAL close paperwork from state, not prose (#819), under the
# invariants automated-researcher#821 states for it.
#
# Why this exists (measured, automated-researcher#819): across 61 executor runs since 2026-08-01 the close
# leg ran a median 51 min of a 136-min median run, and roughly HALF of a run's output tokens were spent in
# it. The close touches ~15 record artifacts and the model hand-authored nearly all of them — including the
# ones that are pure restatements of state it already holds (what landed where, how many objects are in the
# artifact store, which pull commands reproduce the numbers, which terminal ledger event to write). Judgment
# artifacts stay the model's: RESULTS.md and the audit responses are NOT emitted here and never will be.
#
# What it emits into <registry-dir>:
#   LANDED.md             — what this close landed and where (record dir, artifact root, page source, ledger event)
#   ARTIFACT_MANIFEST.md  — the R2/artifact-store pointer #232 requires: path + object count + key sizes,
#                           derived from an ACTUAL listing of the store that was BYTE-VERIFIED against the
#                           local artifact set this run uploaded (never a claim it did not observe)
#   REPRODUCTION.md       — the #447 fresh-pull reproduction record: the documented pull commands, the
#                           committed scripts, and the verbatim diff output the gate produced
#   CLOSE_SELF_AUDIT.md   — the close self-audit checklist, UNSTARTED (☐), with the derived evidence hints
#
# The five invariants #821 states (each one a PR #820 review finding — the regression cases live in
# close_record_smoke.sh, named per finding):
#   1. LISTING = STDOUT ONLY. The store listing is captured from the lister's stdout alone; its stderr is
#      captured separately, surfaced verbatim, and never parsed. A non-zero exit from the lister is a hard
#      failure. Merging the two (`rclone lsl 2>&1`) let routine `NOTICE:`/`WARNING:` lines — which real
#      rclone emits while exiting 0 — count as objects: an EMPTY store listed as "1 object, 2026 bytes"
#      (the date prefix summed as a size), and real listings inflated the same way (#820 round 4). A line on
#      stdout that is not in `rclone lsl` shape is therefore a hard failure too, never a counted object.
#   2. NON-EMPTY AND BYTE-VERIFIED, OR NOTHING. A manifest is written only when the listing has ≥1 object,
#      every file the local artifact set (`--uploaded-from`) says was uploaded is in that listing at a
#      MATCHING SIZE (and matching hash wherever the store gives one), and nothing in the listing is
#      unaccounted for by that local set. Any of those failing → no manifest, exit non-zero, one line saying
#      which. A successful-but-EMPTY listing is evidence AGAINST the upload, not for it (#820 rounds 1-2).
#   3. ATOMIC WRITE-OR-NOTHING. Every generated file is written to a temp dir inside the record dir and moved
#      into place only after every check has passed and the terminal ledger event has been written. A failed
#      run leaves no partial artifact — and a PREVIOUS generated manifest is renamed `*.stale` rather than
#      left standing as the record's answer, claiming a verified upload this close did not observe (#820
#      round 2: a failed re-list left the earlier manifest in place while the gap line said there was none).
#      This is why a missing seam / absent `rclone` fails BEFORE any write (exit 3, #804's loud-gap shape)
#      instead of emitting the rest: "the record carries no unbacked paperwork" is a property of the RECORD,
#      not of one invocation.
#   4. FINALIZE PROVES THE LANDING FROM THE REMOTE, NEVER FROM LOCAL FILES. `finalize` requires `--base-ref`,
#      FETCHES it, and checks the record + `LANDED.md` at the fetched remote-tracking ref. `paperwork` writes
#      LANDED.md itself, so its presence in the working tree only ever proved that this same script just ran
#      (#820 round 1, P0) — and closing the run-supervision record un-gates worktree/scratch/session reaping,
#      with the worktree holding the only local copy of the record.
#   5. LEDGER + SUPERVISION WRITES GO THROUGH THE EXISTING HELPERS and honor the terminal-event rules:
#      #473 (the terminal event's `run` field is the REGISTRY DIR NAME exactly, no suffix — derived here from
#      the dir, never from the run-id, which is frequently a different string), #376 (the terminal status is
#      an OPERATIONAL outcome the caller states and this script validates, never invents, and never maps onto
#      an instance's concrete ledger strings — that mapping is the instance's ledger recipe, reached through
#      EXPERIMENT_LEDGER_EVENT_CMD), #338 (only ever a TERMINAL event; nothing here can emit
#      running/launched/deploying).
#
# Further fail-closed rules, each from a real incident:
#   - #729: an artifact root that does not carry this experiment's own identifier as a path segment is
#     REFUSED — a pulled driver stack's un-renamed path literal pointing at a SIBLING's root is exactly how
#     41 objects of a closed record were permanently lost, and a manifest that pins the sibling's root is
#     that incident written into the permanent record.
#   - #331: a manifest never claims an upload it did not observe (invariant 2 above is the hardened form).
#   - #804: a missing instance seam is LOUD (exit 3 + a `CLOSE-RECORD-GAP:` line for the close record),
#     never a quiet no-op — seven consecutive closes reaped nothing because a no-op said so only on stdout
#     and exited 0.
#   - #512: the emitted checklist is UNSTARTED (every box ☐). Pre-ticked gates are how a copied checklist
#     silently satisfies gates nobody ran.
#
# Usage (the canonical invocations are documented VERBATIM in run-experiment/SKILL.md, and
# close_record_smoke.sh extracts them from that file and runs them — a SKILL.md that documents an
# invocation this script would reject fails the smoke, #820 round 1):
#   close_record.sh paperwork <run-id> <registry-dir> --outcome <abstract-outcome>
#                   (--artifact-root <rclone-dest> --uploaded-from <local-dir>... | --no-artifacts)
#                   [--page-source <path>] [--pull-cmd <cmd>]... [--repro-diff <file>]
#   close_record.sh finalize  <run-id> <registry-dir> --base-ref <remote>/<branch> [--stop]
#
#   paperwork  runs BEFORE the TEMP.md delete + staging, so its output lands with the record.
#   finalize   is the POST-AUDIT finalizer (ordering is load-bearing — see SKILL.md): it proves the
#              paperwork above actually MERGED at --base-ref, then closes the run-supervision record via its
#              own helper. It is deliberately a SECOND call: closing the record early would make the relaunch
#              supervisor refuse to recover a run whose compute is still billing.
#
# Exit codes: 0 = everything verified and written · 1 = BLOCK (bad arguments, or evidence that contradicts
# the paperwork — nothing was written) · 3 = GAP (a required instance seam / tool is missing, so nothing
# could be observed or recorded — nothing was written, and a `CLOSE-RECORD-GAP:` line on stdout is the
# verbatim line to copy onto the close report).
#
# Instance seam:
#   EXPERIMENT_LEDGER_EVENT_CMD  a command invoked as `<cmd> <run> <abstract-outcome> <registry-dir>` that
#                                writes the instance's own terminal ledger event. Unset => exit 3 with a
#                                CLOSE-RECORD-GAP: line and NOTHING written (invariant 3).
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN_MARKER='<!-- generated-by: close_record.sh (automated-researcher#819) -->'

die()  { echo "BLOCK: $*" >&2; exit 1; }
note() { echo "[close-record] $*" >&2; }
gap()  { echo "CLOSE-RECORD-GAP: $*"; }   # stdout, verbatim-copyable onto the close report (#804 shape)

usage() {
  cat >&2 <<'USAGE'
usage:
  close_record.sh paperwork <run-id> <registry-dir> --outcome <completed-as-designed|technical-failure|deliberate-abandon>
                  (--artifact-root <rclone-dest> --uploaded-from <local-dir>... | --no-artifacts)
                  [--page-source <path>] [--pull-cmd <cmd>]... [--repro-diff <file>]
  close_record.sh finalize  <run-id> <registry-dir> --base-ref <remote>/<branch> [--stop]
USAGE
  exit 1
}

# ---------------------------------------------------------------------------------------------------------
# Generated-file staging (invariant 3): every emission is written into $TMPDIR_GEN first and moved into
# place by commit_generated, so a failing check leaves the record exactly as it was.
# ---------------------------------------------------------------------------------------------------------
TMPDIR_GEN=""
declare -a GEN_NAMES=() WROTE=() KEPT=() STALED=()

cleanup_gen() { [ -n "$TMPDIR_GEN" ] && rm -rf "$TMPDIR_GEN"; return 0; }
trap cleanup_gen EXIT

# stage_generated <name> <<'EOF' … : stage one generated file's body. Nothing touches the record dir yet.
stage_generated() {
  local name="$1"
  cat > "$TMPDIR_GEN/$name"
  GEN_NAMES+=("$name")
}

# commit_generated <record-dir>: move every staged file into place. A destination file WITHOUT the
# generated-by marker was taken over by a human/model, so it is left exactly as it is (reported, not
# overwritten); one we generated is replaced, which is what makes regeneration idempotent.
commit_generated() {
  local dir="$1" name
  for name in "${GEN_NAMES[@]}"; do
    if [ -e "$dir/$name" ] && ! grep -qF "$GEN_MARKER" "$dir/$name" 2>/dev/null; then
      note "kept hand-authored $name (no generated-by marker) — not overwritten"
      KEPT+=("$name")
      continue
    fi
    mv -f "$TMPDIR_GEN/$name" "$dir/$name" || die "could not move generated $name into $dir"
    WROTE+=("$name")
  done
}

# stale_generated <path>: a generated file whose claim this close could NOT back is renamed `*.stale`
# instead of being left in the record. It is not deleted (the numbers in it are still evidence of what an
# earlier close observed) and it is not left in place (it would keep answering "the upload was verified" for
# a record whose current close observed no such thing — #820 round 2). A file without GEN_MARKER is
# hand-authored and is never ours to move.
stale_generated() {
  local path="$1"
  [ -e "$path" ] || return 0
  if ! grep -qF "$GEN_MARKER" "$path" 2>/dev/null; then
    note "kept hand-authored $(basename "$path") (no generated-by marker) — not renamed"
    return 0
  fi
  mv -f "$path" "$path.stale" || die "could not rename $(basename "$path") aside"
  STALED+=("$(basename "$path")")
  note "renamed $(basename "$path") -> $(basename "$path").stale — this close observed no verified listing to back it"
}

# ---------------------------------------------------------------------------------------------------------
# Store observation + byte verification (invariants 1 + 2)
# ---------------------------------------------------------------------------------------------------------
# Globals the verifier fills: LISTING (raw stdout, verbatim), OBJECTS, BYTES, HASH_MODE.
LISTING=""; OBJECTS=0; BYTES=0; HASH_MODE="size-only (the store reported no hashes)"
declare -A STORE_SIZE=() STORE_HASH=() LOCAL_SIZE=()

# local_artifact_set <dir>...: fill LOCAL_SIZE with `relative-path -> byte size` for every regular file
# under each uploaded-from dir. Several dirs are accepted because the completion boundary uploads PER
# ARTIFACT-COMPLETION (#460), so one root legitimately receives several local legs; a path two dirs disagree
# on is ambiguous and fails closed rather than picking one.
# NUL-delimited (`%P\0`) so a path containing a newline is read raw rather than silently splitting into two
# bogus entries — a corrupted local set would make the verification below assert the wrong thing. `-type f`
# (regular files only, symlinks not followed) matches rclone's own default of skipping symlinks, so the two
# sides of the comparison are the same set of things.
local_artifact_set() {
  local d rel size
  for d in "$@"; do
    while IFS=$'\t' read -r -d '' size rel; do
      [ -n "$rel" ] || continue
      if [ -n "${LOCAL_SIZE["$rel"]:-}" ] && [ "${LOCAL_SIZE["$rel"]}" != "$size" ]; then
        die "--uploaded-from dirs disagree about '$rel' (${LOCAL_SIZE["$rel"]} vs $size bytes) — the local artifact set must say ONE thing about each uploaded object; pass the dirs that were actually uploaded to distinct paths under the root"
      fi
      LOCAL_SIZE["$rel"]="$size"
    done < <(find "$d" -type f -printf '%s\t%P\0')
  done
}

# observe_store <artifact-root>: capture the listing from STDOUT ONLY, keep stderr separate and surface it,
# then verify it against LOCAL_SIZE. Prints one BLOCK line and returns 1 on any failure of invariant 1 or 2.
observe_store() {
  local root="$1" out err rc=0 line size path p
  out="$TMPDIR_GEN/.lsl.out"; err="$TMPDIR_GEN/.lsl.err"
  rclone lsl "$root" > "$out" 2> "$err" || rc=$?
  # stderr is DIAGNOSTIC, never content: surfaced verbatim so a real problem is visible, never parsed.
  if [ -s "$err" ]; then
    note "rclone stderr (diagnostics, not listing content):"
    sed 's/^/  | /' "$err" >&2
  fi
  if [ "$rc" -ne 0 ]; then
    echo "BLOCK: listing the artifact store '$root' FAILED (rclone lsl exit $rc; its stderr is above) — no ARTIFACT_MANIFEST.md was written: a manifest that claims an upload nobody observed is the #331 divergence, so this fails closed. Fix the root/credentials and re-run" >&2
    return 1
  fi
  # Invariant 1: every stdout line must be in `rclone lsl` shape (size, date, time, path). A line that is
  # not is not an object — it is a diagnostic that leaked onto stdout, or an rclone whose output format this
  # script does not understand, and counting it is exactly how an empty store became "1 object, 2026 bytes".
  while IFS= read -r line; do
    [ -n "${line//[[:space:]]/}" ] || continue
    if [[ "$line" =~ ^[[:space:]]*([0-9]+)[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?[[:space:]]+(.+)$ ]]; then
      size="${BASH_REMATCH[1]}"; path="${BASH_REMATCH[3]}"
      STORE_SIZE["$path"]="$size"
      OBJECTS=$((OBJECTS + 1)); BYTES=$((BYTES + size))
    else
      echo "BLOCK: the listing of '$root' carried a line that is not in 'rclone lsl' shape (<size> <date> <time> <path>), so it is not an object this manifest can count: '$line' — no ARTIFACT_MANIFEST.md was written. A diagnostic line counted as an object is how an EMPTY store listed as '1 object, 2026 bytes' (#820 round 4)" >&2
      return 1
    fi
  done < "$out"
  LISTING="$(cat "$out")"
  # (a) non-empty. A listing that SUCCEEDS and comes back empty is evidence AGAINST the upload: --artifact-root
  # is the caller asserting this run put heavy artifacts there, so zero objects means the upload landed
  # somewhere else (the #729 wrong-root shape) or never ran.
  if [ "$OBJECTS" -eq 0 ]; then
    echo "BLOCK: the artifact store '$root' listed successfully but is EMPTY (0 objects) — no ARTIFACT_MANIFEST.md was written; --artifact-root asserts this run HAS heavy artifacts there, so an empty listing means the upload went somewhere else (the #729 wrong-root shape) or never ran, and a zero-object manifest would record a verified upload nobody observed (#331). Verify the upload against this root and re-run, or pass --no-artifacts if this run genuinely stored nothing" >&2
    return 1
  fi
  # (b) every local object present at a matching size. This is the half that makes the manifest a VERIFIED
  # statement rather than a transcript of whatever happened to be in the bucket.
  local -a missing=() mismatched=() surplus=() hashbad=()
  for p in "${!LOCAL_SIZE[@]}"; do
    if [ -z "${STORE_SIZE["$p"]:-}" ]; then missing+=("$p")
    elif [ "${STORE_SIZE["$p"]}" != "${LOCAL_SIZE["$p"]}" ]; then
      mismatched+=("$p (local ${LOCAL_SIZE["$p"]} vs store ${STORE_SIZE["$p"]} bytes)")
    fi
  done
  # (c) nothing in the listing unaccounted for by the local set. Surplus is REPORTED, never silently
  # accepted: an object the local set cannot explain means either the local set is not what was uploaded, or
  # this root is shared with something else — both make "objects | N" a claim about the wrong set of bytes.
  for p in "${!STORE_SIZE[@]}"; do
    [ -n "${LOCAL_SIZE["$p"]:-}" ] || surplus+=("$p")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "BLOCK: ${#missing[@]} file(s) the local artifact set says were uploaded are ABSENT from the listing of '$root' — no ARTIFACT_MANIFEST.md was written: $(printf '%s ' "${missing[@]:0:5}")" >&2
    return 1
  fi
  if [ "${#mismatched[@]}" -gt 0 ]; then
    echo "BLOCK: ${#mismatched[@]} uploaded file(s) are in the listing of '$root' at a DIFFERENT size than the local copy — no ARTIFACT_MANIFEST.md was written (a truncated/interrupted upload is not a verified one): $(printf '%s; ' "${mismatched[@]:0:5}")" >&2
    return 1
  fi
  if [ "${#surplus[@]}" -gt 0 ]; then
    echo "BLOCK: ${#surplus[@]} object(s) in the listing of '$root' are unaccounted for by the local artifact set — no ARTIFACT_MANIFEST.md was written: $(printf '%s ' "${surplus[@]:0:5}"). Either --uploaded-from is not the set that was uploaded, or this root holds another run's objects (the #729 wrong-root shape); name the dirs that were uploaded, or upload to a root of this experiment's own" >&2
    return 1
  fi
  # Hashes WHERE THE STORE GIVES ONE. A store that cannot hash (or a box without md5sum) is not a failure —
  # sizes already matched — but it is recorded in the manifest so the record never overstates what was checked.
  local hs_out hs_rc=0 want got
  hs_out="$TMPDIR_GEN/.hashsum.out"
  rclone hashsum md5 "$root" > "$hs_out" 2>/dev/null || hs_rc=$?
  if [ "$hs_rc" -eq 0 ] && [ -s "$hs_out" ] && command -v md5sum >/dev/null 2>&1; then
    while IFS= read -r line; do
      if [[ "$line" =~ ^([0-9a-fA-F]{32})[[:space:]]+(.+)$ ]]; then
        STORE_HASH["${BASH_REMATCH[2]}"]="${BASH_REMATCH[1],,}"
      fi
    done < "$hs_out"
    local checked=0
    for p in "${!LOCAL_SIZE[@]}"; do
      want="${STORE_HASH["$p"]:-}"; [ -n "$want" ] || continue
      got="$(local_md5 "$p")"
      [ -n "$got" ] || continue
      checked=$((checked + 1))
      [ "$got" = "$want" ] || hashbad+=("$p (local $got vs store $want)")
    done
    if [ "${#hashbad[@]}" -gt 0 ]; then
      echo "BLOCK: ${#hashbad[@]} uploaded file(s) are in the listing of '$root' at a matching size but a DIFFERENT md5 than the local copy — no ARTIFACT_MANIFEST.md was written (same size, different bytes is a corrupted upload, not a verified one): $(printf '%s; ' "${hashbad[@]:0:5}")" >&2
      return 1
    fi
    [ "$checked" -gt 0 ] && HASH_MODE="md5-verified ($checked of $OBJECTS object(s) carried a store hash)"
  fi
  return 0
}

# local_md5 <relative-path>: the md5 of the local copy of an uploaded object, found in whichever
# --uploaded-from dir holds it (the first one wins; local_artifact_set already refused a disagreement).
local_md5() {
  local rel="$1" d
  for d in "${UPLOADED_FROM[@]}"; do
    if [ -f "$d/$rel" ]; then md5sum "$d/$rel" 2>/dev/null | cut -d' ' -f1; return 0; fi
  done
  return 0
}

cmd_paperwork() {
  local run_id="$1" dir="$2"; shift 2
  local outcome="" artifact_root="" no_artifacts=0 page_source="" repro_diff=""
  local -a pull_cmds=()
  UPLOADED_FROM=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --outcome)       [ "$#" -ge 2 ] || die "--outcome requires a value";       outcome="$2"; shift 2 ;;
      --artifact-root) [ "$#" -ge 2 ] || die "--artifact-root requires a value"; artifact_root="$2"; shift 2 ;;
      --uploaded-from) [ "$#" -ge 2 ] || die "--uploaded-from requires a value"; UPLOADED_FROM+=("$2"); shift 2 ;;
      --no-artifacts)  no_artifacts=1; shift ;;
      --page-source)   [ "$#" -ge 2 ] || die "--page-source requires a value";   page_source="$2"; shift 2 ;;
      --pull-cmd)      [ "$#" -ge 2 ] || die "--pull-cmd requires a value";      pull_cmds+=("$2"); shift 2 ;;
      --repro-diff)    [ "$#" -ge 2 ] || die "--repro-diff requires a value";    repro_diff="$2"; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done

  [ -d "$dir" ] || die "not a directory: $dir"
  dir="$(cd "$dir" && pwd)"
  local exp; exp="$(basename "$dir")"

  # #376: the abstract outcome is the caller's to state and the script's to validate — never to guess.
  case "$outcome" in
    completed-as-designed|technical-failure|deliberate-abandon) : ;;
    "") die "--outcome is required: completed-as-designed | technical-failure | deliberate-abandon (#376) — a terminal ledger status is an OPERATIONAL statement about the run, never a scientific verdict, and never something this script infers for you" ;;
    *)  die "unknown --outcome '$outcome' — expected completed-as-designed | technical-failure | deliberate-abandon (#376)" ;;
  esac
  if [ "$no_artifacts" = 1 ]; then
    [ -z "$artifact_root" ] || die "--artifact-root and --no-artifacts are mutually exclusive"
    [ "${#UPLOADED_FROM[@]}" -eq 0 ] || die "--uploaded-from has nothing to verify against under --no-artifacts (which asserts this run stored nothing) — drop one of them"
  else
    [ -n "$artifact_root" ] || die "one of --artifact-root <rclone-dest> or --no-artifacts is required — a record with heavy artifacts needs the ARTIFACT_MANIFEST.md that pins where they are (#232); an API-only run with nothing in the store says so explicitly"
    [ "${#UPLOADED_FROM[@]}" -gt 0 ] || die "--artifact-root needs at least one --uploaded-from <local-dir>: the manifest is written only when the store listing is BYTE-VERIFIED against the local set this run uploaded (#821 invariant 2), and without that local set there is nothing to verify against — a listing on its own only says what is in the bucket, never that YOUR artifacts are"
    local d
    for d in "${UPLOADED_FROM[@]}"; do [ -d "$d" ] || die "--uploaded-from is not a directory: $d"; done
    # #729: refuse a root that does not carry THIS experiment's identifier. The incident's shape is a
    # sibling's root reached through an un-renamed path literal; pinning it in the manifest makes the
    # wrong-root upload part of the permanent record.
    case "/$artifact_root/" in
      */"$exp"/*) : ;;
      *) die "--artifact-root '$artifact_root' does not contain the experiment identifier '$exp' as a path segment — refusing to pin another experiment's artifact root into this record (#729); if the root is genuinely correct, rename the record dir or the root so they agree" ;;
    esac
  fi
  [ -z "$repro_diff" ] || [ -f "$repro_diff" ] || die "--repro-diff file not found: $repro_diff"

  # ---- preconditions, BEFORE anything is written (invariant 3) ----------------------------------------
  # A missing seam or a missing lister means this close cannot record what it is supposed to record. That is
  # #804's loud gap (exit 3), and under invariant 3 it leaves the record untouched rather than writing
  # paperwork whose ledger line or manifest would be missing: wire it and re-run.
  if [ -z "${EXPERIMENT_LEDGER_EVENT_CMD:-}" ]; then
    gap "EXPERIMENT_LEDGER_EVENT_CMD is unset — NO terminal ledger event could be written for run=$exp outcome=$outcome (terminal; experiment-level, no suffix — #473), so NOTHING was written: every consumer would still read this run as open. Wire the seam per your instance's ledger recipe (the abstract outcome maps onto the recipe's own terminal strings, #376) and re-run; record this line on the close report if you have to write the event by hand"
    return 3
  fi
  if [ "$no_artifacts" = 0 ] && ! command -v rclone >/dev/null 2>&1; then
    gap "rclone is not on PATH — the artifact store '$artifact_root' could not be listed, so NOTHING was written (a manifest must pin an observed, byte-verified listing, never a claim). Install rclone and re-run, or list the store and write ARTIFACT_MANIFEST.md by hand and record this line on the close report"
    return 3
  fi

  # The staging dir lives INSIDE the record dir so the moves below are same-filesystem renames. A hard kill
  # (SIGKILL, the 45-min job cap) skips the EXIT trap, and residue inside the record dir would be staged
  # into the record's PR by log-experiment — so sweep any earlier run's residue first.
  rm -rf "$dir"/.close-record.* 2>/dev/null || true
  TMPDIR_GEN="$(mktemp -d "$dir/.close-record.XXXXXX")" || die "could not create a temp dir inside $dir (the generated files are moved from there into place, so it must be on the same filesystem)"

  local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # ---- ARTIFACT_MANIFEST.md — from an observed, byte-verified listing, or not at all (#232/#331) -------
  if [ "$no_artifacts" = 0 ]; then
    local_artifact_set "${UPLOADED_FROM[@]}"
    [ "${#LOCAL_SIZE[@]}" -gt 0 ] || die "--uploaded-from named no files (${UPLOADED_FROM[*]}) — an empty local set would make every listing 'verified' against nothing; pass the dir(s) whose contents were uploaded, or --no-artifacts if this run stored nothing"
    if ! observe_store "$artifact_root"; then
      # Invariant 2 + 3: no manifest, nothing else written either, and any earlier generated manifest is
      # moved aside so the record stops claiming a verified upload this close could not confirm.
      stale_generated "$dir/ARTIFACT_MANIFEST.md"
      exit 1
    fi
    stage_generated ARTIFACT_MANIFEST.md <<EOF
$GEN_MARKER
# Artifact manifest — $exp

Generated at close from a live listing of the artifact store, byte-verified against the local set this run
uploaded (never from memory of having uploaded).

| field | value |
| --- | --- |
| artifact-store root | \`$artifact_root\` |
| objects | $OBJECTS |
| total bytes | $BYTES |
| listed at (UTC) | $now |
| listing command | \`rclone lsl $artifact_root\` |
| verified against | ${#LOCAL_SIZE[@]} local file(s) under $(printf '`%s` ' "${UPLOADED_FROM[@]}") |
| verification | every uploaded file present at a matching size; nothing unaccounted for; $HASH_MODE |

The heavy artifacts (full rollout JSONL, adapters, raw per-pod driver logs) live in the store above, not in
git (#232) — this manifest is what makes the committed record self-sufficient: it *describes and locates*
them, and records that the upload was verified against the destination re-derived from this experiment's own
identifier rather than from the variable the copy used (#729).

## Largest objects

\`\`\`
$(printf '%s\n' "$LISTING" | sort -k1,1nr | head -n 15)
\`\`\`

## Full listing

\`\`\`
$LISTING
\`\`\`
EOF
  fi

  # ---- REPRODUCTION.md — the #447 fresh-pull reproduction record ----
  local scripts_list
  scripts_list="$( (cd "$dir" && find . -type f \( -name '*.py' -o -name '*.sh' \) 2>/dev/null | LC_ALL=C sort) || true)"
  [ -n "$scripts_list" ] || scripts_list="TODO(close): no committed *.py/*.sh found under this record — the scripts that produced the reported numbers MUST be committed here (#447)"
  local pull_block
  if [ "${#pull_cmds[@]}" -gt 0 ]; then pull_block="$(printf '%s\n' "${pull_cmds[@]}")"
  else pull_block="TODO(close): the exact pull command(s) a fresh reader runs to fetch the inputs from the artifact store"; fi
  local diff_block
  if [ -n "$repro_diff" ]; then
    diff_block="$(cat "$repro_diff")"
    [ -n "$diff_block" ] || diff_block="(empty diff — the regenerated output matched the committed output byte-for-byte)"
  else
    diff_block="TODO(close): paste the ACTUAL diff of regenerated-vs-committed output from the fresh-pull run (#447) — an empty diff is the pass, an unrecorded one is not a gate"
  fi
  stage_generated REPRODUCTION.md <<EOF
$GEN_MARKER
# Reproduction — $exp

The #447 gate: *the committed script reproduces the committed artifact from the documented recipe against a
fresh pull*, which is a strictly stronger claim than "the script ran during the live run". Run after the
close audit's fixes are in, so what reproduces is what lands (#819).

## 1. Pull the inputs (from a clean state — remove local scratch first)

\`\`\`bash
$pull_block
\`\`\`

## 2. Re-run the committed scripts

\`\`\`
$scripts_list
\`\`\`

## 3. Diff regenerated vs committed output

\`\`\`
$diff_block
\`\`\`

Recorded at $now (UTC).
EOF

  # ---- LANDED.md — what this close landed and where ----
  local ledger_line="run=$exp outcome=$outcome (terminal; experiment-level, no suffix — #473)"
  local artifact_cell
  if [ "$no_artifacts" = 1 ]; then artifact_cell='none (no heavy artifacts for this run)'
  else artifact_cell="\`$artifact_root\` ($OBJECTS objects, $BYTES bytes, byte-verified)"; fi
  stage_generated LANDED.md <<EOF
$GEN_MARKER
# Landed — $exp

| what | where |
| --- | --- |
| record dir | \`$exp\` |
| run id | \`$run_id\` |
| artifact-store root | $artifact_cell |
| page source | $([ -n "$page_source" ] && echo "\`$page_source\` — lands in the SAME PR as this record (#819)" || echo 'none (manifest-only close — no [recipes.viewer] in the START.md snapshot)') |
| terminal ledger event | $ledger_line |
| closed at (UTC) | $now |

Landed in ONE \`log-experiment\` call: the record, the page source, and this file are one close, so they are
one gated PR (#819) — not three sequential ones.

\`close_record.sh finalize\` proves THIS file is present and byte-identical at the base ref before the
run-supervision record closes (#821 invariant 4) — so re-running \`paperwork\` after the record landed means
re-landing it, since the regenerated timestamp above is deliberately part of what is compared.
EOF

  # ---- CLOSE_SELF_AUDIT.md — unstarted (#512): verify STATE, not your memory of doing it ----
  stage_generated CLOSE_SELF_AUDIT.md <<EOF
$GEN_MARKER
# Close self-audit — $exp

Re-CHECK by inspection. "I ran the step" ≠ "the state is right". Every box starts ☐ and is resolved to
**☑ PASS** / **☑ N.A. ev: <why>** / **☒ FAIL ev: <what failed>** with evidence, never a bare tick (#512).

- ☐ artifacts listed in the store — ev: $([ "$no_artifacts" = 1 ] && echo 'N.A. (--no-artifacts)' || echo "\`rclone lsl $artifact_root\` → $OBJECTS objects, byte-verified against ${#LOCAL_SIZE[@]} local file(s)")
- ☐ an explicit EXPERIMENT-LEVEL terminal ledger event exists (\`run\` == \`$exp\` exactly, no suffix — #473)
  AND the ledger's folded/latest status is terminal, and is the RIGHT terminal value for \`$outcome\` (#376)
- ☐ no non-terminal event was written after the terminal one (#338)
- ☐ compute gone per the control plane of the DEPLOYING account (never SSH liveness)
- ☐ \`RESULTS.md\` committed + pushed; close audit + responses present (#263)
- ☐ waker + look-again marker cleared
- ☐ run-supervision record closed via \`close_record.sh finalize $run_id <registry-dir> --base-ref <remote>/<base_branch>\`
  (the post-audit finalizer — it fetches that ref and re-proves this close MERGED there before un-gating the reaps below)
- ☐ worktree reaped (\`reap_worktree.sh\`), scratch archived+reaped (\`reap_scratch.sh\`), session reaped
  (\`reap_session.sh\`) — in that order, all gated on the clean close
EOF

  # ---- terminal ledger event, through the instance seam (#473/#376/#338) ----
  # Written BEFORE the generated files are moved into place: LANDED.md states that this event exists, so a
  # seam that fails must leave no paperwork asserting it (invariant 3 + 5).
  $EXPERIMENT_LEDGER_EVENT_CMD "$exp" "$outcome" "$dir" \
    || die "EXPERIMENT_LEDGER_EVENT_CMD failed for $ledger_line — NOTHING was written: the run has no terminal ledger event, so every consumer still reads it as open (#473); fix the seam or write the event per your ledger recipe, then re-run"
  note "terminal ledger event written via EXPERIMENT_LEDGER_EVENT_CMD ($ledger_line)"

  # ---- every check passed: move the paperwork into place (invariant 3) ----
  commit_generated "$dir"
  # --no-artifacts asserts this run stored nothing, so an earlier close's manifest pinning a store is
  # exactly as false as an unbacked one — it does not survive as the record's answer either.
  [ "$no_artifacts" = 1 ] && stale_generated "$dir/ARTIFACT_MANIFEST.md"

  [ "${#WROTE[@]}"  -eq 0 ] || note "wrote: ${WROTE[*]}"
  [ "${#KEPT[@]}"   -eq 0 ] || note "kept (hand-authored): ${KEPT[*]}"
  [ "${#STALED[@]}" -eq 0 ] || note "renamed aside (unbacked by this close): ${STALED[*]}"
  return 0
}

cmd_finalize() {
  local run_id="$1" dir="$2"; shift 2
  local verb="close" base_ref=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --stop)     verb="stop"; shift ;;
      --base-ref) [ "$#" -ge 2 ] || die "--base-ref requires a value"; base_ref="$2"; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [ -d "$dir" ] || die "not a directory: $dir"
  dir="$(cd "$dir" && pwd)"

  # The finalizer runs only once the close is DURABLY LANDED, and "durable" means MERGED — not "the
  # paperwork exists here". Closing the run-supervision record un-gates worktree/scratch/session reaping,
  # and the worktree holds the only local copy of the record, so a local file is exactly the wrong evidence:
  # `paperwork` writes LANDED.md itself, so checking for its presence would only prove that this same script
  # ran a moment ago (#820 round 1, P0). The evidence comes from the FETCHED remote ref the record merges
  # into, and it must be THIS close's paperwork byte-for-byte — a stale LANDED.md from an earlier landing of
  # the same dir would otherwise certify a close that never landed. Same shape, and the same never-default
  # rule, as `launch_record.sh preflight --base-ref` proving the design-stage PR merged before a launch.
  [ -n "$base_ref" ] || die "--base-ref is required — pass the <remote>/<branch> your instance's records merge into (the [github] base_branch of this record's START.md snapshot, e.g. origin/main). This check exists to prove the close actually MERGED before reaping is un-gated, so it can never default to your own branch"
  # A remote-tracking ref, by construction: the proof has to come from the REMOTE (invariant 4), and a local
  # branch name is exactly the evidence that proves nothing — your own branch carries the paperwork you just
  # generated whether or not anything merged.
  [[ "$base_ref" =~ ^([A-Za-z0-9._-]+)/([A-Za-z0-9._/-]+)$ ]] \
    || die "--base-ref '$base_ref' is not in <remote>/<branch> form — the landing proof must come from a remote-tracking ref this finalizer can FETCH (e.g. origin/main), never from a local branch or a bare SHA, which prove only what your own checkout says"
  local remote="${BASH_REMATCH[1]}" branch="${BASH_REMATCH[2]}"

  # Cheapest precondition first: without local paperwork there is nothing this finalizer could certify, and
  # saying so is more useful than a git-resolution error about the same missing close.
  [ -f "$dir/LANDED.md" ] || die "no LANDED.md in $dir — run 'close_record.sh paperwork' and land the record via log-experiment before finalizing: closing the run-supervision record un-gates worktree/scratch/session reaping, so it must never run ahead of the paperwork it certifies"
  local root prefix
  root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" \
    || die "not inside a git checkout: $dir — the close lands as a commit on $base_ref, so a record dir outside git has no landing this finalizer can confirm"
  prefix="$(git -C "$dir" rev-parse --show-prefix)"   # repo-relative, trailing slash (empty at the root)
  [ -n "$prefix" ] || die "record dir is the repo root ($dir) — pass the experiment's own registry dir"
  git -C "$root" remote get-url "$remote" >/dev/null 2>&1 \
    || die "'$remote' (from --base-ref $base_ref) is not a remote of $root — the landing proof is fetched from that remote, so it must be a real one"

  # FETCH, then read the fetched ref (invariant 4). Fetching here rather than telling the caller to is the
  # difference between "this close landed" and "this close landed as far as my last fetch could tell": a
  # stale ref reads exactly like an unlanded close, and the finalizer un-gates reaping.
  # An EXPLICIT refspec, not a bare `git fetch <remote> <branch>`: the bare form only updates the
  # remote-tracking ref as a side effect of the remote's configured fetch refspec, so a checkout with a
  # narrowed/custom refspec would leave the ref this check then reads at whatever it was — the stale-ref
  # case, reached without any way to tell. Fetching straight into the ref makes the thing we verify be the
  # thing we just fetched.
  git -C "$root" fetch --quiet "$remote" "+refs/heads/$branch:refs/remotes/$remote/$branch" \
    || die "could not fetch $branch from $remote — the landing proof has to come from the remote (invariant 4), and an unreachable remote (or a branch that does not exist there) is not evidence of a landing; check the branch name, connectivity and credentials, then re-run"
  local remote_ref="refs/remotes/$remote/$branch"
  git -C "$root" rev-parse --verify --quiet "$remote_ref^{commit}" >/dev/null \
    || die "no $remote_ref after fetching $branch from $remote — is that the branch your records merge into? (a missing ref is not the same as an unlanded close)"
  git -C "$root" rev-parse --verify --quiet "$remote_ref:${prefix%/}" >/dev/null 2>&1 \
    || die "the record dir ${prefix%/} does not exist at $base_ref (fetched just now) — this close has NOT landed, so there is nothing durable for the run-supervision record to certify; land the record (log-experiment, one call for record + page source + LANDED.md) and re-run"
  git -C "$root" cat-file -e "$remote_ref:${prefix}LANDED.md" 2>/dev/null \
    || die "${prefix}LANDED.md is not present at $base_ref (fetched just now) — the record dir landed but this close's paperwork did not, so there is nothing durable to certify; land the close's paperwork and re-run"
  git -C "$root" show "$remote_ref:${prefix}LANDED.md" | cmp -s - "$dir/LANDED.md" \
    || die "${prefix}LANDED.md at $base_ref differs from this working tree's — the landed paperwork is not the paperwork this close produced (a re-run of 'paperwork' after landing, or an earlier close of the same dir still standing in for this one); re-land the record so what is merged is what this close certifies, then re-run"
  note "close landed: ${prefix}LANDED.md matches $base_ref (fetched from $remote)"

  local rsr="$SELF_DIR/run_supervision_record.sh"
  [ -x "$rsr" ] || die "missing/non-executable $rsr — it ships alongside close_record.sh; this install is incomplete"
  "$rsr" "$verb" "$run_id" || die "run_supervision_record.sh $verb $run_id failed — the record is still desired-active; do NOT reap the worktree/scratch/session until it closes cleanly"
  note "run-supervision record $verb: $run_id (reap order next: worktree → scratch → session)"
}

[ "$#" -ge 1 ] || usage
VERB="$1"; shift
case "$VERB" in
  paperwork) [ "$#" -ge 2 ] || usage; cmd_paperwork "$@" ;;
  finalize)  [ "$#" -ge 2 ] || usage; cmd_finalize  "$@" ;;
  *) usage ;;
esac
