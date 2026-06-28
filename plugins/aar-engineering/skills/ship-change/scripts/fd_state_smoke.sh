#!/usr/bin/env bash
# Smoke for the finding-disposition pure helpers (#139): extracts the fd_* block from wf.sh and tests
# fd_fid (stable id), fd_seed (seed findings as unresolved, idempotent), fd_high_list (HIGH extraction).
# The gh-backed fd_load/fd_save/fd_active are defined but not exercised here (they need a live PR).
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
WF="$HERE/wf.sh"
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required"; exit 1; }

# Load just the fd_* helpers (between the section comment and the extraction sentinel).
eval "$(sed -n '/finding-disposition state (#137\/#139)/,/^# fd-helpers-end/p' "$WF")"

TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
fails=0
ok(){ echo "ok   $1"; }
no(){ echo "FAIL $1"; fails=1; }

# fd_fid: stable + case/space-insensitive on the same substance, different for different text.
a=$(fd_fid "The new merge_records path crashes on empty input")
b=$(fd_fid "the   NEW merge_records   path crashes on empty input")
c=$(fd_fid "an unrelated finding about quoting")
[ "$a" = "$b" ] && ok fid-stable-normalized || no "fid-stable-normalized ($a vs $b)"
[ "$a" != "$c" ] && ok fid-distinct || no fid-distinct
[ "${#a}" = 12 ] && ok fid-length || no "fid-length (${#a})"

# fd_seed: seeds findings as unresolved; idempotent (second seed adds nothing).
cache="$TMP/c.json"
cat > "$TMP/rev.md" <<'REV'
FINDING 1: HIGH [correctness]
  issue: empty input crashes merge_records
  recommendation: guard it
FINDING 2: MED [edge-case]
  issue: whitespace not trimmed
  recommendation: trim
REV
: > "$cache"
fd_seed "$cache" "$TMP/rev.md"
[ "$(jq '.findings|length' "$cache")" = 2 ] && ok seed-count || no "seed-count ($(jq '.findings|length' "$cache"))"
[ "$(jq -r '.findings[0].status' "$cache")" = unresolved ] && ok seed-unresolved || no seed-unresolved
[ "$(jq -r '.findings[0].description' "$cache")" = "empty input crashes merge_records" ] && ok seed-description || no seed-description
fd_seed "$cache" "$TMP/rev.md"   # again
[ "$(jq '.findings|length' "$cache")" = 2 ] && ok seed-idempotent || no "seed-idempotent ($(jq '.findings|length' "$cache"))"

# author dispositions one; a NEW finding in a later round is added, the dispositioned one is untouched.
jq '(.findings[]|select(.severity=="HIGH")).status="fixed"' "$cache" > "$cache.t" && mv "$cache.t" "$cache"
cat > "$TMP/rev2.md" <<'REV'
FINDING 1: HIGH [correctness]
  issue: empty input crashes merge_records
FINDING 2: HIGH [security]
  issue: brand new token leak
REV
fd_seed "$cache" "$TMP/rev2.md"
[ "$(jq '.findings|length' "$cache")" = 3 ] && ok seed-adds-new-only || no "seed-adds-new-only ($(jq '.findings|length' "$cache"))"
[ "$(jq -r '.findings[]|select(.description|contains("merge_records")).status' "$cache")" = fixed ] && ok seed-keeps-disposition || no seed-keeps-disposition

# fd_high_list: emits "<id> HIGH" only for HIGH entries.
n=$(fd_high_list "$cache" | wc -l | tr -d ' ')
[ "$n" = 2 ] && ok high-list-count || no "high-list-count ($n)"
fd_high_list "$cache" | grep -qE '^[0-9a-f]{12} HIGH$' && ok high-list-format || no high-list-format

# fd_review_high_list: reviewer-derived trusted list (HIGH only), ids matching fd_seed so the gate aligns.
rl=$(fd_review_high_list "$TMP/rev.md")
[ "$(printf '%s\n' "$rl" | grep -c ' HIGH$')" = 1 ] && ok review-high-count || no "review-high-count ($rl)"
exp_id=$(fd_fid "empty input crashes merge_records")
printf '%s\n' "$rl" | grep -qx "$exp_id HIGH" && ok review-high-matches-seed-id || no "review-high-matches-seed-id (want $exp_id)"

# fd_bump_round / fd_round / fd_last_reviewed_sha: non-convergence backstop counter (#137). A round counts ONLY
# when the review left a blocking HIGH (4th arg had_high=1); idempotent on identical <sha + HIGH set>;
# increments on a new SHA OR a changed HIGH set; back-compat (absent round => 0). Also records last_reviewed_sha.
rc="$TMP/round.json"; : > "$rc"
hi1="$TMP/hi1.txt"; printf 'aaaaaaaaaaaa\nbbbbbbbbbbbb\n' > "$hi1"
[ "$(fd_round "$rc")" = 0 ] && ok round-absent-zero || no "round-absent-zero ($(fd_round "$rc"))"
r=$(fd_bump_round "$rc" "sha1111" "$hi1" 1); [ "$r" = 1 ] && ok round-first-bump || no "round-first-bump ($r)"
[ "$(fd_round "$rc")" = 1 ] && ok round-persisted || no "round-persisted ($(fd_round "$rc"))"
[ "$(fd_last_reviewed_sha "$rc")" = "sha1111" ] && ok round-records-sha || no "round-records-sha ($(fd_last_reviewed_sha "$rc"))"
r=$(fd_bump_round "$rc" "sha1111" "$hi1" 1); [ "$r" = 1 ] && ok round-idempotent-same-sha-same-high || no "round-idempotent ($r)"
# A CLEAN review (had_high=0) is NOT a non-convergence round -> never increments, leaves state untouched.
r=$(fd_bump_round "$rc" "sha9999" "$hi1" 0); [ "$r" = 1 ] && ok round-clean-no-bump || no "round-clean-no-bump ($r)"
[ "$(fd_last_reviewed_sha "$rc")" = "sha1111" ] && ok round-clean-keeps-sha || no "round-clean-keeps-sha ($(fd_last_reviewed_sha "$rc"))"
# same SHA, but HIGH set changed -> new fingerprint -> increment.
hi2="$TMP/hi2.txt"; printf 'aaaaaaaaaaaa\ncccccccccccc\n' > "$hi2"
r=$(fd_bump_round "$rc" "sha1111" "$hi2" 1); [ "$r" = 2 ] && ok round-bump-on-changed-high || no "round-changed-high ($r)"
# NEW commit (new SHA), SAME surviving HIGH set -> still increments (the #192 under-scoped signature).
r=$(fd_bump_round "$rc" "sha2222" "$hi2" 1); [ "$r" = 3 ] && ok round-bump-on-new-sha-same-high || no "round-new-sha ($r)"
[ "$(fd_last_reviewed_sha "$rc")" = "sha2222" ] && ok round-updates-sha || no "round-updates-sha ($(fd_last_reviewed_sha "$rc"))"
# HIGH-id ORDER must not matter (sorted in the fingerprint): reorder hi2 -> same fingerprint as last -> no bump.
hi2r="$TMP/hi2r.txt"; printf 'cccccccccccc\naaaaaaaaaaaa\n' > "$hi2r"
r=$(fd_bump_round "$rc" "sha2222" "$hi2r" 1); [ "$r" = 3 ] && ok round-order-insensitive || no "round-order ($r)"
# fd_round fails safe on a malformed round value (safe-read; the gating check is fd_round_valid below).
echo '{"round":"notanumber"}' > "$TMP/bad.json"
[ "$(fd_round "$TMP/bad.json")" = 0 ] && ok round-malformed-zero || no "round-malformed-zero ($(fd_round "$TMP/bad.json"))"

# fd_round_valid: absent/null/integer => rc 0 (ok); PRESENT non-integer => rc 2 (corruption, finish fails closed).
echo '{"findings":[]}' > "$TMP/v_absent.json"
fd_round_valid "$TMP/v_absent.json" && ok roundvalid-absent-ok || no "roundvalid-absent-ok"
echo '{"round":null}' > "$TMP/v_null.json"
fd_round_valid "$TMP/v_null.json" && ok roundvalid-null-ok || no "roundvalid-null-ok"
echo '{"round":3}' > "$TMP/v_int.json"
fd_round_valid "$TMP/v_int.json" && ok roundvalid-int-ok || no "roundvalid-int-ok"
fd_round_valid "$TMP/bad.json"; [ "$?" = 2 ] && ok roundvalid-string-rc2 || no "roundvalid-string-rc2"
echo '{"round":2.5}' > "$TMP/v_float.json"
fd_round_valid "$TMP/v_float.json"; [ "$?" = 2 ] && ok roundvalid-float-rc2 || no "roundvalid-float-rc2"
# A NUMERIC STRING must NOT sneak through (type-checked, not rendered-string-checked).
echo '{"round":"3"}' > "$TMP/v_numstr.json"
fd_round_valid "$TMP/v_numstr.json"; [ "$?" = 2 ] && ok roundvalid-numeric-string-rc2 || no "roundvalid-numeric-string-rc2"
# A negative integer is not a valid round either.
echo '{"round":-1}' > "$TMP/v_neg.json"
fd_round_valid "$TMP/v_neg.json"; [ "$?" = 2 ] && ok roundvalid-negative-rc2 || no "roundvalid-negative-rc2"
# Zero is a valid round.
echo '{"round":0}' > "$TMP/v_zero.json"
fd_round_valid "$TMP/v_zero.json" && ok roundvalid-zero-ok || no "roundvalid-zero-ok"

# fd_bump_round returns rc 1 (no echo) when the cache write fails — caller fails closed, never trusts a
# phantom increment. Simulate by making the cache dir unwritable so the jq+mv cannot land.
udir="$TMP/unwritable"; mkdir -p "$udir"; echo '{"round":4,"last_review_fingerprint":"x"}' > "$udir/c.json"; chmod 555 "$udir"
hi_bw="$TMP/hi_bw.txt"; printf 'zzzzzzzzzzzz\n' > "$hi_bw"
if out=$(fd_bump_round "$udir/c.json" "shaNEW" "$hi_bw" 1 2>/dev/null); then no "bump-rc1-on-write-fail (echoed $out, rc 0)"; else ok bump-rc1-on-write-fail; fi
chmod 755 "$udir"

# fd_merge_canonical_round: the MONOTONIC-counter guard (#137). An author save must never lower/delete `round`.
# Build a canonical comment body the way fd_save posts it (a ```json fenced block).
canon_body(){ printf '<!-- m -->\n\n```json\n%s\n```\n' "$1"; }
# canonical AHEAD of local -> adopt canonical round + its fp/sha into the cache (prevents regression).
mc="$TMP/mc.json"; echo '{"round":1,"findings":[]}' > "$mc"
fd_merge_canonical_round "$mc" "$(canon_body '{"round":5,"last_review_fingerprint":"FP5","last_reviewed_sha":"SHA5"}')"
[ "$(fd_round "$mc")" = 5 ] && ok merge-adopts-higher-canonical || no "merge-adopts-higher-canonical ($(fd_round "$mc"))"
[ "$(fd_last_reviewed_sha "$mc")" = "SHA5" ] && ok merge-adopts-canonical-sha || no "merge-adopts-canonical-sha ($(fd_last_reviewed_sha "$mc"))"
# local AHEAD of canonical (finish's advancing save) -> keep local, do NOT regress.
mc2="$TMP/mc2.json"; echo '{"round":6,"last_reviewed_sha":"SHALOCAL","findings":[]}' > "$mc2"
fd_merge_canonical_round "$mc2" "$(canon_body '{"round":5,"last_reviewed_sha":"SHA5"}')"
[ "$(fd_round "$mc2")" = 6 ] && ok merge-keeps-higher-local || no "merge-keeps-higher-local ($(fd_round "$mc2"))"
[ "$(fd_last_reviewed_sha "$mc2")" = "SHALOCAL" ] && ok merge-keeps-local-sha || no "merge-keeps-local-sha ($(fd_last_reviewed_sha "$mc2"))"
# author save that DROPPED the round (cache has no round) but canonical has one -> canonical wins (no reset).
mc3="$TMP/mc3.json"; echo '{"findings":[{"id":"x","severity":"HIGH","status":"fixed"}]}' > "$mc3"
fd_merge_canonical_round "$mc3" "$(canon_body '{"round":3,"last_reviewed_sha":"SHA3"}')"
[ "$(fd_round "$mc3")" = 3 ] && ok merge-restores-dropped-round || no "merge-restores-dropped-round ($(fd_round "$mc3"))"
[ "$(jq -r '.findings[0].id' "$mc3")" = "x" ] && ok merge-preserves-findings || no "merge-preserves-findings"
# EQUAL rounds: an author save whose cache dropped last_reviewed_sha must NOT publish a same-round comment
# without the SHA — canonical metadata is preserved on `>=` (else a later bare retry misses the short-circuit).
mc5="$TMP/mc5.json"; echo '{"round":4,"findings":[{"id":"y","severity":"MED","status":"refuted"}]}' > "$mc5"
fd_merge_canonical_round "$mc5" "$(canon_body '{"round":4,"last_review_fingerprint":"FPEQ","last_reviewed_sha":"SHAEQ"}')"
[ "$(fd_round "$mc5")" = 4 ] && ok merge-equal-keeps-round || no "merge-equal-keeps-round ($(fd_round "$mc5"))"
[ "$(fd_last_reviewed_sha "$mc5")" = "SHAEQ" ] && ok merge-equal-restores-sha || no "merge-equal-restores-sha ($(fd_last_reviewed_sha "$mc5"))"
[ "$(jq -r '.findings[0].id' "$mc5")" = "y" ] && ok merge-equal-preserves-findings || no "merge-equal-preserves-findings"
# both rounds zero (the normal no-backstop save) -> no-op, no spurious empty metadata written.
mc0="$TMP/mc0.json"; echo '{"findings":[]}' > "$mc0"
fd_merge_canonical_round "$mc0" "$(canon_body '{"round":0}')"
[ "$(jq 'has("last_reviewed_sha")' "$mc0")" = false ] && ok merge-zero-no-spurious-meta || no "merge-zero-no-spurious-meta"
# no/empty/unparseable canonical -> no-op, local untouched.
mc4="$TMP/mc4.json"; echo '{"round":2,"findings":[]}' > "$mc4"
fd_merge_canonical_round "$mc4" ""; [ "$(fd_round "$mc4")" = 2 ] && ok merge-empty-canonical-noop || no "merge-empty-canonical-noop ($(fd_round "$mc4"))"
fd_merge_canonical_round "$mc4" "no json fence here"; [ "$(fd_round "$mc4")" = 2 ] && ok merge-unparseable-canonical-noop || no "merge-unparseable-canonical-noop ($(fd_round "$mc4"))"

if [ "$fails" -eq 0 ]; then echo "fd_state_smoke: ALL PASS"; else echo "fd_state_smoke: FAILURES"; fi
exit "$fails"
