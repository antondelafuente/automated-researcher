#!/usr/bin/env bash
# log_experiment_secret_scan_smoke.sh — offline behavior smoke for log-experiment.sh's secret_scan (#306),
# symlink_scan (#416), and check_excluded_files (#331).
#
# Drives the REAL script via `--dry-run` (which classifies, stages $REL in a worktree off origin/$BASE_BRANCH,
# runs the secret + symlink scans on the STAGED set, then stops BEFORE any push/token/network), against
# throwaway git fixtures. No engineer identity or network needed. Asserts the two #306 fixes end-to-end:
#   - staged-set scoping: a pre-existing merged file (even one that trips a pattern) does NOT block a log that
#     leaves it unchanged (it stages nothing); a NEWLY added / MODIFIED file carrying a real key DOES block.
#   - sk- boundary guard: a long hyphenated identifier merely CONTAINING `sk-` is not a false-positive, while
#     a genuine `sk-…` key (after a non-word char) still blocks.
# Plus: a non-ASCII staged path is scanned (NUL-delimited), a missing base ref fails CLOSED (refuse to log,
# no scan bypass), and an empty delta fails on "nothing to commit".
#
# #416: also asserts symlink_scan blocks ANY staged symlink — one pointing outside the repo (the original
# incident: a design-stage PR committing a git symlink into another session's /tmp scratchpad) AND one whose
# relative target happens to resolve inside the repo (wholesale rejection, not a resolve-and-judge heuristic)
# — and that it runs for the 'note' kind used throughout this smoke (symlink_scan runs for every KIND).
#
# Also asserts the #331 excluded-files gate: a file present in the staged dir but dropped by an ignore rule
# is always PRINTED, logging still PASSES when that drop is not falsely claimed committed, and logging BLOCKS
# when RESULTS.md / ARTIFACT_MANIFEST.md verbatim-claims the dropped file is committed (the exact silent
# prose/tree divergence #331 caught a day late). Plus review-round hardenings on that same gate: a
# non-ASCII-named staged file is never misread as excluded (git quotes such paths unless read with `ls-files
# -z`), an ignored SYMLINK claimed committed is caught (not just ignored regular files), and the commit-claim
# match is a same-line basename + specific word (committed/commit/in the registry/in this dir) instead of a
# loose 'committ' substring — so a bare "commit" claim is caught (previously missed) and a commit-claim word
# elsewhere in the doc on a different line does not false-positive block.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/log-experiment.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: log-experiment.sh not found next to smoke" >&2; exit 1; }

FAILS=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILS=$((FAILS+1)); }

# A committed anchor phrase that CONTAINS 'sk-' inside a long hyphenated identifier — the real #306 false-positive.
FP_LINE='anchor: my-agent-task-always-succeeds-in-suspicious-ways'
# Real-looking secret VALUES (assembled so this smoke file itself stays clean of a literal secret pattern).
REAL_SK="sk-$(printf 'a%.0s' {1..28})"                 # sk- + 28 chars, after a non-word boundary
REAL_GHP="ghp_$(printf 'A%.0s' {1..30})"

# make_repo <dir>: a fresh git repo with origin/main carrying a pre-existing journal page (the FP line).
make_repo() {
  local root="$1"
  git init -q -b main "$root"
  git -C "$root" config user.email smoke@test; git -C "$root" config user.name smoke
  mkdir -p "$root/reg/note"
  printf '%s\n' "$FP_LINE" > "$root/reg/note/page.html"
  git -C "$root" add -A; git -C "$root" commit -qm base
  git -C "$root" update-ref refs/remotes/origin/main main   # local stand-in for origin/main
  git -C "$root" checkout -q -b change/x
}

# make_repo_ignored <dir>: like make_repo, but origin/main ALREADY carries a `reg/**/*.jsonl` ignore rule (the
# rule must be on the BASE the worktree is created from — a rule added only on change/x would never make it
# into the staged worktree's checked-out tree).
make_repo_ignored() {
  local root="$1"
  git init -q -b main "$root"
  git -C "$root" config user.email smoke@test; git -C "$root" config user.name smoke
  printf 'reg/**/*.jsonl\n' > "$root/.gitignore"
  mkdir -p "$root/reg/note"
  printf '%s\n' "$FP_LINE" > "$root/reg/note/page.html"
  git -C "$root" add -A; git -C "$root" commit -qm base
  git -C "$root" update-ref refs/remotes/origin/main main
  git -C "$root" checkout -q -b change/x
}

# run_dry <dir>: run the gate under a clean XDG_CONFIG_HOME (no profile) + BASE_BRANCH=main. Echoes nothing;
# returns the script's exit code (0 = gate passed; non-zero = BLOCK). stderr captured to $LAST_ERR.
LAST_ERR=""
run_dry() {
  local dir="$1" cfg; cfg="$(mktemp -d)"
  local out; out="$(XDG_CONFIG_HOME="$cfg" AAR_PROFILE="" LOG_EXPERIMENT_BASE_BRANCH=main \
      bash "$SCRIPT" "$dir" --dry-run 2>&1)"; local rc=$?
  LAST_ERR="$out"; rm -rf "$cfg"; return $rc
}

echo "[smoke] case 1: unchanged pre-existing FP page + a clean new note -> PASS (was: blocked #306)"
T=$(mktemp -d); make_repo "$T"
printf 'a fresh note, no secrets\n' > "$T/reg/note/note1.md"
if run_dry "$T/reg/note"; then pass "clean new note logs despite pre-existing FP page"; else fail "clean note BLOCKED (regression): $LAST_ERR"; fi
rm -rf "$T"

echo "[smoke] case 2: NEW note containing a real sk- key -> BLOCK"
T=$(mktemp -d); make_repo "$T"
printf 'key = %s\n' "$REAL_SK" > "$T/reg/note/note2.md"
if run_dry "$T/reg/note"; then fail "real sk- key in a new file was NOT blocked"; else
  case "$LAST_ERR" in *"secret-value pattern"*) pass "new sk- key blocked";; *) fail "blocked but not on the secret scan: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 3: MODIFY the pre-existing page to add a real ghp_ token -> BLOCK"
T=$(mktemp -d); make_repo "$T"
printf 'token %s\n' "$REAL_GHP" >> "$T/reg/note/page.html"
if run_dry "$T/reg/note"; then fail "modified page with a real token was NOT blocked"; else
  case "$LAST_ERR" in *"secret-value pattern"*) pass "modified page blocked";; *) fail "blocked but not on the secret scan: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 4: the FP phrase added in a NEW file -> PASS (sk- boundary guard, no false-positive)"
T=$(mktemp -d); make_repo "$T"
printf '%s\n' "$FP_LINE" > "$T/reg/note/note4.md"
if run_dry "$T/reg/note"; then pass "hyphenated 'sk-' phrase is not a false-positive even when newly added"; else fail "boundary guard failed — FP phrase blocked: $LAST_ERR"; fi
rm -rf "$T"

echo "[smoke] case 5: no origin base ref -> FAIL CLOSED (refuse to log, no scan bypass) even with a new secret"
T=$(mktemp -d); make_repo "$T"
git -C "$T" update-ref -d refs/remotes/origin/main       # remove the base ref the log must be based on
printf 'k=%s\n' "$REAL_GHP" > "$T/reg/note/note5.md"     # a real secret present; must NOT slip through
if run_dry "$T/reg/note"; then fail "missing base ref did NOT refuse to log (possible scan bypass): $LAST_ERR"; else
  case "$LAST_ERR" in *"no origin/main ref"*) pass "missing base ref refuses to log (fail-closed)";; *) fail "failed but not on the missing base ref: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 6: empty delta (nothing changed vs base) -> refuse on 'nothing to commit'"
T=$(mktemp -d); make_repo "$T"   # branch head == origin/main, page.html unchanged, no new files
if run_dry "$T/reg/note"; then fail "empty delta did NOT refuse (should be nothing to commit): $LAST_ERR"; else
  case "$LAST_ERR" in *"nothing to commit"*) pass "empty delta refuses on nothing-to-commit";; *) fail "failed but not on nothing-to-commit: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 7: NEW file with a NON-ASCII name containing a real key -> BLOCK (NUL-delimited path handling)"
# git quotes non-ASCII paths in `diff --cached --name-only` by default; without -z the quoted string is not a
# real path and the staged file would be scan-skipped while still committed. -z emits raw paths so it is scanned.
T=$(mktemp -d); make_repo "$T"
printf 'k=%s\n' "$REAL_GHP" > "$T/reg/note/n"$'\303\266'"te.md"   # 'nöte.md' (UTF-8), staged as a new file
if run_dry "$T/reg/note"; then fail "non-ASCII-named file with a real key was NOT blocked (quoted-path skip)"; else
  case "$LAST_ERR" in *"secret-value pattern"*) pass "non-ASCII-named file scanned + blocked";; *) fail "blocked but not on the secret scan: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 8: NEW staged symlink pointing OUTSIDE the repo -> BLOCK (the #416 incident)"
T=$(mktemp -d); make_repo "$T"
printf 'a fresh clean note\n' > "$T/reg/note/note8.md"
ln -s /etc/passwd "$T/reg/note/bad_link"
git -C "$T" add -A
if run_dry "$T/reg/note"; then fail "symlink pointing outside the repo was NOT blocked"; else
  case "$LAST_ERR" in *"staged symlink"*) pass "symlink outside the repo blocked";; *) fail "blocked but not on the symlink scan: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 9: NEW staged symlink whose RELATIVE target resolves INSIDE the repo -> still BLOCK (wholesale reject, not resolve-and-judge)"
T=$(mktemp -d); make_repo "$T"
printf 'a fresh clean note\n' > "$T/reg/note/note9.md"
ln -s note9.md "$T/reg/note/rel_link"
git -C "$T" add -A
if run_dry "$T/reg/note"; then fail "symlink resolving inside the repo was NOT blocked"; else
  case "$LAST_ERR" in *"staged symlink"*) pass "in-repo-resolving symlink still blocked (wholesale reject)";; *) fail "blocked but not on the symlink scan: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 10: a new gitignored file with no committed-claim -> PASS, but PRINTED as excluded (#331)"
T=$(mktemp -d); make_repo_ignored "$T"
printf 'row\n' > "$T/reg/note/rollout_samples.jsonl"
printf 'a fresh note, no artifact claims\n' > "$T/reg/note/RESULTS.md"
if run_dry "$T/reg/note"; then
  case "$LAST_ERR" in *"excluded from staging"*"rollout_samples.jsonl"*) pass "excluded drop printed, log still passes";;
    *) fail "logged but the exclusion was not printed: $LAST_ERR";; esac
else fail "clean case BLOCKED (regression): $LAST_ERR"; fi
rm -rf "$T"

echo "[smoke] case 11: RESULTS.md verbatim-claims the dropped file is committed -> BLOCK (the #331 bug)"
T=$(mktemp -d); make_repo_ignored "$T"
printf 'row\n' > "$T/reg/note/rollout_samples.jsonl"
printf 'rollout_samples.jsonl is committed in the registry dir.\n' > "$T/reg/note/RESULTS.md"
if run_dry "$T/reg/note"; then fail "false 'committed' claim on a dropped file was NOT blocked"; else
  case "$LAST_ERR" in *"excluded file"*"rollout_samples.jsonl"*"claims it is committed"*) pass "false committed-claim blocked";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 12: ARTIFACT_MANIFEST.md verbatim-claims the dropped file is committed -> BLOCK"
T=$(mktemp -d); make_repo_ignored "$T"
printf 'row\n' > "$T/reg/note/rollout_samples.jsonl"
printf 'no artifact claims here\n' > "$T/reg/note/RESULTS.md"
printf '| rollout_samples.jsonl | committed | 67 rows |\n' > "$T/reg/note/ARTIFACT_MANIFEST.md"
if run_dry "$T/reg/note"; then fail "false 'committed' claim in ARTIFACT_MANIFEST.md was NOT blocked"; else
  case "$LAST_ERR" in *"excluded file"*"rollout_samples.jsonl"*"claims it is committed"*) pass "ARTIFACT_MANIFEST.md false claim blocked";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 13: RESULTS.md mentions the dropped filename WITHOUT 'committed' wording -> PASS (no false-positive)"
T=$(mktemp -d); make_repo_ignored "$T"
printf 'row\n' > "$T/reg/note/rollout_samples.jsonl"
printf 'rollout_samples.jsonl (67 rows) lives on R2, not in git.\n' > "$T/reg/note/RESULTS.md"
if run_dry "$T/reg/note"; then pass "filename mention without 'committed' wording does not false-positive block"; else
  fail "blocked despite no committed-claim wording: $LAST_ERR"; fi
rm -rf "$T"

echo "[smoke] case 14: an unchanged pre-existing tracked file -> PASS, NOT reported as excluded (no false-positive)"
T=$(mktemp -d); make_repo "$T"
printf 'a fresh note\n' > "$T/reg/note/note14.md"
if run_dry "$T/reg/note"; then
  case "$LAST_ERR" in *"excluded from staging"*) fail "spurious excluded-files warning on an unchanged pre-existing file: $LAST_ERR";;
    *) pass "pre-existing unchanged file (page.html) not misreported as excluded";; esac
else fail "clean note BLOCKED (regression): $LAST_ERR"; fi
rm -rf "$T"

echo "[smoke] case 15: NEW non-ASCII-named file that IS staged, claimed committed -> PASS, not falsely reported/blocked (git ls-files -z)"
# git quotes non-ASCII paths in `ls-files`'s default line output; without -z the quoted string never matches
# the raw path from `find`, so a genuinely-staged file would misread as excluded and, if claimed committed,
# falsely BLOCK a legitimate log (the wrong-direction failure mode: annoying, not a silent-drop risk).
T=$(mktemp -d); make_repo "$T"
NAME="n"$'\303\266'"te.md"                                        # 'nöte.md' (UTF-8)
printf 'a fresh note\n' > "$T/reg/note/$NAME"
printf '%s is committed in the registry dir.\n' "$NAME" > "$T/reg/note/RESULTS.md"
if run_dry "$T/reg/note"; then
  case "$LAST_ERR" in *"excluded from staging"*) fail "non-ASCII staged file falsely reported as excluded: $LAST_ERR";;
    *) pass "non-ASCII staged file correctly recognized as staged, no false exclusion/BLOCK";; esac
else fail "non-ASCII staged file (truly committed) falsely BLOCKED as excluded: $LAST_ERR"; fi
rm -rf "$T"

echo "[smoke] case 16: an IGNORED symlink claimed committed -> BLOCK (present-file enumeration must see symlinks, not just regular files)"
T=$(mktemp -d); make_repo_ignored "$T"
ln -s page.html "$T/reg/note/rollout_samples.jsonl"               # matches the base's reg/**/*.jsonl ignore rule
printf 'rollout_samples.jsonl is committed in the registry dir.\n' > "$T/reg/note/RESULTS.md"
if run_dry "$T/reg/note"; then fail "ignored symlink falsely claimed committed was NOT blocked (symlink missed by present-file scan)"; else
  case "$LAST_ERR" in *"excluded file"*"rollout_samples.jsonl"*"claims it is committed"*) pass "ignored symlink claimed committed is blocked";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 17: RESULTS.md uses bare 'commit' (not 'committed') on the same line -> BLOCK (prior 'committ' substring missed this — a real claim, not just a false-positive fix)"
T=$(mktemp -d); make_repo_ignored "$T"
printf 'row\n' > "$T/reg/note/rollout_samples.jsonl"
printf 'We commit rollout_samples.jsonl to the registry after review.\n' > "$T/reg/note/RESULTS.md"
if run_dry "$T/reg/note"; then fail "bare 'commit' claim on a dropped file was NOT blocked"; else
  case "$LAST_ERR" in *"excluded file"*"rollout_samples.jsonl"*"claims it is committed"*) pass "bare 'commit' claim blocked";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 18: RESULTS.md claims 'in this dir' (no 'commit'/'committed' word) on the same line -> BLOCK"
T=$(mktemp -d); make_repo_ignored "$T"
printf 'row\n' > "$T/reg/note/rollout_samples.jsonl"
printf 'rollout_samples.jsonl is in this dir, alongside the other artifacts.\n' > "$T/reg/note/RESULTS.md"
if run_dry "$T/reg/note"; then fail "'in this dir' claim on a dropped file was NOT blocked"; else
  case "$LAST_ERR" in *"excluded file"*"rollout_samples.jsonl"*"claims it is committed"*) pass "'in this dir' claim blocked";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 19: dropped filename and a 'committed' claim about something else appear on DIFFERENT lines -> PASS (no false-positive; same-line co-occurrence only)"
T=$(mktemp -d); make_repo_ignored "$T"
printf 'row\n' > "$T/reg/note/rollout_samples.jsonl"
printf 'rollout_samples.jsonl (67 rows) lives on R2, not in git.\nEverything else in this note is committed.\n' > "$T/reg/note/RESULTS.md"
if run_dry "$T/reg/note"; then pass "filename and unrelated 'committed' line on separate lines does not false-positive block"; else
  fail "blocked despite the commit-claim word being on a different line: $LAST_ERR"; fi
rm -rf "$T"

if [ "$FAILS" -eq 0 ]; then echo "[smoke] log-experiment secret-scan: ALL PASS"; exit 0; else
  echo "[smoke] log-experiment secret-scan: $FAILS FAILURE(S)" >&2; exit 1; fi
