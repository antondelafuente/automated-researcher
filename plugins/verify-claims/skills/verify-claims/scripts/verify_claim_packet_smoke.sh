#!/bin/bash
# verify_claim_packet_smoke.sh — behavior smoke for `verify_claim.sh --exp` (automated-researcher#817).
#
# Why this exists: the whole point of --exp is that the evidence packet is assembled BY CODE, so the
# UNKNOWN→reassemble→rerun loop can't happen (measured in 3/3 recent designs, ~2-3 min and ~$1-2 each).
# That guarantee is only worth anything if the assembly is actually right — a cited path silently left
# out of the packet reproduces exactly the bug this replaced, and a `check:` directive that
# auto-CONFIRMs a claim it should have DISPUTED is strictly worse than the old behavior, because a gate
# that fails OPEN is not a gate. Neither is visible to `bash -n`.
#
# Fully offline: VERIFIER_CMD is stubbed, so no model, no network, no credentials.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VC="$SCRIPT_DIR/verify_claim.sh"
[ -x "$VC" ] || [ -f "$VC" ] || { echo "SMOKE-FAIL: verify_claim.sh not found at $VC" >&2; exit 1; }

fail=0
ok(){ echo "  ok: $*" >&2; }
bad(){ echo "  SMOKE-FAIL: $*" >&2; fail=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A stub verifier: echoes what it was asked, records the evidence dir it was pointed at, and emits a
# fixed verdict for every claim number it sees. It writes to $OUT_TMP, exactly like a real runner must.
STUB="$TMP/stub_verifier.sh"
cat > "$STUB" <<'STUBEOF'
#!/bin/bash
set -uo pipefail
prompt=$(cat)
printf '%s\n' "$prompt" > "$STUB_PROMPT"
printf '%s\n' "$STUB_EVIDENCE" > "$STUB_EVIDENCE_SEEN"
{
  for n in $(printf '%s\n' "$prompt" | grep -oE '^[0-9]+\.' | tr -d '.'); do
    echo "CLAIM $n: CONFIRM"
    echo "  evidence: stub: \"stubbed\""
    echo "  reasoning: stub verifier."
  done
  echo "SUMMARY: confirm=? dispute=? unknown=?"
} > "$OUT_TMP"
STUBEOF
chmod +x "$STUB"

# ---------------------------------------------------------------- a small git-backed experiment repo
REPO="$TMP/repo"
mkdir -p "$REPO/registry/exp-1/data"
git -C "$REPO" init -q
git -C "$REPO" config user.email smoke@example.com
git -C "$REPO" config user.name smoke
EXPD="$REPO/registry/exp-1"
cat > "$EXPD/DESIGN.md" <<'EOF'
# DESIGN — exp-1
## What's measured
Arms A and B on the pinned stack.
EOF
printf 'a\nb\nc\n' > "$EXPD/data/train.jsonl"
mkdir -p "$REPO/registry/parent-1"
echo "# parent design" > "$REPO/registry/parent-1/DESIGN.md"
git -C "$REPO" add -A >/dev/null
git -C "$REPO" commit -qm "exp-1 design stage" >/dev/null
PARENT_SHA=$(git -C "$REPO" rev-parse HEAD)
TRAIN_SHA=$(sha256sum "$EXPD/data/train.jsonl" | cut -d' ' -f1)

run_vc(){   # $1=claims file  $2=out file ; stub env wired in
  STUB_PROMPT="$TMP/prompt.txt" STUB_EVIDENCE_SEEN="$TMP/evidence.txt" \
  VERIFIER_CMD="OUT_TMP=\"\$OUT_TMP\" STUB_EVIDENCE=\"\$EVIDENCE\" bash $STUB" \
  VERIFY_CLAIM_KEEP_EVIDENCE=1 \
    bash "$VC" --exp "$EXPD" "$1" "$2" >"$TMP/run.log" 2>&1
}

# ---------------------------------------------------------------- 1. packet assembly + mechanical facts
rm -f "$TMP/prompt.txt" "$TMP/evidence.txt"
CL="$TMP/claims1.txt"
cat > "$CL" <<EOF
1. The training pool is registry/exp-1/data/train.jsonl and it has 3 rows.
2. The parent design registry/parent-1/DESIGN.md@$PARENT_SHA is the baseline this reruns.
3. The arms are on the same pinned stack as the parent wave.
EOF
run_vc "$CL" "$TMP/out1.md"
rc=$?
[ $rc = 0 ] || bad "run 1 exited $rc; log: $(tail -3 "$TMP/run.log")"
PKT=$(grep -oE '/[^ ]*/packet$' "$TMP/run.log" | tail -1)
if [ -n "$PKT" ] && [ -d "$PKT" ]; then
  ok "packet dir reported and present"
  [ -f "$PKT/DESIGN.md" ] && ok "DESIGN.md auto-included (never cited in the claims)" \
    || bad "DESIGN.md missing from the packet — the #817 packing bug, reproduced"
  [ -f "$PKT/registry/exp-1/data/train.jsonl" ] && ok "cited data path copied into the packet" \
    || bad "cited path registry/exp-1/data/train.jsonl not copied into the packet"
  [ -f "$PKT/registry/parent-1/DESIGN.md" ] && ok "cited sibling-experiment path copied into the packet" \
    || bad "cited path registry/parent-1/DESIGN.md not copied into the packet"
  if [ -f "$PKT/MECHANICAL_FACTS.md" ]; then
    grep -q "$TRAIN_SHA" "$PKT/MECHANICAL_FACTS.md" && ok "sha256 resolved mechanically" \
      || bad "MECHANICAL_FACTS.md carries no sha256 for the cited file"
    grep -q "lines: 3" "$PKT/MECHANICAL_FACTS.md" && ok "line count resolved mechanically" \
      || bad "MECHANICAL_FACTS.md carries no line count for the cited file"
    grep -q "ancestor of HEAD = YES" "$PKT/MECHANICAL_FACTS.md" && ok "commit ancestry resolved mechanically" \
      || bad "MECHANICAL_FACTS.md carries no commit-ancestry fact for the cited <path>@<sha>"
  else
    bad "MECHANICAL_FACTS.md not written into the packet"
  fi
else
  bad "no packet dir reported (VERIFY_CLAIM_KEEP_EVIDENCE=1 should keep and print it)"
fi
[ -f "$TMP/evidence.txt" ] && [ "$(cat "$TMP/evidence.txt")" = "$PKT" ] \
  && ok "verifier was pointed at the generated packet" \
  || bad "verifier evidence dir was '$(cat "$TMP/evidence.txt" 2>/dev/null)', expected '$PKT'"
grep -q "MECHANICAL_FACTS.md" "$TMP/prompt.txt" \
  && ok "verifier prompt tells the model MECHANICAL_FACTS.md is a primary record" \
  || bad "verifier prompt never mentions MECHANICAL_FACTS.md"
grep -q "^SUMMARY: confirm=" "$TMP/out1.md" && ok "verdict carries a combined SUMMARY line" \
  || bad "verdict has no combined SUMMARY line"
# Two SUMMARY records let a consumer grep the first one and read semantic-only counts, missing every
# mechanically-resolved DISPUTE above it (#818 review, P0).
n_sum=$(grep -cE "^[[:space:]]*SUMMARY:" "$TMP/out1.md")
[ "$n_sum" = 1 ] && ok "exactly one SUMMARY record in the verdict (verifier's own is folded in)" \
  || bad "verdict carries $n_sum SUMMARY records; the combined one must be the only one"

# ---------------------------------------------------------------- 2. `check:` directives settle claims
rm -f "$TMP/prompt.txt"
CL2="$TMP/claims2.txt"
cat > "$CL2" <<EOF
1. The training pool is exactly the committed 3-row file.
   check: exists registry/exp-1/data/train.jsonl
   check: rows registry/exp-1/data/train.jsonl 3
   check: sha256 registry/exp-1/data/train.jsonl $TRAIN_SHA
2. The parent design landed on this branch.
   check: commit registry/parent-1/DESIGN.md@$PARENT_SHA
3. The arms measure the same construct as the parent wave.
EOF
run_vc "$CL2" "$TMP/out2.md"
grep -qE "^CLAIM 1: CONFIRM" "$TMP/out2.md" && ok "all-passing check: directives -> deterministic CONFIRM" \
  || bad "claim 1 was not mechanically CONFIRMed"
grep -qE "^CLAIM 2: CONFIRM" "$TMP/out2.md" && ok "commit-ancestry directive -> deterministic CONFIRM" \
  || bad "claim 2 was not mechanically CONFIRMed"
grep -qE "^\s*1\." "$TMP/prompt.txt" && bad "claim 1 was still sent to the verifier despite being settled by code" \
  || ok "mechanically settled claims never reach the verifier"
grep -qE "^\s*3\." "$TMP/prompt.txt" && ok "the semantic claim IS sent to the verifier" \
  || bad "semantic claim 3 never reached the verifier"

# ---------------------------------------------------------------- 3. a gate must fail CLOSED
rm -f "$TMP/prompt.txt"
CL3="$TMP/claims3.txt"
cat > "$CL3" <<EOF
1. The training pool has 9999 rows.
   check: rows registry/exp-1/data/train.jsonl 9999
2. The manifest is committed.
   check: exists registry/exp-1/data/nope.jsonl
EOF
run_vc "$CL3" "$TMP/out3.md"
grep -qE "^CLAIM 1: DISPUTE" "$TMP/out3.md" && ok "a wrong count DISPUTEs (fails closed, not open)" \
  || bad "a wrong row count did not produce DISPUTE"
grep -qE "^CLAIM 2: DISPUTE" "$TMP/out3.md" && ok "a non-existent cited path DISPUTEs (fails closed)" \
  || bad "a missing cited path did not produce DISPUTE"
[ -s "$TMP/prompt.txt" ] && bad "verifier was run even though every claim was settled by code" \
  || ok "verifier skipped entirely when no semantic claim remains"
grep -q "SUMMARY: confirm=0 dispute=2 unknown=0" "$TMP/out3.md" \
  && ok "combined SUMMARY counts the mechanical verdicts" \
  || bad "combined SUMMARY wrong: $(grep '^SUMMARY' "$TMP/out3.md")"

# ---------------------------------------------------------------- 4. fail-closed preconditions
bash "$VC" --exp "$TMP/no-such-dir" "$CL" "$TMP/out4.md" >"$TMP/e4.log" 2>&1 && \
  bad "a missing experiment dir did not BLOCK" || ok "missing experiment dir BLOCKs"
mkdir -p "$TMP/nodesign"
bash "$VC" --exp "$TMP/nodesign" "$CL" "$TMP/out5.md" >"$TMP/e5.log" 2>&1 && \
  bad "an experiment dir with no DESIGN.md did not BLOCK" || ok "missing DESIGN.md BLOCKs"

# ---------------------------------------------------------------- 5. the legacy 2-arg form still works
rm -f "$TMP/prompt.txt" "$TMP/evidence.txt"
LEG="$TMP/legacy_evidence"; mkdir -p "$LEG"; cp "$EXPD/DESIGN.md" "$LEG/"
STUB_PROMPT="$TMP/prompt.txt" STUB_EVIDENCE_SEEN="$TMP/evidence.txt" \
VERIFIER_CMD="OUT_TMP=\"\$OUT_TMP\" STUB_EVIDENCE=\"\$EVIDENCE\" bash $STUB" \
  bash "$VC" "$CL" "$LEG" "$TMP/out6.md" >"$TMP/run6.log" 2>&1
if [ -s "$TMP/out6.md" ] && grep -qE "^CLAIM 1: CONFIRM" "$TMP/out6.md"; then
  ok "legacy hand-assembled-packet form still runs"
else
  bad "legacy form broke: $(tail -3 "$TMP/run6.log")"
fi
grep -q "Evidence packet (built by code" "$TMP/out6.md" \
  && bad "legacy form gained the --exp assembled wrapper (output shape changed for existing callers)" \
  || ok "legacy form's output is the verifier's verdict verbatim, as before"
[ "$(cat "$TMP/evidence.txt")" = "$LEG" ] && ok "legacy form points the verifier at the hand-assembled dir" \
  || bad "legacy evidence dir was '$(cat "$TMP/evidence.txt" 2>/dev/null)', expected '$LEG'"
# The calibration provenance (3/3 incidents caught, 0 false alarms) is against the ORIGINAL prompt text;
# --exp's extra instructions must not leak into the legacy path and silently re-calibrate it.
grep -q "MECHANICAL_FACTS" "$TMP/prompt.txt" \
  && bad "the --exp prompt preamble leaked into the legacy path (its calibration is prompt-specific)" \
  || ok "legacy prompt is unchanged — no --exp preamble"

# ---------------------------------------------------------------- 6. citation shapes reach the packet
# Inclusion must be decided by RESOLUTION, with no shape pre-filter in front of it. Every such guess
# has dropped a real record: first a bare `RESULTS.md` and a long-extension
# `artifacts/model.safetensors`, then an EXTENSIONLESS `SHA256SUMS`/`Makefile` that a surviving
# "slash or extension" pre-filter still rejected before resolve() ran (#818 review rounds 1-2, P0) —
# the exact packing hole --exp exists to close.
rm -f "$TMP/prompt.txt"
mkdir -p "$EXPD/artifacts"
echo "# results" > "$EXPD/RESULTS.md"
printf 'weights\n' > "$EXPD/artifacts/model.safetensors"
printf 'deadbeef  RESULTS.md\n' > "$EXPD/SHA256SUMS"
printf 'all:\n\t@true\n' > "$EXPD/Makefile"
CL7="$TMP/claims7.txt"
cat > "$CL7" <<'EOF'
1. The headline number lives in RESULTS.md and the checkpoint is artifacts/model.safetensors.
2. The digests are recorded in `SHA256SUMS`, and the entry point is Makefile.
3. Every arm was scored and/or re-scored at 24k/53k tokens, per no file in particular.
EOF
run_vc "$CL7" "$TMP/out7.md"
PKT7=$(grep -oE '/[^ ]*/packet$' "$TMP/run.log" | tail -1)
[ -f "$PKT7/RESULTS.md" ] && ok "a bare cited filename reaches the packet" \
  || bad "bare cited path RESULTS.md not copied into the packet"
[ -f "$PKT7/artifacts/model.safetensors" ] \
  && ok "a one-level path with a long extension reaches the packet" \
  || bad "cited path artifacts/model.safetensors not copied into the packet"
[ -f "$PKT7/SHA256SUMS" ] && ok "an extensionless backticked record reaches the packet" \
  || bad "cited path SHA256SUMS not copied into the packet — a shape pre-filter is still deciding inclusion"
[ -f "$PKT7/Makefile" ] && ok "an extensionless UNbackticked record reaches the packet (resolution decides)" \
  || bad "cited path Makefile not copied into the packet — a shape pre-filter is still deciding inclusion"
grep -qE "WARN cited path does not resolve: (and/or|24k/53k)" "$TMP/run.log" \
  && bad "prose with a slash was reported as a missing record" \
  || ok "prose that merely contains a slash is not reported as a missing record"

# ---------------------------------------------------------------- 7. `<path>@<sha>` pins a REVISION
# The packet must carry the bytes AT THE PIN. Showing the working-tree file instead is how a
# parent-drift check silently passes on an amended parent (#818 review, P0).
rm -f "$TMP/prompt.txt"
echo "# parent design — AMENDED AFTER THE PIN" > "$REPO/registry/parent-1/DESIGN.md"
printf 'x\ny\n' > "$EXPD/data/gone.jsonl"
git -C "$REPO" add -A >/dev/null
git -C "$REPO" commit -qm "amend parent, add a file that will be deleted" >/dev/null
GONE_SHA=$(git -C "$REPO" rev-parse HEAD)
rm -f "$EXPD/data/gone.jsonl"
git -C "$REPO" commit -qam "delete gone.jsonl" >/dev/null
CL8="$TMP/claims8.txt"
cat > "$CL8" <<EOF
1. The baseline is registry/parent-1/DESIGN.md@$PARENT_SHA as authorized.
2. The dropped pool was registry/exp-1/data/gone.jsonl@$GONE_SHA at the time it was measured.
EOF
run_vc "$CL8" "$TMP/out8.md"
PKT8=$(grep -oE '/[^ ]*/packet$' "$TMP/run.log" | tail -1)
PIN="$PKT8/registry/parent-1/DESIGN.md@$PARENT_SHA"
if [ -f "$PIN" ]; then
  ok "the pinned revision is materialized into the packet"
  grep -q "AMENDED AFTER THE PIN" "$PIN" \
    && bad "the pinned copy holds the working-tree bytes, not the bytes at the pin" \
    || ok "the pinned copy holds the bytes AS OF the pinned commit"
else
  bad "no pinned copy at $PIN — the verifier would only see the amended working-tree file"
fi
grep -q "the working tree DIFFERS from" "$PKT8/MECHANICAL_FACTS.md" \
  && ok "MECHANICAL_FACTS.md flags the working tree/pin divergence" \
  || bad "a diverged pin is not flagged in MECHANICAL_FACTS.md"
[ -f "$PKT8/registry/exp-1/data/gone.jsonl@$GONE_SHA" ] \
  && ok "a path deleted since the pin is still materialized at its pinned commit" \
  || bad "a since-deleted pinned path produced no packet copy"
grep -q "WARN cited path does not resolve: registry/exp-1/data/gone.jsonl" "$TMP/run.log" \
  && bad "a pinned path whose bytes ARE in the packet was reported unresolved" \
  || ok "pinned-only paths are not reported as unresolved"

# ---------------------------------------------------------------- 8. a truncated listing says so
# Omitted evidence must be distinguishable from absent evidence (#818 review, P1).
rm -f "$TMP/prompt.txt"
BIGD="$EXPD/rollouts"; mkdir -p "$BIGD"
for i in $(seq 1 505); do : > "$BIGD/r$i.json"; done
CL9="$TMP/claims9.txt"
cat > "$CL9" <<'EOF'
1. Every rollout landed under registry/exp-1/rollouts.
EOF
run_vc "$CL9" "$TMP/out9.md"
PKT9=$(grep -oE '/[^ ]*/packet$' "$TMP/run.log" | tail -1)
grep -q "LISTING TRUNCATED" "$PKT9/MECHANICAL_FACTS.md" \
  && ok "a truncated directory listing is marked in MECHANICAL_FACTS.md" \
  || bad "a directory listing cut at 500 entries is not marked as truncated"
grep -q "505 file(s) total" "$PKT9/MECHANICAL_FACTS.md" \
  && ok "the full directory count is stated even when the listing is cut" \
  || bad "MECHANICAL_FACTS.md does not state the true file count for a truncated listing"
grep -q "TRUNCATED" "$PKT9/registry/exp-1/rollouts.listing.txt" \
  && ok "the listing file itself marks the cut" \
  || bad "the listing file ends silently at 500 entries"
grep -q "TRUNCATED to the first 500 of 505" "$TMP/out9.md" \
  && ok "the verdict's packet manifest marks the cut" \
  || bad "the verdict manifest does not mark the truncated listing"

# ------------------------------------------------- 9. an unevaluable directive can't rescue a failed one
# `check: commit` is unevaluable outside a git repo. Paired with an already-FAILED `check: exists`,
# testing unevaluable-before-failed sent the whole claim to the model as an open question instead of
# DISPUTING it — the gate failing OPEN (#818 review round 2, P0). Failure-first is the precedence.
rm -f "$TMP/prompt.txt"
NOGIT="$TMP/nogit-exp"; mkdir -p "$NOGIT"
echo "# DESIGN — an experiment dir outside any git repo" > "$NOGIT/DESIGN.md"
CL10="$TMP/claims10.txt"
cat > "$CL10" <<'EOF'
1. The manifest is present and was committed.
   check: exists nope-not-here.jsonl
   check: commit DESIGN.md@0123456789abcdef0123456789abcdef01234567
2. The design landed on this branch.
   check: commit DESIGN.md@0123456789abcdef0123456789abcdef01234567
EOF
STUB_PROMPT="$TMP/prompt.txt" STUB_EVIDENCE_SEEN="$TMP/evidence.txt" \
VERIFIER_CMD="OUT_TMP=\"\$OUT_TMP\" STUB_EVIDENCE=\"\$EVIDENCE\" bash $STUB" \
  bash "$VC" --exp "$NOGIT" "$CL10" "$TMP/out10.md" >"$TMP/run10.log" 2>&1
grep -qE "^CLAIM 1: DISPUTE" "$TMP/out10.md" \
  && ok "a failed directive DISPUTEs even when a sibling directive is unevaluable" \
  || bad "a failed check: escaped DISPUTE because a sibling was unevaluable — the gate failed OPEN"
grep -qE "^\s*1\." "$TMP/prompt.txt" \
  && bad "the already-failed claim was handed to the verifier as an open question" \
  || ok "the already-failed claim never reached the verifier"
grep -qE "^\s*2\." "$TMP/prompt.txt" \
  && ok "a claim whose ONLY directive is unevaluable still goes to the verifier" \
  || bad "an unevaluable-only claim was settled by code instead of sent to the verifier"
grep -q "could not be evaluated mechanically" "$TMP/prompt.txt" \
  && ok "the verifier is told which directive the environment could not evaluate" \
  || bad "the unevaluable-only claim reached the verifier without its note"

# ---------------------------------- 10. extraction / packet-name collisions / verdict attribution
# Three coupled defects, reproduced from the senior engineer's #818 round-3 fixture:
#   (a) EXTRACTION — a backticked span was word-split, so a real `my results.jsonl` never resolved;
#       an absolute citation was never captured at all; and a token was allowed to start MID-PATH
#       (right after a `-`), so the fragment `abs/absfile.txt` of a hyphenated absolute path became a
#       loud "missing record" report for a path nobody cited.
#   (b) COLLISION — two citations that flatten to the same `cited/<basename>` overwrote each other:
#       the packet ended up holding one file's bytes while MECHANICAL_FACTS.md described both, each
#       with its own sha256. A packet that silently answers a claim with ANOTHER file's bytes is worse
#       than the missing-record hole --exp exists to close.
#   (c) ATTRIBUTION — an unresolvable `check:` path was dropped as prose before the facts were
#       written, so the verdict quoted MECHANICAL_FACTS.md for a string absent from that file.
rm -f "$TMP/prompt.txt"
mkdir -p "$REPO/registry/run-a" "$REPO/registry/run-b" "$TMP/vc-abs"
echo "AAA-run-a-bytes" > "$REPO/registry/run-a/results.jsonl"
echo "BBB-run-b-bytes" > "$REPO/registry/run-b/results.jsonl"
echo "absolute-file-bytes" > "$TMP/vc-abs/absfile.txt"
echo "spacey-bytes" > "$EXPD/my results.jsonl"
# A cited FILE `collide` and a cited `collide/inner.txt` are BOTH legitimate when they resolve under
# different search bases; writing one made the other's makedirs raise, taking the whole gate down.
echo "outer-file-bytes" > "$EXPD/collide"
mkdir -p "$REPO/registry/collide"; echo "inner-bytes" > "$REPO/registry/collide/inner.txt"
CL11="$TMP/claims11.txt"
cat > "$CL11" <<EOF
1. The run-a results at ../run-a/results.jsonl differ from ../run-b/results.jsonl.
2. The raw output landed in $TMP/vc-abs/absfile.txt before postprocessing.
3. The merged rows are in \`my results.jsonl\` in the experiment dir.
4. The dropped-rows record exists.
   check: exists nope.jsonl
5. The prefix records collide and collide/inner.txt are both preserved.
EOF
run_vc "$CL11" "$TMP/out11.md"
rc11=$?
[ $rc11 = 0 ] || bad "run 11 exited $rc11; log: $(tail -3 "$TMP/run.log")"
grep -q "Traceback" "$TMP/run.log" \
  && bad "packet assembly raised: $(grep -A2 Traceback "$TMP/run.log" | tail -2)" \
  || ok "packet assembly survives a file/directory name clash between two cited records"
PKT11=$(grep -oE '/[^ ]*/packet$' "$TMP/run.log" | tail -1)
FACTS11="$PKT11/MECHANICAL_FACTS.md"

# --- (a) extraction
[ -f "$PKT11/abs$TMP/vc-abs/absfile.txt" ] \
  && ok "an absolute citation is extracted and lands under abs/ in the packet" \
  || bad "absolute citation $TMP/vc-abs/absfile.txt never reached the packet"
[ -f "$PKT11/my results.jsonl" ] \
  && ok "a backticked space-containing citation resolves as ONE literal name" \
  || bad "backticked \`my results.jsonl\` was word-split; the real file never reached the packet"
# `nope.jsonl` is the ONLY citation in this claims file that resolves to nothing, so any other loud
# missing-record report is a token that started mid-path inside a citation that does resolve.
missing=$(awk '/^### `/{cur=$0} /^- resolved in the working tree: \*\*NO\*\*/{print cur}' "$FACTS11")
[ "$missing" = '### `nope.jsonl`' ] \
  && ok "only the genuinely-missing record gets an unresolved facts entry" \
  || bad "facts carry unresolved entries for paths nobody cited (mid-path fragments): $missing"
bogus=$(grep -oE "WARN cited path does not resolve: .*" "$TMP/run.log" | grep -v "nope.jsonl" || true)
[ -z "$bogus" ] && ok "no bogus loud WARN for a fragment of a resolvable path" \
  || bad "bogus missing-record WARN(s) from mid-path fragments: $bogus"

# --- (b) collisions: distinct sources never share a packet path, and the facts name each one
facts_block(){ awk -v want="### \`$1\`" '$0==want{f=1;next} f&&/^### /{exit} f{print}' "$2"; }
packet_copy_of(){ facts_block "$1" "$2" | sed -n 's/^- packet copy: `\([^`]*\)`.*/\1/p' | head -1; }
facts_sha_of(){ facts_block "$1" "$2" | sed -n 's/^- sha256: `\([0-9a-f]*\)`.*/\1/p' | head -1; }
A_REL=$(packet_copy_of '../run-a/results.jsonl' "$FACTS11")
B_REL=$(packet_copy_of '../run-b/results.jsonl' "$FACTS11")
if [ -n "$A_REL" ] && [ -n "$B_REL" ]; then
  ok "MECHANICAL_FACTS.md names each included file's packet path (citation -> copy is mapped)"
else
  bad "the facts never name the packet copy for ../run-a ('$A_REL') / ../run-b ('$B_REL')"
fi
[ -n "$A_REL" ] && [ "$A_REL" = "$B_REL" ] \
  && bad "two different cited files share packet path '$A_REL' — one overwrote the other" \
  || ok "citations resolving to different files get different packet paths"
for arm in run-a run-b; do
  rel=$(packet_copy_of "../$arm/results.jsonl" "$FACTS11")
  want=$(facts_sha_of "../$arm/results.jsonl" "$FACTS11")
  got=""; [ -n "$rel" ] && [ -f "$PKT11/$rel" ] && got=$(sha256sum "$PKT11/$rel" | cut -d' ' -f1)
  [ -n "$want" ] && [ "$want" = "$got" ] \
    && ok "../$arm/results.jsonl's packet copy hashes to its OWN facts sha256" \
    || bad "../$arm/results.jsonl: packet copy '$rel' hashes '$got' but its facts say '$want'"
done
C_OUTER=$(packet_copy_of 'collide' "$FACTS11")
C_INNER=$(packet_copy_of 'collide/inner.txt' "$FACTS11")
if [ -n "$C_OUTER" ] && [ -n "$C_INNER" ] &&
   [ "$(cat "$PKT11/$C_OUTER" 2>/dev/null)" = "outer-file-bytes" ] &&
   [ "$(cat "$PKT11/$C_INNER" 2>/dev/null)" = "inner-bytes" ]; then
  ok "a cited file and a cited path UNDER that name both keep their own bytes"
else
  bad "file/dir name clash lost a record: 'collide'->'$C_OUTER', 'collide/inner.txt'->'$C_INNER'"
fi

# --- (c) attribution: every mechanical verdict's evidence quote exists verbatim in the facts file
grep -q "nope.jsonl" "$FACTS11" \
  && ok "an unresolvable check: path surfaces as a facts entry instead of being dropped as prose" \
  || bad "check: exists nope.jsonl left no trace in MECHANICAL_FACTS.md"
grep -qE "^CLAIM 4: DISPUTE" "$TMP/out11.md" && ok "the unresolvable check: directive still DISPUTEs" \
  || bad "check: exists nope.jsonl did not DISPUTE"
QUOTE=$(sed -n 's/^  evidence: MECHANICAL_FACTS\.md: "\(.*\)"$/\1/p' "$TMP/out11.md" | head -1)
if [ -n "$QUOTE" ] && grep -Fq "$QUOTE" "$FACTS11"; then
  ok "the mechanical verdict's evidence quote appears verbatim in MECHANICAL_FACTS.md"
else
  bad "verdict quotes MECHANICAL_FACTS.md for text that file does not contain: '$QUOTE'"
fi
n_sum11=$(grep -cE "^[[:space:]]*SUMMARY:" "$TMP/out11.md")
[ "$n_sum11" = 1 ] && ok "still exactly one SUMMARY record with both halves present" \
  || bad "verdict carries $n_sum11 SUMMARY records"

[ "$fail" = 0 ] && echo "[verify_claim_packet_smoke] PASS" >&2 || echo "[verify_claim_packet_smoke] FAIL" >&2
exit "$fail"
