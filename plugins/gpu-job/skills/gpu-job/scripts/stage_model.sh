#!/usr/bin/env bash
# stage_model.sh — cache an HF model in your artifact store ONCE so every pod pulls from the
# store (same-provider, parallel, verifiable) instead of re-pulling from Hugging Face per run.
# Run from the orchestrator box (or any host with HF access + rclone configured).
#
# Retires a cluster of paid incidents (orchestrator experiment_gotchas.md):
#  - a 32B HF base took 25+ min, sometimes fully STALLED on a bad host (~$5 H200 burned on a
#    stuck `*.incomplete` shard) — staged-then-pulled bytes are a fast same-provider copy;
#  - the first pre-stage of r2:.../Qwen3-32B-hfhub rclone-copied the HF cache WITHOUT -L and
#    skipped the snapshot symlinks → from_pretrained failed on a copy with blobs but no usable
#    snapshot. Here we materialize a clean tree AND pass -L belt-and-suspenders;
#  - a de-risk pod polled "ready" by SIZE THRESHOLD, started pulling mid-upload, and missed
#    model-00017-of-00017.safetensors → from_pretrained died. The fix: a completeness manifest
#    (_STAGED.json) written LAST recording object_count + total_bytes, which the pod-side
#    pull_model (job_lib.sh) verifies — never a size guess.
#
# Usage: stage_model.sh <hf-repo>[@rev] <remote-path>
#   e.g. stage_model.sh meta-llama/Llama-3.1-8B@main <remote>:models/llama-3.1-8b
#        stage_model.sh Qwen/Qwen2.5-7B          <remote>:models/qwen2.5-7b
# Env: HF_TOKEN     — for gated repos (passed through to huggingface-cli).
#      STAGE_FORCE=1 — re-stage into a non-empty remote prefix (purges it first); without it,
#                      a non-empty prefix is a hard error so a typo can't blend two models.
set -euo pipefail

# Source the shared job lib for r2_copy (the hardened -L + "Can't follow symlink ⇒ INCOMPLETE" copy).
# job_lib.sh is a pure function library — sourcing only defines functions, no side effects.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=job_lib.sh
source "$SCRIPT_DIR/job_lib.sh"

[ $# -eq 2 ] || { echo "usage: stage_model.sh <hf-repo>[@rev] <remote-path>" >&2; exit 1; }
SPEC=$1; REMOTE=${2%/}            # strip any trailing slash on the remote path
REPO=${SPEC%@*}                    # repo before '@'
REV=main; [ "$SPEC" != "$REPO" ] && REV=${SPEC#*@}   # rev after '@', default main

command -v rclone >/dev/null || { echo "BLOCKED: rclone not found" >&2; exit 1; }
# HF CLI: modern huggingface_hub ships `hf` (the old `huggingface-cli` is deprecated and no-ops);
# fall back to `huggingface-cli` only for older installs that predate `hf`.
if command -v hf >/dev/null; then HF=hf
elif command -v huggingface-cli >/dev/null; then HF=huggingface-cli
else echo "BLOCKED: no HF CLI found (pip install -U huggingface_hub gives 'hf')" >&2; exit 1; fi

say(){ echo "=== [$(date -u +%H:%M:%S)] $* ==="; }

# 0. Clean-prefix contract: aggregate count+bytes is only sound on a tree we fully own. Refuse a
#    non-empty prefix (catches a typo'd/reused path that would blend two models) unless forced.
if rclone lsf "$REMOTE/" 2>/dev/null | grep -q .; then
  if [ "${STAGE_FORCE:-0}" = "1" ]; then
    say "STAGE_FORCE=1: purging existing $REMOTE/ before re-stage"
    # Fail closed: a swallowed purge error would leave stale objects under the prefix, so the
    # aggregate count+bytes manifest would describe a tree that isn't actually there.
    rclone purge "$REMOTE" 2>/dev/null || { echo "BLOCKED: purge of $REMOTE failed" >&2; exit 1; }
    rclone lsf "$REMOTE/" 2>/dev/null | grep -q . && { echo "BLOCKED: $REMOTE/ still not empty after purge" >&2; exit 1; }
  else
    echo "BLOCKED: $REMOTE/ is not empty — refusing to stage into it. Set STAGE_FORCE=1 to purge+restage, or pick a fresh path." >&2
    exit 1
  fi
fi

# 1. Download into a clean materialized tree (real bytes, not cache symlinks).
# Disable the Xet-accelerated downloader (automated-researcher #442): it silently stalls at zero
# bytes/sec on some host/network paths, no error/timeout/retry — root-caused via a raw curl
# range-GET on the same host hitting full bandwidth, so the stall is Xet-specific, not the network.
export HF_HUB_DISABLE_XET="${HF_HUB_DISABLE_XET:-1}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
say "downloading $REPO@$REV from HF (via $HF) -> $TMP"
"$HF" download "$REPO" --revision "$REV" --local-dir "$TMP" >&2

# 2. Compute the manifest from the local tree BEFORE upload (so it describes what we mean to send).
#    Exclude the manifest name itself; count regular files and sum their bytes.
OBJ_COUNT=$(find "$TMP" -type f ! -name '_STAGED.json' | wc -l | tr -d ' ')
TOTAL_BYTES=$(find "$TMP" -type f ! -name '_STAGED.json' -printf '%s\n' | awk '{s+=$1} END{print s+0}')
[ "$OBJ_COUNT" -gt 0 ] || { echo "BLOCKED: nothing downloaded for $REPO@$REV" >&2; exit 1; }
say "staged tree: $OBJ_COUNT files, $TOTAL_BYTES bytes"

# 3. Upload the DATA first via r2_copy: it injects -L (follows any residual symlinks so bytes land,
#    never dangling links) AND fails closed if rclone logs a skipped symlink — so an incomplete upload
#    can't silently precede the completeness manifest below.
say "uploading -> $REMOTE/"
r2_copy "$TMP" "$REMOTE/" --transfers=8 --checkers=8 --exclude '_STAGED.json'

# 4. Write the completeness manifest LAST. Its presence == upload finished; its numbers are what
#    pull_model verifies against. (job_lib.sh: never a 0-byte sentinel — record the real bytes.)
MANIFEST="$TMP/_STAGED.json"
printf '{"repo":"%s","rev":"%s","object_count":%s,"total_bytes":%s,"staged_at":"%s"}\n' \
  "$REPO" "$REV" "$OBJ_COUNT" "$TOTAL_BYTES" "$(date -u +%FT%TZ)" > "$MANIFEST"
rclone copy "$MANIFEST" "$REMOTE/"

say "done: $REMOTE/_STAGED.json ($OBJ_COUNT files, $TOTAL_BYTES bytes) — pods pull via pull_model"
