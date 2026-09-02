#!/usr/bin/env bash
# close_record.sh — emit run-experiment's MECHANICAL close paperwork from state, not prose (#819).
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
#                           derived from an ACTUAL listing of the store (never a claim it did not observe)
#   REPRODUCTION.md       — the #447 fresh-pull reproduction record: the documented pull commands, the
#                           committed scripts, and the verbatim diff output the gate produced
#   CLOSE_SELF_AUDIT.md   — the close self-audit checklist, UNSTARTED (☐), with the derived evidence hints
#
# Fail-closed rules this script encodes, each from a real incident:
#   - #473: the terminal ledger event's `run` field is the REGISTRY DIR NAME exactly (no suffix) — derived
#     here from the dir, never from the run-id, which is frequently a different string.
#   - #376: the terminal status is an OPERATIONAL outcome (completed-as-designed / technical-failure /
#     deliberate-abandon). This script refuses to invent one and refuses to map it onto an instance's
#     concrete ledger strings — that mapping is the instance's ledger recipe, reached through the
#     EXPERIMENT_LEDGER_EVENT_CMD seam.
#   - #338: only ever a TERMINAL event. Nothing here can emit a running/launched/deploying status.
#   - #729: an artifact root that does not carry this experiment's own identifier as a path segment is
#     REFUSED — a pulled driver stack's un-renamed path literal pointing at a SIBLING's root is exactly how
#     41 objects of a closed record were permanently lost, and a manifest that pins the sibling's root is
#     that incident written into the permanent record.
#   - #331: a manifest never claims an upload it did not observe. If the store cannot be listed — or lists
#     clean and comes back EMPTY, which is evidence against the upload, not for it — no ARTIFACT_MANIFEST.md
#     is written at all; a hollow manifest is worse than none.
#   - #804: a missing instance seam is LOUD (exit 3 + a `CLOSE-RECORD-GAP:` line for the close record),
#     never a quiet no-op — seven consecutive closes reaped nothing because a no-op said so only on stdout
#     and exited 0.
#   - #512: the emitted checklist is UNSTARTED (every box ☐). Pre-ticked gates are how a copied checklist
#     silently satisfies gates nobody ran.
#
# Usage:
#   close_record.sh paperwork <run-id> <registry-dir> --outcome <abstract-outcome>
#                   (--artifact-root <rclone-dest> | --no-artifacts)
#                   [--page-source <path>] [--pull-cmd <cmd>]... [--repro-diff <file>]
#   close_record.sh finalize  <run-id> <registry-dir> --base-ref <ref> [--stop]
#
#   paperwork  runs BEFORE the TEMP.md delete + staging, so its output lands with the record.
#   finalize   is the POST-AUDIT finalizer (ordering is load-bearing — see SKILL.md): it proves the
#              paperwork above actually MERGED at --base-ref, then closes the run-supervision record via its
#              own helper. It is deliberately a SECOND call: closing the record early would make the relaunch
#              supervisor refuse to recover a run whose compute is still billing.
#
# Instance seam:
#   EXPERIMENT_LEDGER_EVENT_CMD  a command invoked as `<cmd> <run> <abstract-outcome> <registry-dir>` that
#                                writes the instance's own terminal ledger event. Unset => everything else is
#                                still emitted, then exit 3 with a CLOSE-RECORD-GAP: line to copy verbatim
#                                onto the close report and the run's ledger line.
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
                  (--artifact-root <rclone-dest> | --no-artifacts)
                  [--page-source <path>] [--pull-cmd <cmd>]... [--repro-diff <file>]
  close_record.sh finalize  <run-id> <registry-dir> --base-ref <ref-the-record-merges-into> [--stop]
USAGE
  exit 1
}

# write_generated <path> <<'EOF' … : write a generated file, but NEVER clobber one a human/model took
# ownership of. A file we generated carries GEN_MARKER, so regenerating is idempotent; a file without it is
# hand-authored and is left exactly as it is (reported, not overwritten).
write_generated() {
  local path="$1" body; body="$(cat)"
  if [ -e "$path" ] && ! grep -qF "$GEN_MARKER" "$path" 2>/dev/null; then
    note "kept hand-authored $(basename "$path") (no generated-by marker) — not overwritten"
    KEPT+=("$(basename "$path")")
    return 0
  fi
  printf '%s\n' "$body" > "$path"
  WROTE+=("$(basename "$path")")
}

cmd_paperwork() {
  local run_id="$1" dir="$2"; shift 2
  local outcome="" artifact_root="" no_artifacts=0 page_source="" repro_diff=""
  local -a pull_cmds=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --outcome)       [ "$#" -ge 2 ] || die "--outcome requires a value";       outcome="$2"; shift 2 ;;
      --artifact-root) [ "$#" -ge 2 ] || die "--artifact-root requires a value"; artifact_root="$2"; shift 2 ;;
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
  else
    [ -n "$artifact_root" ] || die "one of --artifact-root <rclone-dest> or --no-artifacts is required — a record with heavy artifacts needs the ARTIFACT_MANIFEST.md that pins where they are (#232); an API-only run with nothing in the store says so explicitly"
    # #729: refuse a root that does not carry THIS experiment's identifier. The incident's shape is a
    # sibling's root reached through an un-renamed path literal; pinning it in the manifest makes the
    # wrong-root upload part of the permanent record.
    case "/$artifact_root/" in
      */"$exp"/*) : ;;
      *) die "--artifact-root '$artifact_root' does not contain the experiment identifier '$exp' as a path segment — refusing to pin another experiment's artifact root into this record (#729); if the root is genuinely correct, rename the record dir or the root so they agree" ;;
    esac
  fi

  local -a WROTE=() KEPT=(); local ledger_gap="" artifact_gap=""
  local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # ---- ARTIFACT_MANIFEST.md — from an ACTUAL listing, or not at all (#232/#331) ----
  local objects="" bytes="" listing=""
  if [ "$no_artifacts" = 0 ]; then
    if ! command -v rclone >/dev/null 2>&1; then
      artifact_gap="rclone is not on PATH — no ARTIFACT_MANIFEST.md was written for '$artifact_root' (a manifest must pin an observed listing, never a claim); list the store and write it by hand, or install rclone and re-run"
    elif ! listing="$(rclone lsl "$artifact_root" 2>&1)"; then
      artifact_gap="could not list the artifact store '$artifact_root' (rclone lsl failed: $(printf '%s' "$listing" | head -n1)) — no ARTIFACT_MANIFEST.md was written; a manifest that claims an upload nobody observed is the #331 divergence, so this fails closed"
    elif [ "$(printf '%s\n' "$listing" | grep -c . || true)" = 0 ]; then
      # A listing that SUCCEEDS and comes back empty is not evidence of an upload — it is evidence of the
      # opposite. `--artifact-root` is the caller asserting this run put heavy artifacts in the store, so
      # zero objects means the upload landed somewhere else (the #729 wrong-root shape) or never ran. Writing
      # the manifest anyway would put "objects | 0 … the upload was verified" into the permanent record: the
      # same #331 divergence as an unlistable store, reached through a successful exit code, so it takes the
      # same fail-closed path. A run that genuinely has nothing in the store says so with --no-artifacts.
      artifact_gap="the artifact store '$artifact_root' listed successfully but is EMPTY (0 objects) — no ARTIFACT_MANIFEST.md was written; --artifact-root asserts this run HAS heavy artifacts there, so an empty listing means the upload went somewhere else (the #729 wrong-root shape) or never ran, and a zero-object manifest would record a verified upload nobody observed (#331). Verify the upload against this root and re-run, or pass --no-artifacts if this run genuinely stored nothing"
    else
      objects="$(printf '%s\n' "$listing" | grep -c . || true)"
      bytes="$(printf '%s\n' "$listing" | awk '{s+=$1} END {printf "%d", s+0}')"
      write_generated "$dir/ARTIFACT_MANIFEST.md" <<EOF
$GEN_MARKER
# Artifact manifest — $exp

Generated at close from a live listing of the artifact store (never from memory of having uploaded).

| field | value |
| --- | --- |
| artifact-store root | \`$artifact_root\` |
| objects | $objects |
| total bytes | $bytes |
| listed at (UTC) | $now |
| listing command | \`rclone lsl $artifact_root\` |

The heavy artifacts (full rollout JSONL, adapters, raw per-pod driver logs) live in the store above, not in
git (#232) — this manifest is what makes the committed record self-sufficient: it *describes and locates*
them, and records that the upload was verified against the destination re-derived from this experiment's own
identifier rather than from the variable the copy used (#729).

## Largest objects

\`\`\`
$(printf '%s\n' "$listing" | sort -k1,1nr | head -n 15)
\`\`\`

## Full listing

\`\`\`
$listing
\`\`\`
EOF
    fi
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
    [ -f "$repro_diff" ] || die "--repro-diff file not found: $repro_diff"
    diff_block="$(cat "$repro_diff")"
    [ -n "$diff_block" ] || diff_block="(empty diff — the regenerated output matched the committed output byte-for-byte)"
  else
    diff_block="TODO(close): paste the ACTUAL diff of regenerated-vs-committed output from the fresh-pull run (#447) — an empty diff is the pass, an unrecorded one is not a gate"
  fi
  write_generated "$dir/REPRODUCTION.md" <<EOF
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

  # ---- terminal ledger event, through the instance seam (#473/#376/#338) ----
  local ledger_line="run=$exp outcome=$outcome (terminal; experiment-level, no suffix — #473)"
  if [ -n "${EXPERIMENT_LEDGER_EVENT_CMD:-}" ]; then
    if $EXPERIMENT_LEDGER_EVENT_CMD "$exp" "$outcome" "$dir"; then
      note "terminal ledger event written via EXPERIMENT_LEDGER_EVENT_CMD ($ledger_line)"
    else
      die "EXPERIMENT_LEDGER_EVENT_CMD failed for $ledger_line — the run has NO terminal ledger event, so every consumer still reads it as open (#473); fix the seam or write the event per your ledger recipe, then re-run"
    fi
  else
    ledger_gap="EXPERIMENT_LEDGER_EVENT_CMD is unset — NO terminal ledger event was written for $ledger_line; write it per your instance's ledger recipe (the abstract outcome maps onto the recipe's own terminal strings, #376) and record this line on the close report"
  fi

  # ---- LANDED.md — what this close landed and where ----
  write_generated "$dir/LANDED.md" <<EOF
$GEN_MARKER
# Landed — $exp

| what | where |
| --- | --- |
| record dir | \`$exp\` |
| run id | \`$run_id\` |
| artifact-store root | $([ "$no_artifacts" = 1 ] && echo 'none (no heavy artifacts for this run)' || echo "\`$artifact_root\`${objects:+ ($objects objects)}") |
| page source | $([ -n "$page_source" ] && echo "\`$page_source\` — lands in the SAME PR as this record (#819)" || echo 'none (manifest-only close — no [recipes.viewer] in the START.md snapshot)') |
| terminal ledger event | $ledger_line |
| closed at (UTC) | $now |

Landed in ONE \`log-experiment\` call: the record, the page source, and this file are one close, so they are
one gated PR (#819) — not three sequential ones.
${ledger_gap:+
> **CLOSE-RECORD-GAP:** $ledger_gap
}${artifact_gap:+
> **CLOSE-RECORD-GAP:** $artifact_gap
}
EOF

  # ---- CLOSE_SELF_AUDIT.md — unstarted (#512): verify STATE, not your memory of doing it ----
  write_generated "$dir/CLOSE_SELF_AUDIT.md" <<EOF
$GEN_MARKER
# Close self-audit — $exp

Re-CHECK by inspection. "I ran the step" ≠ "the state is right". Every box starts ☐ and is resolved to
**☑ PASS** / **☑ N.A. ev: <why>** / **☒ FAIL ev: <what failed>** with evidence, never a bare tick (#512).

- ☐ artifacts listed in the store — ev: $([ "$no_artifacts" = 1 ] && echo 'N.A. (--no-artifacts)' || echo "\`rclone lsl $artifact_root\`${objects:+ → $objects objects}")
- ☐ an explicit EXPERIMENT-LEVEL terminal ledger event exists (\`run\` == \`$exp\` exactly, no suffix — #473)
  AND the ledger's folded/latest status is terminal, and is the RIGHT terminal value for \`$outcome\` (#376)
- ☐ no non-terminal event was written after the terminal one (#338)
- ☐ compute gone per the control plane of the DEPLOYING account (never SSH liveness)
- ☐ \`RESULTS.md\` committed + pushed; close audit + responses present (#263)
- ☐ waker + look-again marker cleared
- ☐ run-supervision record closed via \`close_record.sh finalize $run_id <registry-dir> --base-ref origin/<base_branch>\`
  (the post-audit finalizer — it re-proves this close MERGED at that ref before un-gating the reaps below)
- ☐ worktree reaped (\`reap_worktree.sh\`), scratch archived+reaped (\`reap_scratch.sh\`), session reaped
  (\`reap_session.sh\`) — in that order, all gated on the clean close
EOF

  [ "${#WROTE[@]}" -eq 0 ] || note "wrote: ${WROTE[*]}"
  [ "${#KEPT[@]}"  -eq 0 ] || note "kept (hand-authored): ${KEPT[*]}"

  # #804: a missing seam / an unlistable store is LOUD and distinct from a failure — exit 3 means nothing was
  # lost and nothing was faked, the wiring or the evidence is missing. Copy the line onto the close report.
  local rc=0
  [ -n "$ledger_gap" ]   && { gap "$ledger_gap"; rc=3; }
  [ -n "$artifact_gap" ] && { gap "$artifact_gap"; rc=3; }
  return "$rc"
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
  # ran a moment ago (PR #820 review, P0). The evidence has to come from the ref the record merges into, and
  # it has to be THIS close's paperwork byte-for-byte — a stale LANDED.md from an earlier landing of the same
  # dir would otherwise certify a close that never landed. Same shape, and the same never-default rule, as
  # `launch_record.sh preflight --base-ref` proving the design-stage PR merged before a launch.
  [ -n "$base_ref" ] || die "--base-ref is required — pass the ref your instance's records merge into (the [github].base_branch of this record's START.md snapshot, e.g. origin/main). This check exists to prove the close actually MERGED before reaping is un-gated, so it can never default to your own branch; fetch it first (git fetch origin) so the ref is current"
  [ -f "$dir/LANDED.md" ] || die "no LANDED.md in $dir — run 'close_record.sh paperwork' and land the record via log-experiment before finalizing: closing the run-supervision record un-gates worktree/scratch/session reaping, so it must never run ahead of the paperwork it certifies"

  local root prefix
  root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" \
    || die "not inside a git checkout: $dir — the close lands as a commit on $base_ref, so a record dir outside git has no landing this finalizer can confirm"
  prefix="$(git -C "$dir" rev-parse --show-prefix)"   # repo-relative, trailing slash (empty at the root)
  [ -n "$prefix" ] || die "record dir is the repo root ($dir) — pass the experiment's own registry dir"
  git -C "$root" rev-parse --verify --quiet "$base_ref^{commit}" >/dev/null \
    || die "base ref not found: $base_ref (fetch it first — a missing ref is not the same as an unlanded close)"
  git -C "$root" cat-file -e "$base_ref:${prefix}LANDED.md" 2>/dev/null \
    || die "${prefix}LANDED.md is not present at $base_ref — this close has NOT landed, so there is nothing durable for the run-supervision record to certify; land the record (log-experiment, one call for record + page source + LANDED.md) and re-run. If you already landed it, fetch $base_ref first: a stale ref reads exactly like an unlanded close, on purpose"
  git -C "$root" show "$base_ref:${prefix}LANDED.md" | cmp -s - "$dir/LANDED.md" \
    || die "${prefix}LANDED.md at $base_ref differs from this working tree's — the landed paperwork is not the paperwork this close produced (a re-run of 'paperwork' after landing, or an earlier close of the same dir still standing in for this one); re-land the record so what is merged is what this close certifies, then re-run"
  note "close landed: ${prefix}LANDED.md matches $base_ref"

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
