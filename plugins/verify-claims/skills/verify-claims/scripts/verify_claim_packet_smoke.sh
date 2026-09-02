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

[ "$fail" = 0 ] && echo "[verify_claim_packet_smoke] PASS" >&2 || echo "[verify_claim_packet_smoke] FAIL" >&2
exit "$fail"
