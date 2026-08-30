#!/usr/bin/env bash
# Smoke for reap_scratch.sh — close-time executor-scratch archive+reap (automated-researcher#792).
# Behavior the deterministic JSON/syntax checks can't catch, and the properties the incident turns on:
#   - the happy path: verified archive THEN delete, copy addressed at "<root>/<run-id>" with -L
#   - the clean-close guard (active / stopped / unknown run-ids never reap, rclone never invoked)
#   - the DERIVED delete target: only "<EXPERIMENT_SCRATCH_ROOT>/<run-id>" is ever reapable — a basename
#     that isn't the run-id is refused (no peer scratch), and so is a same-named dir under a DIFFERENT
#     root, which a basename-only binding would have accepted (round-1 code-review Finding 2)
#   - NO DELETE WITHOUT A VERIFIED ARCHIVE: copy failure, `Can't follow symlink` NOTICE on an exit-0
#     copy, `rclone check` failure, and a destination listing that doesn't show the run-id all leave the
#     directory in place and exit non-zero
#   - the unset-seam NO-OPs — archive dest, scratch root, no rclone (exit 0, nothing deleted/invoked)
#   - path-sanity refusals: a symlinked scratch dir, the run's own bound worktree, and a cwd inside it
#   - the destination probe matches the run-id LITERALLY (a '.' in a run-id is not a regex wildcard
#     that could pass the gate against a different, similarly-named archive prefix)
#   - an EMPTY scratch tree still completes rather than being stranded forever by a probe that cannot
#     pass for it (round-2 code-review Finding 2), while a tree holding only a SYMLINK is not empty and
#     still goes through the full archive-and-verify path
# rclone is stubbed on PATH — nothing is uploaded and no network is touched.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
R="$HERE/reap_scratch.sh"
REC="$HERE/run_supervision_record.sh"
[ -f "$R" ]   || { echo "FAIL: missing $R"; exit 1; }
[ -f "$REC" ] || { echo "FAIL: missing $REC"; exit 1; }

TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export AAR_RUN_SUPERVISION_DIR="$TMP/records"
mkdir -p "$AAR_RUN_SUPERVISION_DIR"
unset EXPERIMENT_SESSION_HANDLE_CMD

fails=0
ok(){ echo "ok   $1"; }
no(){ echo "FAIL $1"; fails=1; }
rec(){ bash "$REC" "$@"; }

# --- stubbed rclone -------------------------------------------------------------------------------
# `copy` materializes a marker under $STUB_STORE (so `lsf` of the parent lists it, exactly like a real
# store would) unless STUB_SKIP_STORE=1; `check`/`copy` exit codes and the symlink NOTICE are knobs.
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/rclone" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RCLONE_LOG"
case "${1:-}" in
  copy)
    [ "${STUB_COPY_NOTICE:-0}" = 1 ] && echo "NOTICE: big.bin: Can't follow symlink, skipping"
    if [ "${STUB_COPY_RC:-0}" = 0 ] && [ "${STUB_SKIP_STORE:-0}" != 1 ]; then
      # Real rclone creates NO empty directories at the destination, so a source tree holding no files
      # produces no destination prefix at all and the parent-listing probe cannot find it. The stub
      # models that rather than always materializing the prefix — otherwise the empty-tree case
      # (round-2 code-review Finding 2) would assert the fix's mechanism instead of reproducing the bug.
      if find "$2" -mindepth 1 ! -type d -print -quit 2>/dev/null | grep -q .; then
        mkdir -p "$STUB_STORE/${3##*/}"
      fi
    fi
    exit "${STUB_COPY_RC:-0}" ;;
  check) exit "${STUB_CHECK_RC:-0}" ;;
  lsf)   ls -1 "$STUB_STORE" 2>/dev/null | sed 's#$#/#'; exit 0 ;;
esac
exit 0
EOF
chmod +x "$BIN/rclone"
PATH="$BIN:$PATH"; export PATH
export RCLONE_LOG="$TMP/rclone.log"
export STUB_STORE="$TMP/store"
mkdir -p "$STUB_STORE"
export EXPERIMENT_SCRATCH_ARCHIVE_DEST="stub:bucket/archive/work"
# The instance-declared LOCAL scratch root: the only directory whose direct children are ever reapable.
export EXPERIMENT_SCRATCH_ROOT="$TMP/work"
mkdir -p "$EXPERIMENT_SCRATCH_ROOT"

rclone_calls(){ [ -f "$RCLONE_LOG" ] && wc -l < "$RCLONE_LOG" | tr -d ' ' || echo 0; }
reset_log(){ : > "$RCLONE_LOG"; }

# mkscratch <name> -> creates $TMP/work/<name> with a file in it, prints the path
mkscratch(){ local d="$TMP/work/$1"; mkdir -p "$d"; echo "payload-$1" > "$d/out.txt"; echo "$d"; }

# Every invocation runs from $TMP (never inside a scratch dir) unless a case deliberately does otherwise.
cd "$TMP" || { echo "FAIL: cd $TMP"; exit 1; }

# --- happy path: verified archive, THEN delete -----------------------------------------------------
rec create h1 >/dev/null; rec close h1 >/dev/null
s=$(mkscratch h1); reset_log
if bash "$R" h1 "$s" >/dev/null 2>&1; then ok happy-exit0; else no happy-exit0; fi
[ -d "$s" ] && no happy-scratch-deleted || ok happy-scratch-deleted
grep -q "^copy $s stub:bucket/archive/work/h1 -L$" "$RCLONE_LOG" && ok happy-copy-derived-dest-with-L \
  || no "happy-copy-derived-dest-with-L ($(grep '^copy' "$RCLONE_LOG"))"
grep -q "^check $s stub:bucket/archive/work/h1 --one-way -L$" "$RCLONE_LOG" && ok happy-check-derived-dest-with-L \
  || no "happy-check-derived-dest-with-L ($(grep '^check' "$RCLONE_LOG"))"
grep -q "^lsf stub:bucket/archive/work/$" "$RCLONE_LOG" && ok happy-lsf-lists-parent-prefix \
  || no "happy-lsf-lists-parent-prefix ($(grep '^lsf' "$RCLONE_LOG"))"

# a trailing slash on the configured root must not produce a "//" prefix
rec create h2 >/dev/null; rec close h2 >/dev/null
s=$(mkscratch h2); reset_log
EXPERIMENT_SCRATCH_ARCHIVE_DEST="stub:bucket/archive/work/" bash "$R" h2 "$s" >/dev/null 2>&1
grep -q "^copy $s stub:bucket/archive/work/h2 -L$" "$RCLONE_LOG" && ok trailing-slash-normalized \
  || no "trailing-slash-normalized ($(grep '^copy' "$RCLONE_LOG"))"

# --- clean-close guard: active / stopped / unknown never reap, and never invoke rclone --------------
rec create g_active >/dev/null
s=$(mkscratch g_active); reset_log
if bash "$R" g_active "$s" >/dev/null 2>&1; then no guard-active-refused; else ok guard-active-refused; fi
[ -d "$s" ] && ok guard-active-scratch-kept || no guard-active-scratch-kept
[ "$(rclone_calls)" = 0 ] && ok guard-active-no-rclone || no guard-active-no-rclone

rec create g_stop >/dev/null; rec stop g_stop >/dev/null
s=$(mkscratch g_stop); reset_log
if bash "$R" g_stop "$s" >/dev/null 2>&1; then no guard-stopped-refused; else ok guard-stopped-refused; fi
[ -d "$s" ] && ok guard-stopped-scratch-kept || no guard-stopped-scratch-kept

s=$(mkscratch g_unknown); reset_log
if bash "$R" g_unknown "$s" >/dev/null 2>&1; then no guard-unknown-refused; else ok guard-unknown-refused; fi
[ -d "$s" ] && ok guard-unknown-scratch-kept || no guard-unknown-scratch-kept
[ "$(rclone_calls)" = 0 ] && ok guard-unknown-no-rclone || no guard-unknown-no-rclone

# --- the delete target is DERIVED: only "<EXPERIMENT_SCRATCH_ROOT>/<run-id>" is ever reapable ---------
rec create b1 >/dev/null; rec close b1 >/dev/null
peer=$(mkscratch someone-elses-run); reset_log
if bash "$R" b1 "$peer" >/dev/null 2>&1; then no binding-peer-refused; else ok binding-peer-refused; fi
[ -d "$peer" ] && ok binding-peer-scratch-kept || no binding-peer-scratch-kept
[ "$(rclone_calls)" = 0 ] && ok binding-peer-no-rclone || no binding-peer-no-rclone

# Round-1 code-review Finding 2: the basename check alone accepted ANY dir named for the run, anywhere on
# the box. A same-named dir under a different root — a second checkout's work dir, a copy, a peer's tree —
# is not this run's scratch and must be refused without a byte being copied or deleted.
rec create b2 >/dev/null; rec close b2 >/dev/null
elsewhere="$TMP/elsewhere/b2"; mkdir -p "$elsewhere"; echo payload > "$elsewhere/out.txt"; reset_log
if bash "$R" b2 "$elsewhere" >/dev/null 2>&1; then no binding-other-root-refused; else ok binding-other-root-refused; fi
[ -d "$elsewhere" ] && ok binding-other-root-kept || no binding-other-root-kept
[ "$(rclone_calls)" = 0 ] && ok binding-other-root-no-rclone || no binding-other-root-no-rclone

# ...and a correctly-named dir NESTED below the root is not a direct child of it, so it is not the derived
# target either — the delete scope is exactly one path deep, not "anywhere under the root".
rec create b3 >/dev/null; rec close b3 >/dev/null
nested="$TMP/work/nested/b3"; mkdir -p "$nested"; echo payload > "$nested/out.txt"; reset_log
if bash "$R" b3 "$nested" >/dev/null 2>&1; then no binding-nested-refused; else ok binding-nested-refused; fi
[ -d "$nested" ] && ok binding-nested-kept || no binding-nested-kept

# --- no delete without a verified archive ----------------------------------------------------------
rec create f_copy >/dev/null; rec close f_copy >/dev/null
s=$(mkscratch f_copy); reset_log
if STUB_COPY_RC=3 bash "$R" f_copy "$s" >/dev/null 2>&1; then no copyfail-nonzero; else ok copyfail-nonzero; fi
[ -d "$s" ] && ok copyfail-scratch-kept || no copyfail-scratch-kept

rec create f_notice >/dev/null; rec close f_notice >/dev/null
s=$(mkscratch f_notice); reset_log
if STUB_COPY_NOTICE=1 bash "$R" f_notice "$s" >/dev/null 2>&1; then no notice-nonzero; else ok notice-nonzero; fi
[ -d "$s" ] && ok notice-scratch-kept || no notice-scratch-kept

rec create f_check >/dev/null; rec close f_check >/dev/null
s=$(mkscratch f_check); reset_log
if STUB_CHECK_RC=1 bash "$R" f_check "$s" >/dev/null 2>&1; then no checkfail-nonzero; else ok checkfail-nonzero; fi
[ -d "$s" ] && ok checkfail-scratch-kept || no checkfail-scratch-kept

rec create f_lsf >/dev/null; rec close f_lsf >/dev/null
s=$(mkscratch f_lsf); reset_log
if STUB_SKIP_STORE=1 bash "$R" f_lsf "$s" >/dev/null 2>&1; then no lsfmiss-nonzero; else ok lsfmiss-nonzero; fi
[ -d "$s" ] && ok lsfmiss-scratch-kept || no lsfmiss-scratch-kept

# --- unset seam / no rclone: documented NO-OPs (exit 0, nothing deleted, nothing invoked) ----------
rec create n1 >/dev/null; rec close n1 >/dev/null
s=$(mkscratch n1); reset_log
if env -u EXPERIMENT_SCRATCH_ARCHIVE_DEST bash "$R" n1 "$s" >/dev/null 2>&1; then ok noseam-exit0; else no noseam-exit0; fi
[ -d "$s" ] && ok noseam-scratch-kept || no noseam-scratch-kept
[ "$(rclone_calls)" = 0 ] && ok noseam-no-rclone || no noseam-no-rclone

rec create n3 >/dev/null; rec close n3 >/dev/null
s=$(mkscratch n3); reset_log
if env -u EXPERIMENT_SCRATCH_ROOT bash "$R" n3 "$s" >/dev/null 2>&1; then ok noroot-exit0; else no noroot-exit0; fi
[ -d "$s" ] && ok noroot-scratch-kept || no noroot-scratch-kept
[ "$(rclone_calls)" = 0 ] && ok noroot-no-rclone || no noroot-no-rclone

# A root that is set but unusable is a LOUD failure, not a no-op: the seam was configured, so a target the
# script cannot derive from it is a wiring error the caller must see — never a silent skip.
rec create n4 >/dev/null; rec close n4 >/dev/null
s=$(mkscratch n4); reset_log
if EXPERIMENT_SCRATCH_ROOT="relative/work" bash "$R" n4 "$s" >/dev/null 2>&1; then no relroot-refused; else ok relroot-refused; fi
[ -d "$s" ] && ok relroot-scratch-kept || no relroot-scratch-kept
if EXPERIMENT_SCRATCH_ROOT="$TMP/no-such-root" bash "$R" n4 "$s" >/dev/null 2>&1; then no missingroot-refused; else ok missingroot-refused; fi
[ -d "$s" ] && ok missingroot-scratch-kept || no missingroot-scratch-kept

rec create n2 >/dev/null; rec close n2 >/dev/null
s=$(mkscratch n2); reset_log
# A PATH that still resolves the standard tools (the script needs `bash`/`mktemp`) but not the stub. If
# the host happens to ship a REAL rclone there, this one case is skipped rather than asserted falsely.
BARE_PATH="/usr/bin:/bin"
if PATH="$BARE_PATH" command -v rclone >/dev/null 2>&1; then
  echo "skip norclone-exit0 (a real rclone is present on $BARE_PATH)"
else
  if env PATH="$BARE_PATH" bash "$R" n2 "$s" >/dev/null 2>&1; then ok norclone-exit0; else no norclone-exit0; fi
  [ -d "$s" ] && ok norclone-scratch-kept || no norclone-scratch-kept
fi

# --- path sanity ------------------------------------------------------------------------------------
rec create p_link >/dev/null; rec close p_link >/dev/null
real=$(mkscratch p_link_target); ln -s "$real" "$TMP/work/p_link"; reset_log
if bash "$R" p_link "$TMP/work/p_link" >/dev/null 2>&1; then no symlink-refused; else ok symlink-refused; fi
[ -d "$real" ] && ok symlink-target-kept || no symlink-target-kept

rec create p_wt >/dev/null
wt=$(mkscratch p_wt)
rec checkpoint p_wt --worktree "$wt" >/dev/null; rec close p_wt >/dev/null
reset_log
if bash "$R" p_wt "$wt" >/dev/null 2>&1; then no worktree-refused; else ok worktree-refused; fi
[ -d "$wt" ] && ok worktree-kept || no worktree-kept
[ "$(rclone_calls)" = 0 ] && ok worktree-no-rclone || no worktree-no-rclone

rec create p_cwd >/dev/null; rec close p_cwd >/dev/null
s=$(mkscratch p_cwd); reset_log
if (cd "$s" && bash "$R" p_cwd "$s" >/dev/null 2>&1); then no cwd-inside-refused; else ok cwd-inside-refused; fi
[ -d "$s" ] && ok cwd-inside-scratch-kept || no cwd-inside-scratch-kept

# --- the destination probe matches the run-id LITERALLY, not as a regex --------------------------------
# A run-id is a free-form identifier: a '.' in it must not match an arbitrary character in some OTHER
# archive prefix that happens to be listed under the same root.
rec create "run.x" >/dev/null; rec close "run.x" >/dev/null
s="$TMP/work/run.x"; mkdir -p "$s"; echo payload > "$s/out.txt"
mkdir -p "$STUB_STORE/runax"   # would match the regex `run.x/`, is NOT the intended archive
reset_log
if STUB_SKIP_STORE=1 bash "$R" "run.x" "$s" >/dev/null 2>&1; then no lsf-literal-match; else ok lsf-literal-match; fi
[ -d "$s" ] && ok lsf-literal-scratch-kept || no lsf-literal-scratch-kept
rm -rf "$STUB_STORE/runax"

# --- an EMPTY scratch tree still completes (round-2 code-review Finding 2) ---------------------------
# `rclone copy` creates no empty directories, so the destination-listing probe cannot pass for a tree with
# no files — it would strand every empty scratch dir on the box forever, which is the residue #792 exists
# to remove. Nothing is archived (there are no bytes), and rclone is never called for it.
rec create e1 >/dev/null; rec close e1 >/dev/null
s="$TMP/work/e1"; mkdir -p "$s/sub/deeper"; reset_log
if bash "$R" e1 "$s" >/dev/null 2>&1; then ok empty-exit0; else no empty-exit0; fi
[ -d "$s" ] && no empty-scratch-deleted || ok empty-scratch-deleted
[ "$(rclone_calls)" = 0 ] && ok empty-no-rclone || no empty-no-rclone

# ...but a tree whose only content is a SYMLINK is NOT empty: the -L copy turns it into a file at the
# destination, so it must take the full archive-and-verify path rather than the delete-outright branch.
rec create e2 >/dev/null; rec close e2 >/dev/null
s="$TMP/work/e2"; mkdir -p "$s"; ln -s "$TMP/store" "$s/link"; reset_log
if STUB_SKIP_STORE=1 bash "$R" e2 "$s" >/dev/null 2>&1; then no symlink-only-verified; else ok symlink-only-verified; fi
[ -d "$s" ] && ok symlink-only-scratch-kept || no symlink-only-scratch-kept
grep -q '^copy ' "$RCLONE_LOG" && ok symlink-only-archive-attempted || no symlink-only-archive-attempted

# --- argument validation ----------------------------------------------------------------------------
if bash "$R" only-one-arg >/dev/null 2>&1; then no args-refused; else ok args-refused; fi

[ "$fails" = 0 ] && { echo "reap_scratch smoke PASS"; exit 0; } || { echo "reap_scratch smoke FAIL"; exit 1; }
