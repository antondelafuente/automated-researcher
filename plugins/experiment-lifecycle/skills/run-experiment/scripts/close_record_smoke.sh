#!/usr/bin/env bash
# close_record_smoke.sh — behavior smoke for close_record.sh (automated-researcher#819, invariants #821).
#
# Covers what syntax/compile checks cannot: the fail-closed rules the close paperwork encodes. Every
# regression PR #820 accumulated has a NAMED case here (#821 invariant 12) — the cases marked `regression:`
# below each FAIL on the pre-fix code:
#   regression: R1 — the finalizer accepted locally generated paperwork as proof of a durable landing
#               (`paperwork` writes LANDED.md itself, so its presence proved only that the generator ran).
#   regression: R2 — a successful but EMPTY store listing produced a manifest claiming a verified upload.
#   regression: R3 — a FAILED re-list left a previously generated manifest in place, still claiming verified.
#   regression: R4 — `rclone lsl 2>&1` merged stderr into the listing, so routine `NOTICE:`/`WARNING:` lines
#               (exit 0) counted as objects: an empty store became "1 object, 2026 bytes" (the date prefix
#               summed as a size) and real listings inflated the same way.
#   regression: A2-1 — the local-set enumeration ran behind a process substitution, so `find`'s exit status
#               was dropped: a traversal that hit an unreadable subdirectory produced a well-formed but SHORT
#               set, and the store was then certified against it as though it were complete (#823 round 5, P0).
#   regression: A2-2 — a listing that repeated a path counted it twice into `objects`/`total bytes` while the
#               verification ran over the distinct paths, so the manifest published a count it never compared.
#   regression: A2-3 — a FAILED `rclone hashsum md5` was recorded as "size-only (the store reported no
#               hashes)": a false statement about the store, indistinguishable from a store that has none.
#   regression: A2-4 — a local copy the box could not hash was silently skipped (`md5sum | cut` dropped the
#               status, the empty result was `continue`d), so a partial hash check read as a complete one.
#   regression: A2-5 — no working md5sum was folded into the same "the store reported no hashes" wording,
#               hiding that the LOCAL side, not the store, is why nothing was hash-checked.
#   regression: A2-6 — REPRODUCTION.md's committed-script list came from a `find … | sort` behind `|| true`,
#               so a half-failed traversal published a reproduction recipe silently missing steps (#447).
#   regression: R5 — the primary skill documented an INVALID close_record invocation (SKILL.md said
#               `close_record.sh <run-id> <registry-dir> …`, which the script rejects as an unknown verb).
#               Closed structurally: the canonical invocations are extracted FROM SKILL.md and run here.
#
# Plus the invariants #821 states, beyond the regressions:
#   - A1: listing = stdout only; a non-zero lister exit is a hard failure; a stdout line that is not in
#     `rclone lsl` shape is never a counted object.
#   - A2: non-empty AND byte-verified, or nothing — a local file absent from the listing, present at a
#     different size, present with a different md5, a listing object no local file explains, or two
#     --uploaded-from legs disagreeing about one path (different size, OR same size and different bytes),
#     each mean NO manifest and a non-zero exit. Plus the completeness rules the two sets themselves are
#     built under (the A2-* cases above): total-or-fatal enumeration, no silent per-file skip, and the set
#     counted equalling the set compared.
#   - A3: atomic write-or-nothing — a failing check (or a failing ledger seam) leaves NO paperwork at all,
#     and an earlier generated manifest is renamed `*.stale` rather than left claiming verified.
#   - A4: `finalize` FETCHES `--base-ref` and proves the landing at the remote-tracking ref; a local branch
#     name is refused outright.
#   - A5: the ledger event goes through the seam keyed on the REGISTRY DIR NAME (#473), never the run-id, and
#     the run-supervision record closes through its own helper (#376/#338).
#   - invariant 11 (the paperwork half): `--page-source-external <url>` is mutually exclusive with
#     `--page-source` and is RECORDED as an external landing — LANDED.md never renders an external viewer as
#     riding this PR, nor as a close whose snapshot carried no `[recipes.viewer]` recipe at all.
#   - #729 (sibling artifact root refused), #512 (the emitted checklist is UNSTARTED), #804 (a missing seam is
#     exit 3 + a `CLOSE-RECORD-GAP:` line, distinct from exit 1).
#
# Hermetic: a stubbed `rclone` backed by a local directory standing in for the store, a stubbed
# run_supervision_record.sh alongside a copy of the script under test, and TWO checkouts of a local
# file-backed `origin` so the finalizer's own fetch is exercised (the landing is pushed from the checkout
# the finalizer is NOT run in, so its remote-tracking ref is stale until it fetches). No network, no real
# store, no real record registry.
#
# Run it directly: `bash close_record_smoke.sh`. Registered in `.aar-ci/checks.sh` next to the other
# run-experiment script smokes, gated on `close_record(_smoke)?\.sh` (or the SKILL.md it extracts the
# canonical invocations from) appearing in the changed paths.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/close_record.sh"
SKILL_MD="$SELF_DIR/../SKILL.md"
[ -f "$SCRIPT" ] || { echo "FAIL: close_record.sh not found next to this smoke" >&2; exit 1; }

fails=0
pass() { echo "  ok: $*" >&2; }
fail() { echo "  SMOKE-FAIL: $*" >&2; fails=1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# A copy of the script under test with a STUB run_supervision_record.sh beside it — close_record.sh resolves
# that helper from its own directory, so this exercises the real resolution path.
mkdir -p "$T/bin"
cp "$SCRIPT" "$T/bin/close_record.sh"; chmod +x "$T/bin/close_record.sh"
cat > "$T/bin/run_supervision_record.sh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$RSR_CALLS"
[ "${RSR_FAIL:-0}" = 1 ] && exit 1
exit 0
STUB
chmod +x "$T/bin/run_supervision_record.sh"
CR="$T/bin/close_record.sh"
export RSR_CALLS="$T/rsr-calls"; : > "$RSR_CALLS"

# Absolute paths to the real tools the stubs below shadow or delegate to, resolved BEFORE $T/stub goes on
# PATH so a stub can still reach the genuine article.
REAL_MD5SUM="$(command -v md5sum)"; export REAL_MD5SUM
REAL_FIND="$(command -v find)";     export REAL_FIND

# Stub rclone, backed by $STORE_DIR (a local dir standing in for the artifact store), so a size/hash
# mismatch or a surplus object is set up by editing files rather than by hand-writing listings.
#   RCLONE_FAIL=1          the lister exits non-zero (unlistable store)
#   RCLONE_NOISY=1         a routine NOTICE on STDERR, exit 0 (what real rclone does constantly)
#   RCLONE_STDOUT_NOISE=1  the same NOTICE on STDOUT (a diagnostic that leaked into the listing channel)
#   RCLONE_DUP=1           the listing repeats its first object line (one path, counted twice)
#   RCLONE_NOHASH=1        `hashsum` FAILS (what a backend with no md5 support does) — distinct from:
#   RCLONE_EMPTYHASH=1     `hashsum` succeeds and reports nothing (a store that genuinely has no hashes)
mkdir -p "$T/stub"
cat > "$T/stub/rclone" <<'STUB'
#!/usr/bin/env bash
verb="${1:-}"
case "$verb" in
  lsl)
    [ "${RCLONE_NOISY:-0}" = 1 ] && echo "2026/09/02 NOTICE: Config file not found - using defaults" >&2
    [ "${RCLONE_STDOUT_NOISE:-0}" = 1 ] && echo "2026/09/02 NOTICE: Config file not found - using defaults"
    [ "${RCLONE_FAIL:-0}" = 1 ] && { echo "ERROR: directory not found" >&2; exit 1; }
    [ -d "${STORE_DIR:-/nonexistent}" ] || exit 0
    first=1
    while IFS=$'\t' read -r -d '' s p; do
      printf '%9d %s %s %s\n' "$s" 2026-08-31 12:00:00.000000000 "$p"
      if [ "${RCLONE_DUP:-0}" = 1 ] && [ "$first" = 1 ]; then
        printf '%9d %s %s %s\n' "$s" 2026-08-31 12:00:00.000000000 "$p"; first=0
      fi
    done < <(cd "$STORE_DIR" && "$REAL_FIND" . -type f -printf '%s\t%P\0')
    exit 0 ;;
  hashsum)
    [ "${RCLONE_NOHASH:-0}" = 1 ] && { echo "ERROR: hash type md5 not supported" >&2; exit 1; }
    [ "${RCLONE_EMPTYHASH:-0}" = 1 ] && exit 0
    [ -d "${STORE_DIR:-/nonexistent}" ] || exit 0
    while IFS= read -r -d '' p; do
      printf '%s  %s\n' "$("$REAL_MD5SUM" "$STORE_DIR/$p" | cut -d' ' -f1)" "$p"
    done < <(cd "$STORE_DIR" && "$REAL_FIND" . -type f -printf '%P\0')
    exit 0 ;;
esac
exit 0
STUB
chmod +x "$T/stub/rclone"

# Stub find: stands in for a traversal that hits an unreadable subdirectory — it emits the records it COULD
# enumerate on stdout and then exits non-zero. That is precisely the shape whose status a process
# substitution swallowed (A2-1): the reader sees a well-formed, SHORT set and cannot tell it from a complete
# one. Armed only for the exact `--uploaded-from` root named in FIND_PARTIAL_ROOT (so the store stub's own
# traversals and the committed-script enumeration pass straight through), and it re-emits close_record.sh's
# own `-printf` format because that is the one call it stands in for.
cat > "$T/stub/find" <<'STUB'
#!/usr/bin/env bash
if [ -n "${FIND_PARTIAL_ROOT:-}" ] && [ "${1:-}" = "$FIND_PARTIAL_ROOT" ]; then
  "$REAL_FIND" "$1" -type f ! -name "${FIND_PARTIAL_SKIP:?}" -printf '%s\t%P\0'
  echo "find: '$1/locked': Permission denied" >&2
  exit 1
fi
if [ -n "${FIND_SCRIPTS_FAIL:-}" ] && [ "${1:-}" = "." ] && [ "$(pwd)" = "$FIND_SCRIPTS_FAIL" ]; then
  echo "find: './locked': Permission denied" >&2
  exit 1
fi
exec "$REAL_FIND" "$@"
STUB
chmod +x "$T/stub/find"

# Stub md5sum: MD5SUM_ABSENT=1 makes the LOCAL hasher unusable (a box without a working md5sum);
# MD5SUM_FAIL_NAME=<name> makes exactly one local file unhashable (unreadable/vanished). Both are per-file
# steps the pre-fix code skipped silently. The store side reaches the real tool through $REAL_MD5SUM.
cat > "$T/stub/md5sum" <<'STUB'
#!/usr/bin/env bash
[ "${MD5SUM_ABSENT:-0}" = 1 ] && { echo "md5sum: not available on this box" >&2; exit 127; }
if [ -n "${MD5SUM_FAIL_NAME:-}" ]; then
  for a in "$@"; do
    case "$a" in *"$MD5SUM_FAIL_NAME") echo "md5sum: $a: Permission denied" >&2; exit 1 ;; esac
  done
fi
exec "$REAL_MD5SUM" "$@"
STUB
chmod +x "$T/stub/md5sum"
export PATH="$T/stub:$PATH"

# A ledger seam that records exactly what it was invoked with.
cat > "$T/stub/ledger.sh" <<'STUB'
#!/usr/bin/env bash
echo "$1|$2|$3" >> "$LEDGER_CALLS"
[ "${LEDGER_FAIL:-0}" = 1 ] && exit 1
exit 0
STUB
chmod +x "$T/stub/ledger.sh"
export LEDGER_CALLS="$T/ledger-calls"; : > "$LEDGER_CALLS"
export EXPERIMENT_LEDGER_EVENT_CMD="$T/stub/ledger.sh"

new_record() {   # new_record <name> -> prints the dir
  local d="$T/registry/$1"
  rm -rf "$d"; mkdir -p "$d/scripts"
  printf 'print(1)\n' > "$d/scripts/aggregate.py"
  printf '# results\n' > "$d/RESULTS.md"
  printf '%s' "$d"
}
# new_upload -> prints a local artifact dir; new_store copies it, so store and local agree by construction.
new_upload() {
  local d="$T/work/upload"
  rm -rf "$d"; mkdir -p "$d/logs"
  printf 'rollout line\n' > "$d/rollouts.jsonl"
  printf 'adapter bytes\n' > "$d/adapter.safetensors"
  printf 'pod stdout\n' > "$d/logs/pod0.log"
  printf '%s' "$d"
}
sync_store() {   # sync_store <upload-dir> : the store holds exactly what was uploaded
  rm -rf "$T/store"; mkdir -p "$T/store"; cp -r "$1/." "$T/store/"
  export STORE_DIR="$T/store"
}
GEN_FILES=(LANDED.md ARTIFACT_MANIFEST.md REPRODUCTION.md CLOSE_SELF_AUDIT.md)
no_paperwork() {  # no_paperwork <dir> : true when the record carries none of the generated files
  local f; for f in "${GEN_FILES[@]}"; do [ -e "$1/$f" ] && return 1; done; return 0
}
no_residue() {    # no_residue <dir> : the staging temp dir never survives a run
  compgen -G "$1/.close-record.*" >/dev/null && return 1 || return 0
}
run() { OUT="$(bash "$CR" "$@" 2>"$T/err")"; RC=$?; ERR="$(cat "$T/err")"; return 0; }

echo "[smoke] close_record.sh" >&2

# ---- 1. arguments: nothing is inferred, nothing half-specified is accepted (#376/#232/#729/#821 A2) ----
D="$(new_record exp-a)"; U="$(new_upload)"; sync_store "$U"
run paperwork run-1 "$D" --no-artifacts
{ [ "$RC" = 1 ] && case "$ERR" in *"--outcome is required"*) true;; *) false;; esac; } \
  && pass "missing --outcome BLOCKs (#376)" || fail "missing --outcome did not BLOCK (rc=$RC: $ERR)"
run paperwork run-1 "$D" --outcome went-great --no-artifacts
{ [ "$RC" = 1 ] && case "$ERR" in *"unknown --outcome"*) true;; *) false;; esac; } \
  && pass "unknown --outcome BLOCKs (#376)" || fail "unknown --outcome did not BLOCK (rc=$RC: $ERR)"
no_paperwork "$D" && pass "a BLOCKed run wrote nothing" || fail "a BLOCKed run wrote paperwork anyway"
run paperwork run-1 "$D" --outcome completed-as-designed --artifact-root "r2:artifacts/exp-b" --uploaded-from "$U"
{ [ "$RC" = 1 ] && case "$ERR" in *"does not contain the experiment identifier"*) true;; *) false;; esac; } \
  && pass "sibling artifact root refused (#729)" || fail "sibling artifact root not refused (rc=$RC: $ERR)"
run paperwork run-1 "$D" --outcome completed-as-designed --artifact-root "r2:artifacts/exp-a" --no-artifacts
{ [ "$RC" = 1 ] && case "$ERR" in *"mutually exclusive"*) true;; *) false;; esac; } \
  && pass "--artifact-root + --no-artifacts refused" || fail "mutually-exclusive flags accepted (rc=$RC)"
run paperwork run-1 "$D" --outcome completed-as-designed
{ [ "$RC" = 1 ] && case "$ERR" in *"--artifact-root"*"--no-artifacts"*) true;; *) false;; esac; } \
  && pass "neither --artifact-root nor --no-artifacts refused (#232)" || fail "artifact source not required (rc=$RC)"
run paperwork run-1 "$D" --outcome completed-as-designed --artifact-root "r2:artifacts/exp-a"
{ [ "$RC" = 1 ] && case "$ERR" in *"needs at least one --uploaded-from"*) true;; *) false;; esac; } \
  && pass "--artifact-root without --uploaded-from refused (nothing to byte-verify against, #821 A2)" \
  || fail "a manifest could be written with no local set to verify against (rc=$RC: $ERR)"
run paperwork run-1 "$D" --outcome completed-as-designed --no-artifacts --uploaded-from "$U"
{ [ "$RC" = 1 ] && case "$ERR" in *"nothing to verify against under --no-artifacts"*) true;; *) false;; esac; } \
  && pass "--no-artifacts + --uploaded-from refused" || fail "contradictory artifact flags accepted (rc=$RC)"

# ---- 2. #804/#821 A3: a missing seam or missing lister is exit 3 AND writes nothing ----
D="$(new_record exp-a)"
(unset EXPERIMENT_LEDGER_EVENT_CMD; bash "$CR" paperwork run-1 "$D" --outcome completed-as-designed --no-artifacts >"$T/out" 2>"$T/err"); RC=$?
OUT="$(cat "$T/out")"; ERR="$(cat "$T/err")"
[ "$RC" = 3 ] && pass "unset ledger seam exits 3 (not 0, not 1)" || fail "unset ledger seam exit was $RC, expected 3"
case "$OUT" in *"CLOSE-RECORD-GAP: EXPERIMENT_LEDGER_EVENT_CMD is unset"*) pass "gap line on stdout, copyable verbatim";;
  *) fail "no CLOSE-RECORD-GAP line on stdout: $OUT";; esac
no_paperwork "$D" \
  && pass "the gap path writes NOTHING — no paperwork asserts a ledger event that was never written (#821 A3)" \
  || fail "the gap path emitted paperwork claiming a terminal event nothing wrote"
D="$(new_record exp-a)"
(PATH="/usr/bin:/bin"; export PATH; bash "$CR" paperwork run-1 "$D" --outcome completed-as-designed \
   --artifact-root "r2:artifacts/exp-a" --uploaded-from "$U" >"$T/out" 2>"$T/err"); RC=$?
OUT="$(cat "$T/out")"
[ "$RC" = 3 ] && pass "no rclone on PATH exits 3 (a gap, not a failure)" || fail "absent rclone exit was $RC, expected 3"
case "$OUT" in *"CLOSE-RECORD-GAP: rclone is not on PATH"*) pass "absent lister reported as a gap";;
  *) fail "absent lister not reported as a gap: $OUT";; esac
no_paperwork "$D" && pass "an unobservable store writes nothing at all" || fail "paperwork written with no listing to back it"

# ---- 3. the happy path: an observed, byte-verified listing ----
: > "$LEDGER_CALLS"
D="$(new_record exp-a)"; U="$(new_upload)"; sync_store "$U"
printf 'no differences\n' > "$T/diff.txt"
run paperwork run-XYZ-different "$D" --outcome completed-as-designed \
    --artifact-root "r2:artifacts/exp-a" --uploaded-from "$U" \
    --page-source "dashboard/exp-a" --pull-cmd 'rclone copy r2:artifacts/exp-a ./pull' --repro-diff "$T/diff.txt"
[ "$RC" = 0 ] && pass "a verified listing exits 0" || fail "verified listing exit was $RC ($OUT / $ERR)"
for f in "${GEN_FILES[@]}"; do
  [ -f "$D/$f" ] && pass "emitted $f" || fail "did not emit $f"
done
no_residue "$D" && pass "no staging residue left in the record dir" || fail "a .close-record.* staging dir survived"
grep -qE '^\| objects \| 3 \|' "$D/ARTIFACT_MANIFEST.md" && pass "manifest pins the observed object count" || fail "manifest object count not derived from the listing"
grep -qF 'md5-verified' "$D/ARTIFACT_MANIFEST.md" && pass "manifest records that the listing was md5-verified" || fail "manifest does not record its verification mode"
grep -qF 'logs/pod0.log' "$D/ARTIFACT_MANIFEST.md" && pass "manifest carries the full listing" || fail "manifest missing listed objects"
grep -qE '^-[[:space:]]*(☑|☒)' "$D/CLOSE_SELF_AUDIT.md" && fail "close self-audit ships PRE-TICKED gates (#512)" || pass "close self-audit is unstarted (#512)"
grep -qF 'rclone copy r2:artifacts/exp-a ./pull' "$D/REPRODUCTION.md" && pass "pull command recorded" || fail "pull command not recorded"
grep -qF 'no differences' "$D/REPRODUCTION.md" && pass "reproduction diff recorded verbatim" || fail "reproduction diff not recorded"
grep -qF 'scripts/aggregate.py' "$D/REPRODUCTION.md" && pass "REPRODUCTION.md lists the committed scripts" || fail "REPRODUCTION.md missed the committed scripts"
grep -qF 'dashboard/exp-a' "$D/LANDED.md" && pass "LANDED.md records the page source riding the same PR" || fail "LANDED.md does not record the page source"
# #473: the ledger event is keyed on the REGISTRY DIR NAME, not the run-id (they differ here on purpose).
grep -qxF "exp-a|completed-as-designed|$D" "$LEDGER_CALLS" \
  && pass "ledger event keyed on the registry dir name + abstract outcome (#473/#376)" \
  || fail "ledger seam got the wrong arguments: $(cat "$LEDGER_CALLS")"
grep -qF 'run-XYZ-different' "$LEDGER_CALLS" && fail "ledger event keyed on the run-id (#473)" || pass "run-id is not the ledger key"
before="$(grep -v 'closed at' "$D/LANDED.md")"
run paperwork run-XYZ-different "$D" --outcome completed-as-designed \
    --artifact-root "r2:artifacts/exp-a" --uploaded-from "$U" \
    --page-source "dashboard/exp-a" --pull-cmd 'rclone copy r2:artifacts/exp-a ./pull' --repro-diff "$T/diff.txt"
[ "$before" = "$(grep -v 'closed at' "$D/LANDED.md")" ] \
  && pass "regeneration is idempotent apart from the close timestamp" || fail "regenerating changed the generated content"

# ---- 3b. #821 invariant 11: an EXTERNAL viewer is recorded as external, never as riding this PR ----
D="$(new_record exp-a)"
run paperwork run-1 "$D" --outcome completed-as-designed \
    --artifact-root "r2:artifacts/exp-a" --uploaded-from "$U" \
    --page-source-external "https://github.com/org/viewer"
[ "$RC" = 0 ] && pass "--page-source-external is accepted on its own (SKILL.md's external-viewer flow has a truthful invocation)" \
  || fail "--page-source-external rejected (rc=$RC: $ERR)"
grep -qF 'https://github.com/org/viewer' "$D/LANDED.md" \
  && pass "LANDED.md records WHERE the external viewer landed" || fail "LANDED.md does not record the external page source"
grep -qF 'SAME PR' "$D/LANDED.md" \
  && fail "LANDED.md claims an EXTERNAL viewer rode this PR (#821 invariant 11)" \
  || pass "LANDED.md does not claim the external viewer rode this PR"
grep -qF 'manifest-only close' "$D/LANDED.md" \
  && fail "LANDED.md records an external-viewer close as having had no [recipes.viewer] recipe at all" \
  || pass "an external-viewer close is not recorded as manifest-only"
grep -qF 'the record, the page source, and this file are one close' "$D/LANDED.md" \
  && fail "the one-close paragraph still folds an EXTERNAL page source into this PR's landing" \
  || pass "the one-close paragraph names the separate external landing instead of claiming it rode this PR"
D="$(new_record exp-a)"
run paperwork run-1 "$D" --outcome completed-as-designed \
    --artifact-root "r2:artifacts/exp-a" --uploaded-from "$U" \
    --page-source "dashboard/exp-a" --page-source-external "https://github.com/org/viewer"
{ [ "$RC" = 1 ] && case "$ERR" in *"mutually exclusive"*) true;; *) false;; esac; } \
  && pass "--page-source + --page-source-external refused, as log-experiment refuses the same pair (#821 invariant 11)" \
  || fail "both page-source flags accepted, so LANDED.md could claim two landings (rc=$RC: $ERR)"
no_paperwork "$D" && pass "the refused flag pair wrote NOTHING (#821 A3)" || fail "paperwork survived a refused flag pair"

# ---- 4. regression R2: a successful but EMPTY listing is evidence AGAINST the upload ----
D="$(new_record exp-a)"
rm -rf "$T/store"; mkdir -p "$T/store"     # lists clean, comes back empty
run paperwork run-1 "$D" --outcome completed-as-designed --artifact-root "r2:artifacts/exp-a" --uploaded-from "$U"
[ "$RC" != 0 ] && pass "regression R2: an empty listing exits non-zero" || fail "regression R2: an empty store listing exited 0"
[ -e "$D/ARTIFACT_MANIFEST.md" ] \
  && fail "regression R2: wrote a ZERO-OBJECT manifest claiming a verified upload for an empty store (#331)" \
  || pass "regression R2: no manifest for an empty store"
case "$ERR" in *"is EMPTY (0 objects)"*) pass "regression R2: one line says which check failed";;
  *) fail "regression R2: empty store not named as the failure: $ERR";; esac
no_paperwork "$D" && pass "regression R2: no other paperwork written either (#821 A3)" || fail "regression R2: partial paperwork survived a failed check"

# ---- 5. regression R4 + A1: rclone's stderr is diagnostics, never listing content ----
D="$(new_record exp-a)"
RCLONE_NOISY=1 run paperwork run-1 "$D" --outcome completed-as-designed --artifact-root "r2:artifacts/exp-a" --uploaded-from "$U"
[ "$RC" != 0 ] && pass "regression R4: a NOISY empty store still fails — stderr is not a listing" || fail "regression R4: a stderr NOTICE laundered an EMPTY store into a verified upload"
[ -e "$D/ARTIFACT_MANIFEST.md" ] && fail "regression R4: a manifest was written for a noisy empty store" || pass "regression R4: no manifest from a noisy empty store"
case "$ERR" in *"is EMPTY (0 objects)"*) pass "regression R4: the noisy empty store takes the EMPTY path, not the observed one";;
  *) fail "regression R4: noisy empty store not reported as EMPTY: $ERR";; esac
case "$ERR" in *"Config file not found"*) pass "the lister's stderr is surfaced verbatim (kept, not parsed)";;
  *) fail "the lister's stderr was swallowed: $ERR";; esac
D="$(new_record exp-a)"; sync_store "$U"
RCLONE_NOISY=1 run paperwork run-1 "$D" --outcome completed-as-designed --artifact-root "r2:artifacts/exp-a" --uploaded-from "$U"
grep -qE '^\| objects \| 3 \|' "$D/ARTIFACT_MANIFEST.md" \
  && pass "regression R4: a stderr NOTICE does not inflate the observed object count" \
  || fail "regression R4: the object count counted a stderr diagnostic line ($(grep -E '^\| objects' "$D/ARTIFACT_MANIFEST.md" || true))"
grep -q 'NOTICE' "$D/ARTIFACT_MANIFEST.md" && fail "regression R4: a stderr diagnostic line was embedded in the manifest" || pass "regression R4: no stderr text in the manifest"
# A1: a diagnostic that leaks onto STDOUT is not a countable object either — it is a hard failure.
D="$(new_record exp-a)"
RCLONE_STDOUT_NOISE=1 run paperwork run-1 "$D" --outcome completed-as-designed --artifact-root "r2:artifacts/exp-a" --uploaded-from "$U"
{ [ "$RC" = 1 ] && case "$ERR" in *"not in 'rclone lsl' shape"*) true;; *) false;; esac; } \
  && pass "A1: an unparseable stdout line is a hard failure, never a counted object" \
  || fail "A1: an unparseable listing line was tolerated (rc=$RC: $ERR)"
[ -e "$D/ARTIFACT_MANIFEST.md" ] && fail "A1: a manifest was written from an unparseable listing" || pass "A1: no manifest from an unparseable listing"
# A1: a non-zero exit from the lister is a hard failure (not a soft skip).
D="$(new_record exp-a)"
RCLONE_FAIL=1 run paperwork run-1 "$D" --outcome completed-as-designed --artifact-root "r2:artifacts/exp-a" --uploaded-from "$U"
{ [ "$RC" = 1 ] && case "$ERR" in *"FAILED (rclone lsl exit 1"*) true;; *) false;; esac; } \
  && pass "A1: a non-zero lister exit is a hard failure" || fail "A1: unlistable store rc=$RC: $ERR"
[ -e "$D/ARTIFACT_MANIFEST.md" ] && fail "A1: wrote a HOLLOW manifest for a store it could not list (#331)" || pass "A1: no hollow manifest (#331)"

# ---- 6. regression R3: a failed re-list must not leave the earlier manifest answering for this close ----
# paperwork is re-runnable, so the real sequence is: a successful listing writes the manifest, then a later
# close finds the store emptied/wrong-rooted. Skipping the write alone left "objects | 3 … the upload was
# verified" standing as the record's answer while the failure line claimed there was no manifest.
D="$(new_record exp-a)"; sync_store "$U"
run paperwork run-1 "$D" --outcome completed-as-designed --artifact-root "r2:artifacts/exp-a" --uploaded-from "$U"
[ -f "$D/ARTIFACT_MANIFEST.md" ] && pass "regression R3: a listed store writes the manifest (the precondition)" || fail "regression R3: no manifest from a good listing: $ERR"
RCLONE_FAIL=1 run paperwork run-1 "$D" --outcome completed-as-designed --artifact-root "r2:artifacts/exp-a" --uploaded-from "$U"
[ -e "$D/ARTIFACT_MANIFEST.md" ] \
  && fail "regression R3: a STALE generated manifest survived, still claiming a verified upload (#331)" \
  || pass "regression R3: the failed re-list leaves no manifest claiming verified"
[ -f "$D/ARTIFACT_MANIFEST.md.stale" ] \
  && pass "regression R3: the earlier manifest is renamed *.stale (kept as evidence, not answering as current)" \
  || fail "regression R3: the earlier manifest was neither kept aside nor removed"
case "$ERR" in *"ARTIFACT_MANIFEST.md.stale"*) pass "regression R3: the rename is reported, not silent";;
  *) fail "regression R3: the stale rename was silent: $ERR";; esac
# --no-artifacts asserts this run stored nothing, so an earlier run's manifest pinning a store is equally false.
D="$(new_record exp-a)"; sync_store "$U"
run paperwork run-1 "$D" --outcome completed-as-designed --artifact-root "r2:artifacts/exp-a" --uploaded-from "$U"
run paperwork run-1 "$D" --outcome completed-as-designed --no-artifacts
[ "$RC" = 0 ] && pass "--no-artifacts re-run exits 0" || fail "--no-artifacts re-run exit was $RC ($ERR)"
[ -e "$D/ARTIFACT_MANIFEST.md" ] \
  && fail "--no-artifacts left a manifest pinning an artifact store the run says it never used" \
  || pass "--no-artifacts moves a stale generated manifest aside"
# A manifest a human took ownership of is never renamed or deleted — the generated-by marker is the rule.
D="$(new_record exp-a)"
printf '# hand-written manifest\n' > "$D/ARTIFACT_MANIFEST.md"
RCLONE_FAIL=1 run paperwork run-1 "$D" --outcome completed-as-designed --artifact-root "r2:artifacts/exp-a" --uploaded-from "$U"
grep -qxF '# hand-written manifest' "$D/ARTIFACT_MANIFEST.md" \
  && pass "a hand-authored manifest is never moved by the failure path" \
  || fail "the failure path moved/deleted a hand-authored ARTIFACT_MANIFEST.md"
D="$(new_record exp-a)"; sync_store "$U"
printf '# my own manifest\n' > "$D/ARTIFACT_MANIFEST.md"
run paperwork run-1 "$D" --outcome completed-as-designed --artifact-root "r2:artifacts/exp-a" --uploaded-from "$U"
grep -qxF '# my own manifest' "$D/ARTIFACT_MANIFEST.md" \
  && pass "hand-authored ARTIFACT_MANIFEST.md left untouched on the success path too" || fail "clobbered a hand-authored file"

# ---- 7. A2: byte verification against the local artifact set ----
D="$(new_record exp-a)"; sync_store "$U"; rm -f "$T/store/adapter.safetensors"
run paperwork run-1 "$D" --outcome completed-as-designed --artifact-root "r2:artifacts/exp-a" --uploaded-from "$U"
{ [ "$RC" = 1 ] && case "$ERR" in *"ABSENT from the listing"*) true;; *) false;; esac; } \
  && pass "A2: an uploaded file absent from the listing BLOCKs" || fail "A2: a missing object was accepted (rc=$RC: $ERR)"
[ -e "$D/ARTIFACT_MANIFEST.md" ] && fail "A2: a manifest was written despite a missing object" || pass "A2: no manifest when an uploaded object is missing"
D="$(new_record exp-a)"; sync_store "$U"; printf 'truncated' > "$T/store/rollouts.jsonl"
run paperwork run-1 "$D" --outcome completed-as-designed --artifact-root "r2:artifacts/exp-a" --uploaded-from "$U"
{ [ "$RC" = 1 ] && case "$ERR" in *"DIFFERENT size"*) true;; *) false;; esac; } \
  && pass "A2: a size mismatch BLOCKs (a truncated upload is not a verified one)" || fail "A2: size mismatch accepted (rc=$RC: $ERR)"
D="$(new_record exp-a)"; sync_store "$U"; printf 'somebody elses object\n' > "$T/store/stranger.bin"
run paperwork run-1 "$D" --outcome completed-as-designed --artifact-root "r2:artifacts/exp-a" --uploaded-from "$U"
{ [ "$RC" = 1 ] && case "$ERR" in *"unaccounted for by the local artifact set"*) true;; *) false;; esac; } \
  && pass "A2: a surplus object is reported, never silently accepted" || fail "A2: surplus object silently accepted (rc=$RC: $ERR)"
# Same size, different bytes: only the hash catches it, and only where the store gives one.
D="$(new_record exp-a)"; sync_store "$U"; printf 'ROLLOUT LINE\n' > "$T/store/rollouts.jsonl"
run paperwork run-1 "$D" --outcome completed-as-designed --artifact-root "r2:artifacts/exp-a" --uploaded-from "$U"
{ [ "$RC" = 1 ] && case "$ERR" in *"DIFFERENT md5"*) true;; *) false;; esac; } \
  && pass "A2: same size + different md5 BLOCKs (a corrupted upload)" || fail "A2: md5 mismatch accepted (rc=$RC: $ERR)"
# (the size-only cases — a failing hash listing, a hashless store, no local hasher — are section 7b's A2-3/A2-5)
# Several --uploaded-from dirs: the completion boundary uploads per artifact-completion (#460).
D="$(new_record exp-a)"; U2="$T/work/upload2"; rm -rf "$U2"; mkdir -p "$U2"
printf 'second leg\n' > "$U2/eval_summary.json"
sync_store "$U"; cp "$U2/eval_summary.json" "$T/store/"
run paperwork run-1 "$D" --outcome completed-as-designed --artifact-root "r2:artifacts/exp-a" --uploaded-from "$U" --uploaded-from "$U2"
[ "$RC" = 0 ] && pass "A2: several --uploaded-from dirs verify as one local set (#460)" || fail "A2: multi-leg upload set rejected (rc=$RC: $ERR)"
# The same rel path in two legs at the SAME SIZE but DIFFERENT BYTES is a disagreement, not an agreement:
# size-only comparison collapsed it into one entry and hashed whichever leg was seen first, so a corrupted
# second leg rode a matching first leg into a "verified" manifest (#823 round 3).
D="$(new_record exp-a)"; U3="$T/work/upload3"; rm -rf "$U3"; mkdir -p "$U3"
printf 'AAAA\n' > "$U/collide.bin"; printf 'BBBB\n' > "$U3/collide.bin"
sync_store "$U"
run paperwork run-1 "$D" --outcome completed-as-designed --artifact-root "r2:artifacts/exp-a" --uploaded-from "$U" --uploaded-from "$U3"
{ [ "$RC" != 0 ] && case "$ERR" in *"disagree about 'collide.bin'"*"DIFFERENT bytes"*) true;; *) false;; esac; } \
  && pass "A2: two legs, same size + different bytes BLOCK and the error names the path" \
  || fail "A2: a same-size/different-byte collision was accepted (rc=$RC: $ERR)"
[ -e "$D/ARTIFACT_MANIFEST.md" ] && fail "A3: a manifest was written despite an ambiguous local artifact set" \
  || pass "A3: no manifest when two legs disagree about a path's bytes"
# Byte-identical copies of the same rel path are NOT a disagreement — the legitimate #460 multi-leg shape
# (two completions uploading the same file) must keep verifying, or the fix above over-blocks.
printf 'AAAA\n' > "$U3/collide.bin"
D="$(new_record exp-a)"; sync_store "$U"
run paperwork run-1 "$D" --outcome completed-as-designed --artifact-root "r2:artifacts/exp-a" --uploaded-from "$U" --uploaded-from "$U3"
[ "$RC" = 0 ] && pass "A2: byte-identical copies of one path across legs still verify (#460 not over-blocked)" \
  || fail "A2: byte-identical multi-leg copies were rejected (rc=$RC: $ERR)"
rm -f "$U/collide.bin"

# ---- 7b. A2's own completeness rules: the two sets are TOTAL OR FATAL, and counted == compared ----------
# Two review rounds landed on this surface (#823 rounds 3 and 5) because the comparison was hardened while
# the CONSTRUCTION of the sets it compares was not. Each case below is one construction hole.

# regression A2-1: a partial enumeration is not a set. `find` emits what it could and exits non-zero; the
# store is trimmed to match that PARTIAL set, so the pre-fix code (status dropped into a process
# substitution) saw local == store and wrote a manifest reporting a VERIFIED upload of a set that had
# silently lost adapter.safetensors.
D="$(new_record exp-a)"; U="$(new_upload)"; sync_store "$U"; rm -f "$T/store/adapter.safetensors"
FIND_PARTIAL_ROOT="$U" FIND_PARTIAL_SKIP='adapter.safetensors' \
  run paperwork run-1 "$D" --outcome completed-as-designed --artifact-root "r2:artifacts/exp-a" --uploaded-from "$U"
{ [ "$RC" != 0 ] && case "$ERR" in *"enumerating --uploaded-from"*"FAILED"*) true;; *) false;; esac; } \
  && pass "regression A2-1: a non-zero find exit while building the local set is FATAL, not a shorter set" \
  || fail "regression A2-1: a partial --uploaded-from enumeration was accepted as the complete uploaded set (rc=$RC: $ERR)"
[ -e "$D/ARTIFACT_MANIFEST.md" ] \
  && fail "regression A2-1: a manifest certified the store against a partially enumerated local set" \
  || pass "regression A2-1: no manifest from a partially enumerated local set"
no_paperwork "$D" && pass "regression A2-1: nothing else was written either (#821 A3)" || fail "regression A2-1: partial paperwork survived"

# regression A2-2: counted == compared. A listing that repeats a path counts it twice into objects/bytes
# while the missing/mismatch/surplus checks run over the DISTINCT paths, so the manifest would publish a
# count (and a byte total) it never compared.
D="$(new_record exp-a)"; sync_store "$U"
RCLONE_DUP=1 run paperwork run-1 "$D" --outcome completed-as-designed --artifact-root "r2:artifacts/exp-a" --uploaded-from "$U"
{ [ "$RC" != 0 ] && case "$ERR" in *"distinct object path"*) true;; *) false;; esac; } \
  && pass "regression A2-2: a repeated listing path BLOCKs — the published count must be the compared set" \
  || fail "regression A2-2: a duplicated listing line inflated objects/bytes past the verified set (rc=$RC: $ERR)"
[ -e "$D/ARTIFACT_MANIFEST.md" ] && fail "regression A2-2: a manifest published a count it never compared" \
  || pass "regression A2-2: no manifest when counted != compared"

# regression A2-3: a FAILED hash listing is not "the store reported no hashes". Sizes matched, so this is
# still a pass — but the manifest has to say WHY nothing was hashed, or the record asserts something about
# the store that this close never observed.
D="$(new_record exp-a)"; sync_store "$U"
RCLONE_NOHASH=1 run paperwork run-1 "$D" --outcome completed-as-designed --artifact-root "r2:artifacts/exp-a" --uploaded-from "$U"
[ "$RC" = 0 ] && pass "A2: a store whose hash listing fails still verifies on sizes (not a failure)" \
  || fail "A2: a failing hash listing was treated as a verification failure (rc=$RC: $ERR)"
grep -qF 'size-only' "$D/ARTIFACT_MANIFEST.md" \
  && pass "A2: the manifest records that only sizes were checked (never overstates the verification)" \
  || fail "A2: a size-only verification is recorded as if hashes matched"
grep -qF 'hashsum md5` exit 1' "$D/ARTIFACT_MANIFEST.md" \
  && pass "regression A2-3: the manifest names the FAILED hash listing as the reason nothing was hashed" \
  || fail "regression A2-3: a failed hash listing is not named ($(grep -F 'verification' "$D/ARTIFACT_MANIFEST.md" || true))"
grep -qF 'the store reported no hashes' "$D/ARTIFACT_MANIFEST.md" \
  && fail "regression A2-3: a FAILED hash listing is recorded as 'the store reported no hashes' — a claim about the store this close never observed" \
  || pass "regression A2-3: a failed hash listing is not laundered into a claim about the store"
# The genuine no-hashes store (hashsum succeeds, reports nothing) keeps its own, different wording.
D="$(new_record exp-a)"; sync_store "$U"
RCLONE_EMPTYHASH=1 run paperwork run-1 "$D" --outcome completed-as-designed --artifact-root "r2:artifacts/exp-a" --uploaded-from "$U"
{ [ "$RC" = 0 ] && grep -qF 'the store reported no hashes' "$D/ARTIFACT_MANIFEST.md"; } \
  && pass "regression A2-3: a store that genuinely reports no hashes still says exactly that" \
  || fail "regression A2-3: a hashless-but-working store lost its own wording (rc=$RC: $ERR)"

# regression A2-4: an unhashable LOCAL copy is a hard failure. The store gave an md5 for it, so this is a
# file the close claims to have uploaded and cannot re-hash — pre-fix, `md5sum | cut` dropped the status and
# the empty result was skipped, so the manifest reported a partial hash check as a complete one.
D="$(new_record exp-a)"; sync_store "$U"
MD5SUM_FAIL_NAME='rollouts.jsonl' \
  run paperwork run-1 "$D" --outcome completed-as-designed --artifact-root "r2:artifacts/exp-a" --uploaded-from "$U"
{ [ "$RC" != 0 ] && case "$ERR" in *"'rollouts.jsonl'"*"could NOT be hashed"*) true;; *) false;; esac; } \
  && pass "regression A2-4: a local copy that cannot be hashed BLOCKs and the error names it" \
  || fail "regression A2-4: an unhashable local copy was silently skipped out of the hash check (rc=$RC: $ERR)"
[ -e "$D/ARTIFACT_MANIFEST.md" ] \
  && fail "regression A2-4: a manifest claimed md5 verification while a local copy went unhashed" \
  || pass "regression A2-4: no manifest when an uploaded file could not be re-hashed"

# regression A2-5: no working md5sum is a LOCAL-side gap, and the manifest must say so rather than reuse the
# store's wording. Sizes matched, so it is still a pass.
D="$(new_record exp-a)"; sync_store "$U"
MD5SUM_ABSENT=1 run paperwork run-1 "$D" --outcome completed-as-designed --artifact-root "r2:artifacts/exp-a" --uploaded-from "$U"
[ "$RC" = 0 ] && pass "A2: a box with no working md5sum still verifies on sizes" \
  || fail "A2: a missing local hasher was treated as a verification failure (rc=$RC: $ERR)"
{ grep -qF 'no working md5sum' "$D/ARTIFACT_MANIFEST.md" \
    && ! grep -qF 'the store reported no hashes' "$D/ARTIFACT_MANIFEST.md"; } \
  && pass "regression A2-5: the manifest names the LOCAL hasher, not the store, as why nothing was hashed" \
  || fail "regression A2-5: a local-side hash gap is recorded as a statement about the store"

# regression A2-6: the committed-script list is a set too. A half-failed traversal must not publish a
# reproduction recipe that silently omits steps (#447).
D="$(new_record exp-a)"; sync_store "$U"
FIND_SCRIPTS_FAIL="$D" \
  run paperwork run-1 "$D" --outcome completed-as-designed --artifact-root "r2:artifacts/exp-a" --uploaded-from "$U"
{ [ "$RC" != 0 ] && case "$ERR" in *"enumerating the committed scripts"*"FAILED"*) true;; *) false;; esac; } \
  && pass "regression A2-6: a non-zero find exit while listing the committed scripts is FATAL" \
  || fail "regression A2-6: a partial committed-script enumeration was published as the reproduction recipe (rc=$RC: $ERR)"
no_paperwork "$D" && pass "regression A2-6: nothing was written (#821 A3)" || fail "regression A2-6: paperwork survived a partial script enumeration"

# ---- 8. A3: a failing ledger seam leaves NO paperwork (write-or-nothing) ----
D="$(new_record exp-a)"; sync_store "$U"
LEDGER_FAIL=1 run paperwork run-1 "$D" --outcome completed-as-designed --artifact-root "r2:artifacts/exp-a" --uploaded-from "$U"
{ [ "$RC" = 1 ] && case "$ERR" in *"EXPERIMENT_LEDGER_EVENT_CMD failed"*) true;; *) false;; esac; } \
  && pass "A3: a failing ledger seam is exit 1, loud (never exit 3)" || fail "A3: failing ledger seam rc=$RC: $ERR"
no_paperwork "$D" && pass "A3: nothing was written — no LANDED.md asserting an event that failed" || fail "A3: paperwork survived a failed ledger write"
no_residue "$D" && pass "A3: the staging dir is cleaned up on the failure path too" || fail "A3: staging residue left behind"

# ---- 9. regression R1 + A4: finalize proves the landing from the FETCHED remote ----
D="$(new_record exp-a)"; sync_store "$U"
: > "$RSR_CALLS"
run finalize run-1 "$D" --base-ref origin/main
{ [ "$RC" = 1 ] && case "$ERR" in *"no LANDED.md"*) true;; *) false;; esac; } \
  && pass "finalize refuses before the paperwork exists" || fail "finalize ran ahead of the paperwork (rc=$RC: $ERR)"
[ -s "$RSR_CALLS" ] && fail "finalize touched the run-supervision record anyway" || pass "record untouched on refusal"

# Two checkouts of one local bare origin: A is the executor's worktree (where finalize runs), B is where the
# landing is pushed from — so A's refs/remotes/origin/main is STALE until finalize fetches it itself (A4).
BARE="$T/origin.git"; A="$T/repoA"; B="$T/repoB"
git init -q --bare "$BARE" && git -C "$BARE" symbolic-ref HEAD refs/heads/main
git init -q "$A" && git -C "$A" symbolic-ref HEAD refs/heads/main
git -C "$A" config user.email smoke@example.invalid; git -C "$A" config user.name smoke
git -C "$A" remote add origin "$BARE"
mkdir -p "$A/registry"; printf 'seed\n' > "$A/registry/.keep"
git -C "$A" add -A >/dev/null && git -C "$A" commit -qm seed && git -C "$A" push -q origin main
git -C "$A" fetch -q origin
git clone -q "$BARE" "$B"
git -C "$B" config user.email smoke@example.invalid; git -C "$B" config user.name smoke

G="$A/registry/exp-a"; mkdir -p "$G/scripts"; printf '# results\n' > "$G/RESULTS.md"
run paperwork run-1 "$G" --outcome completed-as-designed --no-artifacts
[ -f "$G/LANDED.md" ] || fail "paperwork did not emit LANDED.md into the git-backed record"

: > "$RSR_CALLS"
run finalize run-1 "$G"
{ [ "$RC" = 1 ] && case "$ERR" in *"--base-ref is required"*) true;; *) false;; esac; } \
  && pass "finalize requires --base-ref (never defaults to your own branch)" || fail "finalize defaulted the base ref (rc=$RC: $ERR)"
run finalize run-1 "$G" --base-ref main
{ [ "$RC" = 1 ] && case "$ERR" in *"not in <remote>/<branch> form"*) true;; *) false;; esac; } \
  && pass "A4: a LOCAL branch name is refused — the proof must come from a remote" || fail "A4: a local ref was accepted as landing proof (rc=$RC: $ERR)"
run finalize run-1 "$G" --base-ref upstream/main
{ [ "$RC" = 1 ] && case "$ERR" in *"is not a remote of"*) true;; *) false;; esac; } \
  && pass "A4: an unknown remote is refused" || fail "A4: unknown remote accepted (rc=$RC: $ERR)"
run finalize run-1 "$G" --base-ref origin/main
{ [ "$RC" = 1 ] && case "$ERR" in *"has NOT landed"*|*"does not exist at"*) true;; *) false;; esac; } \
  && pass "regression R1: locally-generated LANDED.md is NOT accepted as proof of a landing" \
  || fail "regression R1: finalize accepted its own generated paperwork as a durable landing (rc=$RC: $ERR)"
[ -s "$RSR_CALLS" ] && fail "regression R1: an unlanded close still closed the record" || pass "regression R1: an unlanded close leaves reaping gated"
run finalize run-1 "$G" --base-ref origin/nope
{ [ "$RC" = 1 ] && case "$ERR" in *"could not fetch"*|*"no refs/remotes/origin/nope"*) true;; *) false;; esac; } \
  && pass "a missing base branch is distinct from an unlanded close" || fail "missing base ref rc=$RC: $ERR"

# Land it the way log-experiment does — from the OTHER checkout, so A's tracking ref stays stale.
mkdir -p "$B/registry/exp-a"; cp -r "$G/." "$B/registry/exp-a/"
git -C "$B" add registry/exp-a >/dev/null && git -C "$B" commit -qm 'log exp-a' && git -C "$B" push -q origin main
git -C "$A" rev-parse --verify --quiet "origin/main:registry/exp-a/LANDED.md" >/dev/null \
  && fail "the fixture's stale-ref premise is broken (A already sees the landing without fetching)" \
  || pass "A4 premise: the executor's checkout cannot see the landing until it fetches"
: > "$RSR_CALLS"
run finalize run-1 "$G" --base-ref origin/main
[ "$RC" = 0 ] \
  && pass "A4: finalize FETCHES the base ref itself and confirms the landing (a stale ref is not an answer)" \
  || fail "A4: finalize failed against a landed-but-not-yet-fetched close (rc=$RC: $ERR)"
grep -qxF "close run-1" "$RSR_CALLS" && pass "A5: finalize closes the run-supervision record through its helper" || fail "A5: record close not delegated: $(cat "$RSR_CALLS")"

# Byte-equality, not mere presence: a landed-but-different LANDED.md is a stale landing standing in for this one.
cp "$G/LANDED.md" "$T/landed.bak"
printf 'drifted after landing\n' >> "$G/LANDED.md"
: > "$RSR_CALLS"
run finalize run-1 "$G" --base-ref origin/main
{ [ "$RC" = 1 ] && case "$ERR" in *"differs from this working tree"*) true;; *) false;; esac; } \
  && pass "a landed LANDED.md that differs from this close's is refused" || fail "stale landing accepted (rc=$RC: $ERR)"
[ -s "$RSR_CALLS" ] && fail "a stale landing still closed the record" || pass "a stale landing leaves reaping gated"
cp "$T/landed.bak" "$G/LANDED.md"

# A record dir outside git has no landing to confirm — it fails closed rather than falling back to presence.
D="$(new_record exp-a)"
run paperwork run-1 "$D" --outcome completed-as-designed --no-artifacts
run finalize run-1 "$D" --base-ref origin/main
{ [ "$RC" = 1 ] && case "$ERR" in *"not inside a git checkout"*) true;; *) false;; esac; } \
  && pass "a non-git record dir fails closed" || fail "non-git record dir rc=$RC: $ERR"

: > "$RSR_CALLS"
run finalize run-1 "$G" --base-ref origin/main --stop
grep -qxF "stop run-1" "$RSR_CALLS" && pass "--stop maps to the record's stop verb" || fail "--stop not delegated: $(cat "$RSR_CALLS")"
: > "$RSR_CALLS"
RSR_FAIL=1 run finalize run-1 "$G" --base-ref origin/main
{ [ "$RC" = 1 ] && case "$ERR" in *"still desired-active"*) true;; *) false;; esac; } \
  && pass "a failed record close is loud (reaping stays gated)" || fail "failed record close swallowed (rc=$RC: $ERR)"

# ---- 10. regression R5 + A6: the canonical invocations documented in SKILL.md are the ones that RUN ----
# The round-1 finding was a SKILL.md that documented `close_record.sh <run-id> <registry-dir> …` — an
# invocation the script rejects as an unknown verb. Prose and code cannot drift here anymore: the blocks are
# extracted from SKILL.md and executed verbatim, with only `scripts/close_record.sh` repointed at the copy
# under test. A SKILL.md whose canonical block the script rejects fails this smoke.
extract_block() {   # extract_block <marker> <file>
  sed -n "/$1:BEGIN/,/$1:END/p" "$2" | sed -e "/$1:BEGIN/d" -e "/$1:END/d" -e '/^[[:space:]]*```/d'
}
if [ -f "$SKILL_MD" ]; then
  PW_BLOCK="$(extract_block CLOSE-RECORD-PAPERWORK "$SKILL_MD")"
  FI_BLOCK="$(extract_block CLOSE-RECORD-FINALIZE "$SKILL_MD")"
  [ -n "$PW_BLOCK" ] && pass "A6: SKILL.md carries a marked canonical paperwork invocation" || fail "A6: no canonical paperwork block in SKILL.md"
  [ -n "$FI_BLOCK" ] && pass "A6: SKILL.md carries a marked canonical finalize invocation" || fail "A6: no canonical finalize block in SKILL.md"
  G2="$A/registry/exp-canon"; mkdir -p "$G2/scripts"; printf '# results\n' > "$G2/RESULTS.md"
  printf 'print(2)\n' > "$G2/scripts/aggregate.py"
  U3="$T/work/upload-canon"; rm -rf "$U3"; mkdir -p "$U3"; printf 'canon rollouts\n' > "$U3/rollouts.jsonl"
  sync_store "$U3"
  export RUN_ID=run-canon REGISTRY_DIR="$G2" ARTIFACT_ROOT="r2:artifacts/exp-canon" UPLOAD_DIR="$U3" \
         PAGE_SOURCE="dashboard/exp-canon" REPRO_DIFF="$T/diff.txt" BASE_REF=origin/main
  if bash -c "${PW_BLOCK//scripts\/close_record.sh/$CR}" >"$T/out" 2>"$T/err"; then
    pass "A6/R5: SKILL.md's canonical paperwork invocation runs as documented"
    [ -f "$G2/LANDED.md" ] && [ -f "$G2/ARTIFACT_MANIFEST.md" ] \
      && pass "A6: it produces the paperwork the skill says it does" || fail "A6: the canonical invocation wrote no paperwork"
  else
    fail "A6/R5: SKILL.md's canonical paperwork invocation FAILED: $(cat "$T/err")"
  fi
  # The finalize block, before and after the landing: refused, then accepted.
  : > "$RSR_CALLS"
  if bash -c "${FI_BLOCK//scripts\/close_record.sh/$CR}" >/dev/null 2>&1; then
    fail "A6: the canonical finalize invocation certified an unlanded close"
  else
    pass "A6: the canonical finalize invocation refuses an unlanded close"
  fi
  mkdir -p "$B/registry/exp-canon"; cp -r "$G2/." "$B/registry/exp-canon/"
  git -C "$B" add registry/exp-canon >/dev/null && git -C "$B" commit -qm 'log exp-canon' && git -C "$B" push -q origin main
  if bash -c "${FI_BLOCK//scripts\/close_record.sh/$CR}" >"$T/out" 2>"$T/err"; then
    grep -qxF "close $RUN_ID" "$RSR_CALLS" \
      && pass "A6: the canonical finalize invocation closes the record once the close is landed" \
      || fail "A6: canonical finalize exited 0 without closing the record: $(cat "$RSR_CALLS")"
  else
    fail "A6: SKILL.md's canonical finalize invocation FAILED on a landed close: $(cat "$T/err")"
  fi
else
  fail "A6: run-experiment/SKILL.md not found at $SKILL_MD — the canonical invocations cannot be verified"
fi

[ "$fails" = 0 ] && echo "[smoke] close_record.sh: PASS" >&2 || echo "[smoke] close_record.sh: FAIL" >&2
exit "$fails"
