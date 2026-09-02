#!/usr/bin/env bash
# close_record_smoke.sh — behavior smoke for close_record.sh (automated-researcher#819).
#
# Covers what syntax/compile checks cannot: the fail-closed rules the close paperwork encodes.
#   - #376: an absent/unknown abstract outcome BLOCKs; the script never invents a terminal status.
#   - #473: the ledger event's `run` field is the REGISTRY DIR NAME, not the run-id (they differ here on
#     purpose — a run-id-keyed event is exactly the suffix/aliasing bug that rendered a completed
#     experiment `failed` on a downstream dashboard).
#   - #729: an artifact root carrying a SIBLING's identifier is refused before anything is written.
#   - #331/#232: a store that cannot be listed — or that lists clean and comes back EMPTY — produces NO
#     ARTIFACT_MANIFEST.md at all (never a hollow one, and never a zero-object "verified upload").
#   - #804: a missing seam is exit 3 + a CLOSE-RECORD-GAP: line on stdout, distinct from exit 1 (a real
#     failure), with everything else still emitted.
#   - #512: the emitted close self-audit checklist is UNSTARTED (no ☑/☒ gate lines).
#   - the finalizer's ordering guard: the close must be MERGED at --base-ref (present AND byte-identical)
#     before the run-supervision record closes — locally-generated paperwork is never its own landing proof.
#   - hand-authored files (no generated-by marker) are never clobbered; generated ones regenerate idempotently.
#
# Hermetic: a stubbed `rclone`, a stubbed run_supervision_record.sh alongside a copy of the script under
# test, and a local file-backed `origin` for the finalizer's merged-proof. No network, no real store, no
# real record registry.
#
# Run it directly: `bash close_record_smoke.sh`. Registering it in `.aar-ci/checks.sh` next to the other
# run-experiment script smokes (run_supervision_record / reap_session / session_janitor — same guard shape,
# gated on `close_record(_smoke)?\.sh` appearing in the changed paths) is deliberately left for a human
# pass: that file is the pipeline's trust boundary and an automated implementor run does not edit it.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/close_record.sh"
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

# Stub rclone: `lsl <dest>` prints a fixed listing, fails (exit 1) when RCLONE_FAIL=1, or succeeds with an
# EMPTY listing when RCLONE_EMPTY=1 — the "clean exit, nothing there" case a manifest must never launder.
mkdir -p "$T/stub"
cat > "$T/stub/rclone" <<'STUB'
#!/usr/bin/env bash
[ "${RCLONE_FAIL:-0}" = 1 ] && { echo "Listing error: directory not found" >&2; exit 1; }
[ "${RCLONE_EMPTY:-0}" = 1 ] && exit 0
if [ "$1" = "lsl" ]; then
  printf '%8d %s %s\n' 100 2026-08-31 'rollouts.jsonl'
  printf '%8d %s %s\n' 250 2026-08-31 'adapter.safetensors'
  exit 0
fi
exit 0
STUB
chmod +x "$T/stub/rclone"
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

new_record() {   # new_record <name> -> prints the dir
  local d="$T/registry/$1"
  rm -rf "$d"; mkdir -p "$d/scripts"
  printf 'print(1)\n' > "$d/scripts/aggregate.py"
  printf '# results\n' > "$d/RESULTS.md"
  printf '%s' "$d"
}
run() { OUT="$(bash "$CR" "$@" 2>"$T/err")"; RC=$?; ERR="$(cat "$T/err")"; return 0; }

echo "[smoke] close_record.sh" >&2

# ---- 1. --outcome is required and validated (#376) ----
D="$(new_record exp-a)"
run paperwork run-1 "$D" --no-artifacts
{ [ "$RC" = 1 ] && case "$ERR" in *"--outcome is required"*) true;; *) false;; esac; } \
  && pass "missing --outcome BLOCKs (#376)" || fail "missing --outcome did not BLOCK (rc=$RC: $ERR)"
run paperwork run-1 "$D" --outcome went-great --no-artifacts
{ [ "$RC" = 1 ] && case "$ERR" in *"unknown --outcome"*) true;; *) false;; esac; } \
  && pass "unknown --outcome BLOCKs (#376)" || fail "unknown --outcome did not BLOCK (rc=$RC: $ERR)"
[ -e "$D/LANDED.md" ] && fail "a BLOCKed run wrote LANDED.md anyway" || pass "a BLOCKed run wrote nothing"

# ---- 2. artifact root must carry THIS experiment's identifier (#729) ----
run paperwork run-1 "$D" --outcome completed-as-designed --artifact-root "r2:artifacts/exp-b"
{ [ "$RC" = 1 ] && case "$ERR" in *"does not contain the experiment identifier"*) true;; *) false;; esac; } \
  && pass "sibling artifact root refused (#729)" || fail "sibling artifact root not refused (rc=$RC: $ERR)"
run paperwork run-1 "$D" --outcome completed-as-designed --artifact-root "r2:artifacts/exp-a" --no-artifacts
{ [ "$RC" = 1 ] && case "$ERR" in *"mutually exclusive"*) true;; *) false;; esac; } \
  && pass "--artifact-root + --no-artifacts refused" || fail "mutually-exclusive flags accepted (rc=$RC)"
run paperwork run-1 "$D" --outcome completed-as-designed
{ [ "$RC" = 1 ] && case "$ERR" in *"--artifact-root"*"--no-artifacts"*) true;; *) false;; esac; } \
  && pass "neither --artifact-root nor --no-artifacts refused (#232)" || fail "artifact source not required (rc=$RC)"

# ---- 3. unset ledger seam: everything emitted, exit 3 + CLOSE-RECORD-GAP (#804) ----
unset EXPERIMENT_LEDGER_EVENT_CMD
D="$(new_record exp-a)"
run paperwork run-1 "$D" --outcome completed-as-designed --artifact-root "r2:artifacts/exp-a"
[ "$RC" = 3 ] && pass "unset ledger seam exits 3 (not 0, not 1)" || fail "unset ledger seam exit was $RC, expected 3"
case "$OUT" in *"CLOSE-RECORD-GAP: EXPERIMENT_LEDGER_EVENT_CMD is unset"*) pass "gap line on stdout, copyable verbatim";;
  *) fail "no CLOSE-RECORD-GAP line on stdout: $OUT";; esac
for f in LANDED.md ARTIFACT_MANIFEST.md REPRODUCTION.md CLOSE_SELF_AUDIT.md; do
  [ -f "$D/$f" ] && pass "emitted $f" || fail "did not emit $f"
done
grep -qF "CLOSE-RECORD-GAP" "$D/LANDED.md" && pass "LANDED.md carries the gap verbatim" || fail "LANDED.md hides the gap"
grep -qE '^\| objects \| 2 \|' "$D/ARTIFACT_MANIFEST.md" && pass "manifest pins the observed object count" || fail "manifest object count not derived from the listing"
grep -qF '350' "$D/ARTIFACT_MANIFEST.md" && pass "manifest pins total bytes from the listing" || fail "manifest total bytes not derived"
grep -qE '^-[[:space:]]*(☑|☒)' "$D/CLOSE_SELF_AUDIT.md" && fail "close self-audit ships PRE-TICKED gates (#512)" || pass "close self-audit is unstarted (#512)"
grep -qF 'TODO(close):' "$D/REPRODUCTION.md" && pass "REPRODUCTION.md marks what it could not derive as TODO(close)" || fail "REPRODUCTION.md invented the undeliverable parts"
grep -qF 'scripts/aggregate.py' "$D/REPRODUCTION.md" && pass "REPRODUCTION.md lists the committed scripts" || fail "REPRODUCTION.md missed the committed scripts"

# ---- 4. unlistable store: NO manifest at all, gap recorded (#331) ----
D="$(new_record exp-a)"
RCLONE_FAIL=1 run paperwork run-1 "$D" --outcome completed-as-designed --artifact-root "r2:artifacts/exp-a"
[ "$RC" = 3 ] && pass "unlistable store exits 3" || fail "unlistable store exit was $RC, expected 3"
[ -e "$D/ARTIFACT_MANIFEST.md" ] && fail "wrote a HOLLOW manifest for a store it could not list (#331)" || pass "no hollow manifest written (#331)"
case "$OUT" in *"CLOSE-RECORD-GAP: could not list the artifact store"*) pass "unlistable store reported as a gap";;
  *) fail "unlistable store not reported: $OUT";; esac
[ -f "$D/LANDED.md" ] && pass "the rest of the paperwork still emitted" || fail "an artifact gap suppressed the other emissions"

# ---- 4b. store lists CLEAN but EMPTY: still no manifest — a successful exit is not an observed upload ----
D="$(new_record exp-a)"
RCLONE_EMPTY=1 run paperwork run-1 "$D" --outcome completed-as-designed --artifact-root "r2:artifacts/exp-a"
[ "$RC" = 3 ] && pass "an empty store listing exits 3 (the gap path, not success)" || fail "empty listing exit was $RC, expected 3"
[ -e "$D/ARTIFACT_MANIFEST.md" ] \
  && fail "wrote a ZERO-OBJECT manifest claiming a verified upload for an empty store (#331)" \
  || pass "no zero-object manifest for an empty store (#331)"
case "$OUT" in *"CLOSE-RECORD-GAP: the artifact store"*"is EMPTY"*) pass "empty store reported as a gap";;
  *) fail "empty store not reported as a gap: $OUT";; esac
grep -qF 'CLOSE-RECORD-GAP' "$D/LANDED.md" && pass "LANDED.md carries the empty-store gap" || fail "LANDED.md hides the empty-store gap"

# ---- 5. ledger seam wired: invoked with the REGISTRY DIR NAME, not the run-id (#473) ----
: > "$LEDGER_CALLS"
D="$(new_record exp-a)"
EXPERIMENT_LEDGER_EVENT_CMD="$T/stub/ledger.sh" run paperwork run-XYZ-different "$D" --outcome technical-failure --no-artifacts
[ "$RC" = 0 ] && pass "wired seam exits 0" || fail "wired seam exit was $RC, expected 0 ($OUT / $ERR)"
grep -qxF "exp-a|technical-failure|$D" "$LEDGER_CALLS" \
  && pass "ledger event keyed on the registry dir name + abstract outcome (#473/#376)" \
  || fail "ledger seam got the wrong arguments: $(cat "$LEDGER_CALLS")"
grep -qF 'run-XYZ-different' "$LEDGER_CALLS" && fail "ledger event keyed on the run-id (#473)" || pass "run-id is not the ledger key"

# ---- 6. a failing ledger seam is exit 1 (a real failure), never exit 3 ----
D="$(new_record exp-a)"
LEDGER_FAIL=1 EXPERIMENT_LEDGER_EVENT_CMD="$T/stub/ledger.sh" run paperwork run-1 "$D" --outcome completed-as-designed --no-artifacts
{ [ "$RC" = 1 ] && case "$ERR" in *"EXPERIMENT_LEDGER_EVENT_CMD failed"*) true;; *) false;; esac; } \
  && pass "a failing ledger seam is exit 1, loud (never exit 3)" || fail "failing ledger seam rc=$RC: $ERR"

# ---- 7. hand-authored files are never clobbered; generated ones regenerate ----
D="$(new_record exp-a)"
printf '# my own manifest\n' > "$D/ARTIFACT_MANIFEST.md"
run paperwork run-1 "$D" --outcome completed-as-designed --artifact-root "r2:artifacts/exp-a"
grep -qxF '# my own manifest' "$D/ARTIFACT_MANIFEST.md" \
  && pass "hand-authored ARTIFACT_MANIFEST.md left untouched" || fail "clobbered a hand-authored file"
before="$(grep -v 'closed at' "$D/LANDED.md")"
run paperwork run-1 "$D" --outcome completed-as-designed --artifact-root "r2:artifacts/exp-a"
[ "$before" = "$(grep -v 'closed at' "$D/LANDED.md")" ] \
  && pass "regeneration is idempotent" || fail "regenerating changed the generated content"

# ---- 8. --repro-diff / --pull-cmd are recorded verbatim ----
D="$(new_record exp-a)"
printf 'ROW 3 differs: 0.41 vs 0.44\n' > "$T/diff.txt"
run paperwork run-1 "$D" --outcome completed-as-designed --no-artifacts \
    --pull-cmd 'rclone copy r2:artifacts/exp-a ./pull' --repro-diff "$T/diff.txt"
grep -qF 'ROW 3 differs: 0.41 vs 0.44' "$D/REPRODUCTION.md" && pass "reproduction diff recorded verbatim" || fail "reproduction diff not recorded"
grep -qF 'rclone copy r2:artifacts/exp-a ./pull' "$D/REPRODUCTION.md" && pass "pull command recorded" || fail "pull command not recorded"

# ---- 9. finalize: the close must be MERGED at --base-ref before the run-supervision record closes ----
# `paperwork` writes LANDED.md itself, so its presence in the working tree proves only that the generator
# ran. The evidence has to come from the ref the record merges into — modelled here with a real checkout
# pushing to a real (local, file-backed) `origin`, so the git path under test is the production one.
D="$(new_record exp-a)"
: > "$RSR_CALLS"
run finalize run-1 "$D" --base-ref origin/main
{ [ "$RC" = 1 ] && case "$ERR" in *"no LANDED.md"*) true;; *) false;; esac; } \
  && pass "finalize refuses before the paperwork exists" || fail "finalize ran ahead of the paperwork (rc=$RC: $ERR)"
[ -s "$RSR_CALLS" ] && fail "finalize touched the run-supervision record anyway" || pass "record untouched on refusal"

BARE="$T/origin.git"; REPO="$T/repo"
git init -q --bare "$BARE"
git init -q "$REPO" && git -C "$REPO" symbolic-ref HEAD refs/heads/main
git -C "$REPO" config user.email smoke@example.invalid; git -C "$REPO" config user.name smoke
git -C "$REPO" remote add origin "$BARE"
mkdir -p "$REPO/registry"; printf 'seed\n' > "$REPO/registry/.keep"
git -C "$REPO" add -A >/dev/null && git -C "$REPO" commit -qm seed && git -C "$REPO" push -q origin main
git -C "$REPO" fetch -q origin

G="$REPO/registry/exp-a"; mkdir -p "$G/scripts"; printf '# results\n' > "$G/RESULTS.md"
EXPERIMENT_LEDGER_EVENT_CMD="$T/stub/ledger.sh" run paperwork run-1 "$G" --outcome completed-as-designed --no-artifacts
[ -f "$G/LANDED.md" ] || fail "paperwork did not emit LANDED.md into the git-backed record"

: > "$RSR_CALLS"
run finalize run-1 "$G"
{ [ "$RC" = 1 ] && case "$ERR" in *"--base-ref is required"*) true;; *) false;; esac; } \
  && pass "finalize requires --base-ref (never defaults to your own branch)" || fail "finalize defaulted the base ref (rc=$RC: $ERR)"
run finalize run-1 "$G" --base-ref origin/main
{ [ "$RC" = 1 ] && case "$ERR" in *"has NOT landed"*) true;; *) false;; esac; } \
  && pass "locally-generated LANDED.md is NOT accepted as proof of a landing" \
  || fail "finalize accepted its own generated paperwork as a durable landing (rc=$RC: $ERR)"
[ -s "$RSR_CALLS" ] && fail "an unlanded close still closed the record" || pass "an unlanded close leaves reaping gated"
run finalize run-1 "$G" --base-ref origin/nope
{ [ "$RC" = 1 ] && case "$ERR" in *"base ref not found"*) true;; *) false;; esac; } \
  && pass "a missing base ref is distinct from an unlanded close" || fail "missing base ref rc=$RC: $ERR"

# Land it the way log-experiment does: commit the record onto the base branch and merge it.
git -C "$REPO" add registry/exp-a >/dev/null && git -C "$REPO" commit -qm 'log exp-a' && git -C "$REPO" push -q origin main
git -C "$REPO" fetch -q origin
: > "$RSR_CALLS"
run finalize run-1 "$G" --base-ref origin/main
[ "$RC" = 0 ] && pass "finalize exits 0 once the close is merged at the base ref" || fail "finalize rc=$RC: $ERR"
grep -qxF "close run-1" "$RSR_CALLS" && pass "finalize closes the run-supervision record" || fail "record close not delegated: $(cat "$RSR_CALLS")"

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
EXPERIMENT_LEDGER_EVENT_CMD="$T/stub/ledger.sh" run paperwork run-1 "$D" --outcome completed-as-designed --no-artifacts
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

[ "$fails" = 0 ] && echo "[smoke] close_record.sh: PASS" >&2 || echo "[smoke] close_record.sh: FAIL" >&2
exit "$fails"
