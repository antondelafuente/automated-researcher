#!/usr/bin/env bash
# log_experiment_secret_scan_smoke.sh — offline behavior smoke for log-experiment.sh's secret_scan (#306),
# symlink_scan (#416), its ignored-file guard (#340) + committed-claim check (#331), and temp_handoff_scan (#332).
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
# #470/#471: also covers the design-stage KIND's Presentation-lock gate added to gate_design_stage: a valid
# `## Presentation (locked with the researcher <ISO date>)` header PASSes (case 24 also supplies a valid
# instance-profile snapshot, since gate_design_stage's #469 check runs after the lock check and would
# otherwise BLOCK it); a DESIGN.md with no lock header at all BLOCKs on "no locked Presentation section"; and
# a header with a digit-shaped but calendar-invalid date (e.g. 2026-99-99) BLOCKs the same way, since the gate
# round-trips the date through GNU `date` rather than trusting digit shape alone.
#
# #340: also covers a non-trivial file the BASE tree's .gitignore silently excludes from staging (even
# alongside other content that stages fine) BLOCKS and is listed; --skip-ignored explicitly acknowledges and
# proceeds; well-known junk (e.g. .DS_Store) never blocks on its own.
# #331: on top of that guard, an excluded file verbatim-claimed "committed" in RESULTS.md / ARTIFACT_MANIFEST.md
# BLOCKs with a specific message even when --skip-ignored is passed (the exact silent prose/tree divergence
# #331 caught a day late — an intentional R2 exclusion is fine, a doc that still claims the file landed is
# not). Also covers the review-round hardenings on that check: an ignored SYMLINK claimed committed is caught
# (not just ignored regular files, since it reuses check_ignored_files' `git ls-files --others --ignored
# --exclude-standard -z` list), the commit-claim match is a same-line basename + specific word (committed/
# commit/in the registry/in this dir) instead of a loose 'committ' substring — so a bare "commit" claim is
# caught (previously missed) and a commit-claim word elsewhere in the doc on a different line does not
# false-positive block — a courtesy negation filter (' not '/'n't ' on the same line) means "is not committed"
# does not false-positive block either — and a claim about a file inside a WHOLLY-ignored directory (not just
# an individually-ignored file) is still caught, since `ls-files` enumerates every file under an ignored
# directory individually rather than collapsing it to one directory entry the way `git status` does.
# #467: also covers check_excluded_claim's precision fix for the run-experiment scripts/ vs work/scripts/
# dual-copy layout — a commit-claim match downgrades to a printed note (not a BLOCK) when a file sharing the
# excluded file's basename IS staged elsewhere in the dir, while the original #331 scenario (no staged
# counterpart at all) still BLOCKs exactly as before.
#
# #374: also covers the `--only <path>` allowlist — a co-tenant's file left OUT of the allowlist is never
# staged and so never scanned/blocked by secret_scan or the #340 ignored-file guard, even when it sits right
# alongside the allowlisted file(s) in the same shared registry dir; a nonexistent or escaping (`/abs`,
# `../`) --only path BLOCKs (fail-closed — never silently falls back to staging the whole dir); an allowlist
# that stages nothing (the named file is unchanged vs base) BLOCKs on nothing-to-commit same as the
# unscoped case; and a --only path that is itself gitignored is still caught by the #340 guard (the
# allowlist narrows scope, it does not disable the existing gates). Also covers a review-round hardening:
# --only is refused outright for a dir that classifies as KIND != note (e.g. design-stage/experiment),
# since those gates read their audit/design evidence straight from $DIR rather than the allowlisted staged
# set — narrowing there could approve/merge a record whose cited evidence never actually gets committed.
# Also covers a further review-round hardening: a --only path that is itself a symlink is staged (and then
# symlink-scan-BLOCKed) as the named symlink, never resolved to its canonical target — the target-resolving
# behavior would otherwise silently stage/scan a co-tenant's file under a name the caller never asked for.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/log-experiment.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: log-experiment.sh not found next to smoke" >&2; exit 1; }

FAILS=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILS=$((FAILS+1)); }

# mktemp_d: mktemp -d, but refuses to hand back an empty/non-existent path — every fixture and config dir in
# this smoke is scoped under a dir from this helper, then rm -rf'd by name, so a bad path here (e.g. "") would
# otherwise turn later `git -C "$dir"` / `rm -rf "$dir"` calls into ops against the caller's own cwd/root.
mktemp_d() {
  local d
  d="$(mktemp -d)"
  [ -n "$d" ] && [ -d "$d" ] || { echo "FAIL: mktemp -d returned an empty/non-existent path" >&2; exit 1; }
  printf '%s\n' "$d"
}

# A committed anchor phrase that CONTAINS 'sk-' inside a long hyphenated identifier — the real #306 false-positive.
FP_LINE='anchor: my-agent-task-always-succeeds-in-suspicious-ways'
# Real-looking secret VALUES (assembled so this smoke file itself stays clean of a literal secret pattern).
REAL_SK="sk-$(printf 'a%.0s' {1..28})"                 # sk- + 28 chars, after a non-word boundary
REAL_GHP="ghp_$(printf 'A%.0s' {1..30})"
# A format-valid (but not a real content hash) 64-hex-character sha256-shaped digest, for dataset MANIFEST.md fixtures.
FAKE_SHA256="$(printf '0123456789abcdef%.0s' {1..4})"

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

# run_dry <dir> [extra-args...]: run the gate under a clean XDG_CONFIG_HOME (no profile) + BASE_BRANCH=main.
# Echoes nothing; returns the script's exit code (0 = gate passed; non-zero = BLOCK). stderr captured to $LAST_ERR.
LAST_ERR=""
run_dry() {
  local dir="$1"; shift; local cfg; cfg="$(mktemp_d)" || return 1
  local out; out="$(XDG_CONFIG_HOME="$cfg" AAR_PROFILE="" LOG_EXPERIMENT_BASE_BRANCH=main \
      bash "$SCRIPT" "$dir" --dry-run "$@" 2>&1)"; local rc=$?
  LAST_ERR="$out"; rm -rf "$cfg"; return $rc
}

# make_design_stage_repo <dir>: a fresh git repo with an EMPTY base commit, checked out onto change/x so a
# reg/design dir added afterward (DESIGN.md + DESIGN_AUDIT.md, no RESULTS.md) is entirely NEW content and
# stages cleanly — exercises the design-stage KIND's Presentation-lock gate (#470/#471) added to
# gate_design_stage, not the note-kind secret-scan cases above.
make_design_stage_repo() {
  local root="$1"
  git init -q -b main "$root"
  git -C "$root" config user.email smoke@test; git -C "$root" config user.name smoke
  mkdir -p "$root/reg"
  printf 'placeholder\n' > "$root/reg/.keep"
  git -C "$root" add -A; git -C "$root" commit -qm base
  git -C "$root" update-ref refs/remotes/origin/main main
  git -C "$root" checkout -q -b change/x
  mkdir -p "$root/reg/design"
}

# make_repo_with_gitignore <dir> <gitignore-content>: like make_repo, but the BASE commit also carries a
# .gitignore (the ignored-file guard is decided by the BASE tree the worktree checks out, not the working
# tree — see log-experiment.sh's stage_worktree comment).
make_repo_with_gitignore() {
  local root="$1" ignore="$2"
  git init -q -b main "$root"
  git -C "$root" config user.email smoke@test; git -C "$root" config user.name smoke
  mkdir -p "$root/reg/note"
  printf '%s\n' "$FP_LINE" > "$root/reg/note/page.html"
  printf '%s\n' "$ignore" > "$root/.gitignore"
  git -C "$root" add -A; git -C "$root" commit -qm base
  git -C "$root" update-ref refs/remotes/origin/main main
  git -C "$root" checkout -q -b change/x
}

echo "[smoke] case 1: unchanged pre-existing FP page + a clean new note -> PASS (was: blocked #306)"
T=$(mktemp_d); make_repo "$T"
printf 'a fresh note, no secrets\n' > "$T/reg/note/note1.md"
if run_dry "$T/reg/note"; then pass "clean new note logs despite pre-existing FP page"; else fail "clean note BLOCKED (regression): $LAST_ERR"; fi
rm -rf "$T"

echo "[smoke] case 2: NEW note containing a real sk- key -> BLOCK"
T=$(mktemp_d); make_repo "$T"
printf 'key = %s\n' "$REAL_SK" > "$T/reg/note/note2.md"
if run_dry "$T/reg/note"; then fail "real sk- key in a new file was NOT blocked"; else
  case "$LAST_ERR" in *"secret-value pattern"*) pass "new sk- key blocked";; *) fail "blocked but not on the secret scan: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 3: MODIFY the pre-existing page to add a real ghp_ token -> BLOCK"
T=$(mktemp_d); make_repo "$T"
printf 'token %s\n' "$REAL_GHP" >> "$T/reg/note/page.html"
if run_dry "$T/reg/note"; then fail "modified page with a real token was NOT blocked"; else
  case "$LAST_ERR" in *"secret-value pattern"*) pass "modified page blocked";; *) fail "blocked but not on the secret scan: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 4: the FP phrase added in a NEW file -> PASS (sk- boundary guard, no false-positive)"
T=$(mktemp_d); make_repo "$T"
printf '%s\n' "$FP_LINE" > "$T/reg/note/note4.md"
if run_dry "$T/reg/note"; then pass "hyphenated 'sk-' phrase is not a false-positive even when newly added"; else fail "boundary guard failed — FP phrase blocked: $LAST_ERR"; fi
rm -rf "$T"

echo "[smoke] case 5: no origin base ref -> FAIL CLOSED (refuse to log, no scan bypass) even with a new secret"
T=$(mktemp_d); make_repo "$T"
git -C "$T" update-ref -d refs/remotes/origin/main       # remove the base ref the log must be based on
printf 'k=%s\n' "$REAL_GHP" > "$T/reg/note/note5.md"     # a real secret present; must NOT slip through
if run_dry "$T/reg/note"; then fail "missing base ref did NOT refuse to log (possible scan bypass): $LAST_ERR"; else
  case "$LAST_ERR" in *"no origin/main ref"*) pass "missing base ref refuses to log (fail-closed)";; *) fail "failed but not on the missing base ref: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 6: empty delta (nothing changed vs base) -> refuse on 'nothing to commit'"
T=$(mktemp_d); make_repo "$T"   # branch head == origin/main, page.html unchanged, no new files
if run_dry "$T/reg/note"; then fail "empty delta did NOT refuse (should be nothing to commit): $LAST_ERR"; else
  case "$LAST_ERR" in *"nothing to commit"*) pass "empty delta refuses on nothing-to-commit";; *) fail "failed but not on nothing-to-commit: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 7: NEW file with a NON-ASCII name containing a real key -> BLOCK (NUL-delimited path handling)"
# git quotes non-ASCII paths in `diff --cached --name-only` by default; without -z the quoted string is not a
# real path and the staged file would be scan-skipped while still committed. -z emits raw paths so it is scanned.
T=$(mktemp_d); make_repo "$T"
printf 'k=%s\n' "$REAL_GHP" > "$T/reg/note/n"$'\303\266'"te.md"   # 'nöte.md' (UTF-8), staged as a new file
if run_dry "$T/reg/note"; then fail "non-ASCII-named file with a real key was NOT blocked (quoted-path skip)"; else
  case "$LAST_ERR" in *"secret-value pattern"*) pass "non-ASCII-named file scanned + blocked";; *) fail "blocked but not on the secret scan: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 8: NEW staged symlink pointing OUTSIDE the repo -> BLOCK (the #416 incident)"
T=$(mktemp_d); make_repo "$T"
printf 'a fresh clean note\n' > "$T/reg/note/note8.md"
ln -s /etc/passwd "$T/reg/note/bad_link"
git -C "$T" add -A
if run_dry "$T/reg/note"; then fail "symlink pointing outside the repo was NOT blocked"; else
  case "$LAST_ERR" in *"staged symlink"*) pass "symlink outside the repo blocked";; *) fail "blocked but not on the symlink scan: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 9: NEW staged symlink whose RELATIVE target resolves INSIDE the repo -> still BLOCK (wholesale reject, not resolve-and-judge)"
T=$(mktemp_d); make_repo "$T"
printf 'a fresh clean note\n' > "$T/reg/note/note9.md"
ln -s note9.md "$T/reg/note/rel_link"
git -C "$T" add -A
if run_dry "$T/reg/note"; then fail "symlink resolving inside the repo was NOT blocked"; else
  case "$LAST_ERR" in *"staged symlink"*) pass "in-repo-resolving symlink still blocked (wholesale reject)";; *) fail "blocked but not on the symlink scan: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 10: a pinned .jsonl silently gitignored alongside other content that stages fine -> BLOCK (#340)"
T=$(mktemp_d); make_repo_with_gitignore "$T" '*.jsonl'
printf 'notes\n' > "$T/reg/note/note10.md"                      # a normal new file — stages fine
printf '{"in": "battery"}\n' > "$T/reg/note/battery.jsonl"      # pinned instrument file — silently gitignored
if run_dry "$T/reg/note"; then fail "gitignored pinned file was NOT blocked (#340 regression) — record looked complete but dropped battery.jsonl"; else
  case "$LAST_ERR" in *"gitignored file"*"battery.jsonl"*) pass "gitignored pinned file blocked and listed, even though other content staged fine";; *) fail "blocked but not on the ignored-file guard: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 11: same gitignored pinned file, but with --skip-ignored -> PASS (explicit acknowledgment)"
T=$(mktemp_d); make_repo_with_gitignore "$T" '*.jsonl'
printf 'notes\n' > "$T/reg/note/note11.md"
printf '{"in": "battery"}\n' > "$T/reg/note/battery.jsonl"
if run_dry "$T/reg/note" --skip-ignored; then pass "--skip-ignored proceeds past the ignored-file guard"; else
  fail "--skip-ignored did NOT bypass the guard: $LAST_ERR"; fi
rm -rf "$T"

echo "[smoke] case 12: only a trivial ignored file (.DS_Store) -> PASS, no block (junk filter)"
T=$(mktemp_d); make_repo_with_gitignore "$T" '.DS_Store'
printf 'notes\n' > "$T/reg/note/note12.md"
touch "$T/reg/note/.DS_Store"
if run_dry "$T/reg/note"; then pass "trivial .DS_Store ignore does not block"; else
  fail "trivial-only ignore blocked (should not): $LAST_ERR"; fi
rm -rf "$T"

echo "[smoke] case 13: gitignored file with no committed-claim, --skip-ignored -> PASS, still PRINTED as excluded (#331)"
T=$(mktemp_d); make_repo_with_gitignore "$T" 'reg/**/*.jsonl'
printf 'row\n' > "$T/reg/note/rollout_samples.jsonl"
printf 'a fresh note, no artifact claims\n' > "$T/reg/note/RESULTS.md"
if run_dry "$T/reg/note" --skip-ignored; then
  case "$LAST_ERR" in *"gitignored file"*"rollout_samples.jsonl"*) pass "excluded drop printed, log still passes";;
    *) fail "logged but the exclusion was not printed: $LAST_ERR";; esac
else fail "clean case BLOCKED (regression): $LAST_ERR"; fi
rm -rf "$T"

echo "[smoke] case 14: RESULTS.md verbatim-claims the dropped file is committed, WITHOUT --skip-ignored -> BLOCK with the specific claims message (#331 gate composed into the #340 default-block path)"
T=$(mktemp_d); make_repo_with_gitignore "$T" 'reg/**/*.jsonl'
printf 'row\n' > "$T/reg/note/rollout_samples.jsonl"
printf 'rollout_samples.jsonl is committed in the registry dir.\n' > "$T/reg/note/RESULTS.md"
if run_dry "$T/reg/note"; then fail "false 'committed' claim on a dropped file was NOT blocked"; else
  case "$LAST_ERR" in *"excluded file"*"rollout_samples.jsonl"*"claims it is committed"*) pass "false committed-claim blocked with the specific message";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 15: same false 'committed' claim, but WITH --skip-ignored -> still BLOCK (the #331 bug: --skip-ignored must never wave through a doc/tree divergence)"
T=$(mktemp_d); make_repo_with_gitignore "$T" 'reg/**/*.jsonl'
printf 'row\n' > "$T/reg/note/rollout_samples.jsonl"
printf 'rollout_samples.jsonl is committed in the registry dir.\n' > "$T/reg/note/RESULTS.md"
if run_dry "$T/reg/note" --skip-ignored; then fail "--skip-ignored bypassed a false 'committed' claim (the #331 incident)"; else
  case "$LAST_ERR" in *"excluded file"*"rollout_samples.jsonl"*"claims it is committed"*) pass "--skip-ignored does NOT bypass a false committed-claim";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 16: ARTIFACT_MANIFEST.md verbatim-claims the dropped file is committed, --skip-ignored -> BLOCK"
T=$(mktemp_d); make_repo_with_gitignore "$T" 'reg/**/*.jsonl'
printf 'row\n' > "$T/reg/note/rollout_samples.jsonl"
printf 'no artifact claims here\n' > "$T/reg/note/RESULTS.md"
printf '| rollout_samples.jsonl | committed | 67 rows |\n' > "$T/reg/note/ARTIFACT_MANIFEST.md"
if run_dry "$T/reg/note" --skip-ignored; then fail "false 'committed' claim in ARTIFACT_MANIFEST.md was NOT blocked"; else
  case "$LAST_ERR" in *"excluded file"*"rollout_samples.jsonl"*"claims it is committed"*) pass "ARTIFACT_MANIFEST.md false claim blocked";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 17: RESULTS.md mentions the dropped filename WITHOUT 'committed' wording, --skip-ignored -> PASS (no false-positive)"
T=$(mktemp_d); make_repo_with_gitignore "$T" 'reg/**/*.jsonl'
printf 'row\n' > "$T/reg/note/rollout_samples.jsonl"
printf 'rollout_samples.jsonl (67 rows) lives on R2, not in git.\n' > "$T/reg/note/RESULTS.md"
if run_dry "$T/reg/note" --skip-ignored; then pass "filename mention without 'committed' wording does not false-positive block"; else
  fail "blocked despite no committed-claim wording: $LAST_ERR"; fi
rm -rf "$T"

echo "[smoke] case 18: an IGNORED symlink claimed committed, --skip-ignored -> BLOCK (check_ignored_files' status --ignored=matching list covers symlinks too, not just regular files)"
T=$(mktemp_d); make_repo_with_gitignore "$T" 'reg/**/*.jsonl'
ln -s page.html "$T/reg/note/rollout_samples.jsonl"               # matches the base's reg/**/*.jsonl ignore rule
printf 'rollout_samples.jsonl is committed in the registry dir.\n' > "$T/reg/note/RESULTS.md"
if run_dry "$T/reg/note" --skip-ignored; then fail "ignored symlink falsely claimed committed was NOT blocked"; else
  case "$LAST_ERR" in *"excluded file"*"rollout_samples.jsonl"*"claims it is committed"*) pass "ignored symlink claimed committed is blocked";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 19: RESULTS.md uses bare 'commit' (not 'committed') on the same line, --skip-ignored -> BLOCK (a real claim, not just a false-positive fix)"
T=$(mktemp_d); make_repo_with_gitignore "$T" 'reg/**/*.jsonl'
printf 'row\n' > "$T/reg/note/rollout_samples.jsonl"
printf 'We commit rollout_samples.jsonl to the registry after review.\n' > "$T/reg/note/RESULTS.md"
if run_dry "$T/reg/note" --skip-ignored; then fail "bare 'commit' claim on a dropped file was NOT blocked"; else
  case "$LAST_ERR" in *"excluded file"*"rollout_samples.jsonl"*"claims it is committed"*) pass "bare 'commit' claim blocked";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 20: RESULTS.md claims 'in this dir' (no 'commit'/'committed' word) on the same line, --skip-ignored -> BLOCK"
T=$(mktemp_d); make_repo_with_gitignore "$T" 'reg/**/*.jsonl'
printf 'row\n' > "$T/reg/note/rollout_samples.jsonl"
printf 'rollout_samples.jsonl is in this dir, alongside the other artifacts.\n' > "$T/reg/note/RESULTS.md"
if run_dry "$T/reg/note" --skip-ignored; then fail "'in this dir' claim on a dropped file was NOT blocked"; else
  case "$LAST_ERR" in *"excluded file"*"rollout_samples.jsonl"*"claims it is committed"*) pass "'in this dir' claim blocked";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 21: dropped filename and a 'committed' claim about something else appear on DIFFERENT lines, --skip-ignored -> PASS (no false-positive; same-line co-occurrence only)"
T=$(mktemp_d); make_repo_with_gitignore "$T" 'reg/**/*.jsonl'
printf 'row\n' > "$T/reg/note/rollout_samples.jsonl"
printf 'rollout_samples.jsonl (67 rows) lives on R2, not in git.\nEverything else in this note is committed.\n' > "$T/reg/note/RESULTS.md"
if run_dry "$T/reg/note" --skip-ignored; then pass "filename and unrelated 'committed' line on separate lines does not false-positive block"; else
  fail "blocked despite the commit-claim word being on a different line: $LAST_ERR"; fi
rm -rf "$T"

echo "[smoke] case 22: RESULTS.md says the dropped file is 'not committed' (negated), --skip-ignored -> PASS (courtesy negation filter)"
T=$(mktemp_d); make_repo_with_gitignore "$T" 'reg/**/*.jsonl'
printf 'row\n' > "$T/reg/note/rollout_samples.jsonl"
printf 'rollout_samples.jsonl is not committed; it lives on R2.\n' > "$T/reg/note/RESULTS.md"
if run_dry "$T/reg/note" --skip-ignored; then pass "negated 'is not committed' claim does not false-positive block"; else
  fail "blocked despite the claim being negated ('not committed'): $LAST_ERR"; fi
rm -rf "$T"

echo "[smoke] case 23: dropped file lives inside a WHOLLY-ignored directory (not an individually-ignored file), RESULTS.md claims it's committed, WITHOUT --skip-ignored -> BLOCK (ls-files enumerates files inside the ignored dir, not just the dir's own basename)"
T=$(mktemp_d); make_repo_with_gitignore "$T" 'artifacts/'
mkdir -p "$T/reg/note/artifacts"
printf 'row\n' > "$T/reg/note/artifacts/rollout_samples.jsonl"
printf 'rollout_samples.jsonl is committed in the registry dir.\n' > "$T/reg/note/RESULTS.md"
if run_dry "$T/reg/note"; then fail "false 'committed' claim on a file inside a wholly-ignored directory was NOT blocked"; else
  case "$LAST_ERR" in *"excluded file"*"rollout_samples.jsonl"*"claims it is committed"*) pass "claim about a file inside a wholly-ignored directory is blocked";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 24: design-stage DESIGN.md with a valid locked Presentation header + a valid instance-profile snapshot -> PASS (#469/#470/#471)"
T=$(mktemp_d); make_design_stage_repo "$T"
printf '# Design\n\n## Presentation (locked with the researcher 2026-07-14)\nDetails.\n' > "$T/reg/design/DESIGN.md"
printf 'design-audit findings, clean\n' > "$T/reg/design/DESIGN_AUDIT.md"
cfg24="$(mktemp_d)"; mkdir -p "$cfg24/experiment-lifecycle"
cat > "$cfg24/experiment-lifecycle/aar-profile.toml" <<'EOF'
schema_version = 1
[github]
research_repo = "owner/example-repo"
base_branch = "main"
branch_prefix = "run/"
private = true
EOF
printf '# START.md\n\n## Your one job\ndo a thing\n' > "$T/reg/design/START.md"
XDG_CONFIG_HOME="$cfg24" AAR_PROFILE="" bash "$SELF_DIR/aar_profile_snapshot.sh" snapshot "$T/reg/design/START.md" >/dev/null
out24="$(XDG_CONFIG_HOME="$cfg24" AAR_PROFILE="" LOG_EXPERIMENT_BASE_BRANCH=main bash "$SCRIPT" "$T/reg/design" --dry-run 2>&1)"; rc24=$?
rm -rf "$cfg24"
if [ "$rc24" -eq 0 ]; then pass "design-stage with a valid lock header + valid snapshot passes the gate"; else
  fail "valid lock header + snapshot BLOCKED (regression): $out24"; fi
rm -rf "$T"

echo "[smoke] case 25: design-stage DESIGN.md with NO lock header -> BLOCK ('no locked Presentation section')"
T=$(mktemp_d); make_design_stage_repo "$T"
printf '# Design\n\n## Presentation\nDetails, not yet locked.\n' > "$T/reg/design/DESIGN.md"
printf 'design-audit findings, clean\n' > "$T/reg/design/DESIGN_AUDIT.md"
if run_dry "$T/reg/design"; then fail "design-stage with no lock header was NOT blocked"; else
  case "$LAST_ERR" in *"no locked Presentation section"*) pass "missing lock header blocked";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 26: design-stage DESIGN.md with a malformed calendar date in the lock header -> BLOCK (digit-shape alone would accept this)"
T=$(mktemp_d); make_design_stage_repo "$T"
printf '# Design\n\n## Presentation (locked with the researcher 2026-99-99)\nDetails.\n' > "$T/reg/design/DESIGN.md"
printf 'design-audit findings, clean\n' > "$T/reg/design/DESIGN_AUDIT.md"
if run_dry "$T/reg/design"; then fail "malformed calendar date (2026-99-99) was NOT blocked"; else
  case "$LAST_ERR" in *"no locked Presentation section"*) pass "malformed calendar date blocked";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac; fi
rm -rf "$T"

# #374: --only allowlist — restricts the staged set (and, transitively, check_ignored_files/secret_scan/
# symlink_scan, which all scan whatever ends up staged) to exactly the named path(s), so a co-tenant
# session's untracked files under a SHARED multi-tenant registry dir never sweep into this PR.

echo "[smoke] case 27: --only names one clean new file; a co-tenant's file with a real secret sits alongside it -> PASS (the co-tenant file is never staged, so it is never scanned)"
T=$(mktemp_d); make_repo "$T"
printf 'my own clean file\n' > "$T/reg/note/mine.md"
printf 'token %s\n' "$REAL_GHP" > "$T/reg/note/cotenant_secret.md"
if run_dry "$T/reg/note" --only mine.md; then pass "--only stages just the named file; the co-tenant's secret file alongside it is never scanned"; else
  fail "--only mine.md was BLOCKED despite the co-tenant secret file being outside the allowlist: $LAST_ERR"; fi
rm -rf "$T"

echo "[smoke] case 28: repeated --only flags name two files; a co-tenant's secret file is left out -> PASS"
T=$(mktemp_d); make_repo "$T"
printf 'file a\n' > "$T/reg/note/a.md"
printf 'file b\n' > "$T/reg/note/b.md"
printf 'token %s\n' "$REAL_GHP" > "$T/reg/note/cotenant_secret.md"
if run_dry "$T/reg/note" --only a.md --only b.md; then pass "repeated --only flags stage exactly the two named files"; else
  fail "--only a.md --only b.md was BLOCKED: $LAST_ERR"; fi
rm -rf "$T"

echo "[smoke] case 29: --only names a path that does not exist under the registry dir -> BLOCK (fail closed, never falls back to the whole dir)"
T=$(mktemp_d); make_repo "$T"
printf 'my own clean file\n' > "$T/reg/note/mine.md"
if run_dry "$T/reg/note" --only missing.md; then fail "--only missing.md was NOT blocked"; else
  case "$LAST_ERR" in *"--only path does not exist under"*) pass "nonexistent --only path blocked";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 30: --only given an absolute path -> BLOCK"
T=$(mktemp_d); make_repo "$T"
if run_dry "$T/reg/note" --only /etc/passwd; then fail "--only with an absolute path was NOT blocked"; else
  case "$LAST_ERR" in *"must be relative to the registry dir, not absolute"*) pass "absolute --only path blocked";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 31: --only escapes the registry dir via '../' to a real file OUTSIDE it -> BLOCK (existence alone is not enough; containment is also checked)"
T=$(mktemp_d); make_repo "$T"
mkdir -p "$T/reg/sibling"
printf 'not mine\n' > "$T/reg/sibling/file.txt"
if run_dry "$T/reg/note" --only ../sibling/file.txt; then fail "--only escaping via '../' to a real file was NOT blocked"; else
  case "$LAST_ERR" in *"escapes the registry dir"*) pass "'../'-escaping --only path blocked";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 32: --only names the one file changed, but it is UNCHANGED vs base -> BLOCK on nothing-to-commit (never silently stages the whole dir instead)"
T=$(mktemp_d); make_repo "$T"   # page.html is already committed on origin/main, unchanged
if run_dry "$T/reg/note" --only page.html; then fail "--only on an unchanged file did NOT refuse (should be nothing to commit)"; else
  case "$LAST_ERR" in *"nothing to commit"*"--only"*) pass "--only on an unchanged file refuses on nothing-to-commit";;
    *) fail "failed but not on the expected nothing-to-commit message: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 33: --only names a clean file; a co-tenant's GITIGNORED file sits alongside it -> PASS (the ignored-file guard is scoped to the allowlist too, not just the secret scan)"
T=$(mktemp_d); make_repo_with_gitignore "$T" '*.jsonl'
printf 'my own clean file\n' > "$T/reg/note/mine.md"
printf '{"not": "mine"}\n' > "$T/reg/note/cotenant.jsonl"
if run_dry "$T/reg/note" --only mine.md; then pass "--only scopes the gitignored-file guard too — a co-tenant's ignored file elsewhere in the dir does not block"; else
  fail "--only mine.md was BLOCKED by a co-tenant's unrelated gitignored file: $LAST_ERR"; fi
rm -rf "$T"

echo "[smoke] case 34: --only names a file that is itself GITIGNORED -> still BLOCK (the guard still catches an allowlisted path that silently failed to stage)"
T=$(mktemp_d); make_repo_with_gitignore "$T" '*.jsonl'
printf '{"in": "battery"}\n' > "$T/reg/note/mine.jsonl"
if run_dry "$T/reg/note" --only mine.jsonl; then fail "--only on a gitignored path was NOT blocked (#340 guard should still apply within the allowlist)"; else
  case "$LAST_ERR" in *"gitignored file"*"mine.jsonl"*) pass "gitignored --only path still caught by the ignored-file guard";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 35: --only against a design-stage dir (KIND != note) -> BLOCK (review finding: gate_design_stage/gate_experiment read their audit evidence from \$DIR, not the --only-narrowed staged set, so narrowing there could approve a record whose cited evidence never lands in the commit)"
T=$(mktemp_d); make_design_stage_repo "$T"
printf '# Design\n\n## Presentation (locked with the researcher 2026-07-14)\nDetails.\n' > "$T/reg/design/DESIGN.md"
printf 'design-audit findings, clean\n' > "$T/reg/design/DESIGN_AUDIT.md"
if run_dry "$T/reg/design" --only DESIGN.md; then fail "--only on a design-stage dir was NOT blocked"; else
  case "$LAST_ERR" in *"--only is only supported for KIND=note"*) pass "--only on a design-stage dir refused";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 36: --only names a path that is itself a SYMLINK to a co-tenant's secret file -> BLOCK on the staged symlink itself, NOT on the co-tenant's secret content (#586 review: --only must not resolve a named symlink to its canonical target, which would silently stage/scan the co-tenant's file under a name the caller never asked for)"
T=$(mktemp_d); make_repo "$T"
printf 'token %s\n' "$REAL_GHP" > "$T/reg/note/cotenant_secret.md"
ln -s cotenant_secret.md "$T/reg/note/mine.py"
if run_dry "$T/reg/note" --only mine.py; then fail "--only on a symlink to a co-tenant's file was NOT blocked"; else
  case "$LAST_ERR" in
    *"staged symlink"*) pass "--only stages the named symlink as-is; symlink_scan blocks it (co-tenant target never substituted in)";;
    *"secret-value pattern"*) fail "REGRESSION: --only resolved the symlink to its target and staged/scanned the co-tenant's file instead of the named symlink: $LAST_ERR";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac; fi
rm -rf "$T"

# #358: also covers the first-class 'exploration' (FINDINGS.md, no DESIGN.md) and 'dataset' (MANIFEST.md, no
# DESIGN.md) record kinds (research-lab#136) — auto-classification, the KIND override no longer dying with
# "unknown KIND override" for these two values, their structural gates (Status: EXPLORATORY header;
# sha256 table + r2:// path), that the shared secret scan still runs for both, that DESIGN.md takes
# precedence over FINDINGS.md/MANIFEST.md in auto-classification, and that --only is still refused for both
# (same #374 restriction as design-stage/experiment, since their gates read evidence straight from $DIR).
#
# #467: check_excluded_claim's basename+commit-claim match false-positived when the SAME basename legitimately
# exists TWICE by design — once committed outside work/, once as a gitignored working copy under work/ (the
# run-experiment R2-mirrored dual-copy layout). Downgrade to a note ONLY when a same-basename file IS staged.

echo "[smoke] case 37: RESULTS.md claims a gitignored file is committed, a SAME-BASENAME file IS staged elsewhere under the dir (the run-experiment scripts/ vs work/scripts/ dual-copy layout), WITH --skip-ignored -> PASS with a downgrade note, not a BLOCK (#467; --skip-ignored still needed to acknowledge the #340 exclusion itself — only the #331 commit-claim die is downgraded)"
T=$(mktemp_d); make_repo_with_gitignore "$T" 'reg/note/work/'
mkdir -p "$T/reg/note/scripts" "$T/reg/note/work/scripts"
printf 'print("hi")\n' > "$T/reg/note/scripts/foo.py"        # committed copy — new, stages fine
printf 'print("hi")\n' > "$T/reg/note/work/scripts/foo.py"   # gitignored working copy, same basename
printf 'foo.py is committed in the registry dir.\n' > "$T/reg/note/RESULTS.md"
if run_dry "$T/reg/note" --skip-ignored; then
  case "$LAST_ERR" in *"shares a basename with a file that IS staged"*"foo.py"*) pass "commit-claim downgraded to a note when a same-basename file is staged elsewhere";;
    *) fail "passed but the expected downgrade note was not printed: $LAST_ERR";; esac
else fail "dual-copy layout with a staged same-basename counterpart was BLOCKED (regression): $LAST_ERR"; fi
rm -rf "$T"

echo "[smoke] case 37b: same dual-copy layout as case 37, but WITHOUT --skip-ignored -> BLOCK on the #340 exclusion itself (the commit-claim die is downgraded, but the general gitignored-file guard still requires explicit acknowledgment)"
T=$(mktemp_d); make_repo_with_gitignore "$T" 'reg/note/work/'
mkdir -p "$T/reg/note/scripts" "$T/reg/note/work/scripts"
printf 'print("hi")\n' > "$T/reg/note/scripts/foo.py"
printf 'print("hi")\n' > "$T/reg/note/work/scripts/foo.py"
printf 'foo.py is committed in the registry dir.\n' > "$T/reg/note/RESULTS.md"
if run_dry "$T/reg/note"; then fail "gitignored file(s) present with no --skip-ignored did NOT block (#340 guard should still require acknowledgment)"; else
  case "$LAST_ERR" in
    *"shares a basename with a file that IS staged"*"foo.py"*"gitignored file(s) excluded from the staged commit"*) pass "commit-claim downgraded to a note, but the #340 guard still blocks without --skip-ignored";;
    *"claims it is committed"*) fail "REGRESSION: the commit-claim die still fired despite a staged same-basename counterpart: $LAST_ERR";;
    *) fail "blocked but not on the expected #340 message: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 38: RESULTS.md claims a gitignored file is committed, and NO same-basename file is staged anywhere -> still BLOCK (the original #331 scenario; fail-closed preserved)"
T=$(mktemp_d); make_repo_with_gitignore "$T" 'reg/**/*.jsonl'
printf 'row\n' > "$T/reg/note/rollout_samples.jsonl"
printf 'rollout_samples.jsonl is committed in the registry dir.\n' > "$T/reg/note/RESULTS.md"
if run_dry "$T/reg/note"; then fail "false 'committed' claim with no staged counterpart was NOT blocked (#467 must not weaken the #331 fail-closed path)"; else
  case "$LAST_ERR" in *"excluded file"*"rollout_samples.jsonl"*"claims it is committed"*) pass "no staged counterpart -> still blocks exactly as before";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 39: a staged TEMP.md -> BLOCK (#332 — run-experiment's transient successor-handoff scratch must not land in the merged PR)"
T=$(mktemp_d); make_repo "$T"
printf 'a fresh clean note\n' > "$T/reg/note/note39.md"
printf 'pod: abc123\nnext: poll seed2\n' > "$T/reg/note/TEMP.md"
if run_dry "$T/reg/note"; then fail "staged TEMP.md was NOT blocked"; else
  case "$LAST_ERR" in *"staged a TEMP.md"*|*"has a staged TEMP.md"*) pass "staged TEMP.md blocked";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 40: no TEMP.md anywhere in the staged set -> PASS (no false-positive from the new guard)"
T=$(mktemp_d); make_repo "$T"
printf 'a fresh clean note, no handoff scratch\n' > "$T/reg/note/note40.md"
if run_dry "$T/reg/note"; then pass "clean note with no TEMP.md logs fine"; else fail "clean note BLOCKED (regression): $LAST_ERR"; fi
rm -rf "$T"

# #358: 'exploration' (FINDINGS.md, no DESIGN.md) and 'dataset' (MANIFEST.md, no DESIGN.md) record kinds
# (research-lab#136). Reuse make_design_stage_repo's empty-base-then-add-new-content fixture (the directory
# it hands back is just a fresh, empty registry dir ready for whatever content a case writes into it — the
# helper's name is a historical artifact of the first gate it was written for).

echo "[smoke] case 41: FINDINGS.md with a Status: EXPLORATORY header, no DESIGN.md -> classifies as exploration and PASSes"
T=$(mktemp_d); make_design_stage_repo "$T"
printf '# Findings\n\nStatus: EXPLORATORY\n\nSome exploratory notes.\n' > "$T/reg/design/FINDINGS.md"
if run_dry "$T/reg/design"; then
  case "$LAST_ERR" in *"classified: exploration"*) pass "FINDINGS.md classifies as exploration and the gate passes";;
    *) fail "passed but did not classify as exploration: $LAST_ERR";; esac
else fail "valid exploration record was BLOCKED (regression): $LAST_ERR"; fi
rm -rf "$T"

echo "[smoke] case 42: FINDINGS.md with no Status: EXPLORATORY marker -> BLOCK"
T=$(mktemp_d); make_design_stage_repo "$T"
printf '# Findings\n\nSome exploratory notes, no status line.\n' > "$T/reg/design/FINDINGS.md"
if run_dry "$T/reg/design"; then fail "exploration record with no Status: EXPLORATORY marker was NOT blocked"; else
  case "$LAST_ERR" in *"no 'Status: EXPLORATORY' header"*) pass "missing Status: EXPLORATORY marker blocked";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 43: MANIFEST.md with a sha256 table + an r2:// path, no DESIGN.md -> classifies as dataset and PASSes"
T=$(mktemp_d); make_design_stage_repo "$T"
printf '# Manifest\n\nR2 path: r2://bucket/dataset-1/\n\n| file | sha256 |\n|---|---|\n| a.jsonl | %s |\n' "$FAKE_SHA256" > "$T/reg/design/MANIFEST.md"
if run_dry "$T/reg/design"; then
  case "$LAST_ERR" in *"classified: dataset"*) pass "MANIFEST.md classifies as dataset and the gate passes";;
    *) fail "passed but did not classify as dataset: $LAST_ERR";; esac
else fail "valid dataset record was BLOCKED (regression): $LAST_ERR"; fi
rm -rf "$T"

echo "[smoke] case 44: MANIFEST.md with an r2:// path but no sha256 table -> BLOCK"
T=$(mktemp_d); make_design_stage_repo "$T"
printf '# Manifest\n\nR2 path: r2://bucket/dataset-1/\n\nNo hash table here.\n' > "$T/reg/design/MANIFEST.md"
if run_dry "$T/reg/design"; then fail "dataset record with no sha256 table was NOT blocked"; else
  case "$LAST_ERR" in *"no sha256 table"*) pass "missing sha256 table blocked";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 45: MANIFEST.md with a sha256 table but no r2:// path -> BLOCK"
T=$(mktemp_d); make_design_stage_repo "$T"
printf '# Manifest\n\n| file | sha256 |\n|---|---|\n| a.jsonl | %s |\n' "$FAKE_SHA256" > "$T/reg/design/MANIFEST.md"
if run_dry "$T/reg/design"; then fail "dataset record with no R2 path was NOT blocked"; else
  case "$LAST_ERR" in *"no R2 path"*) pass "missing R2 path blocked";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 46: explicit KIND=exploration override (with a valid FINDINGS.md) -> PASS, not the 'unknown KIND override' die (the #358 bug this issue fixes)"
T=$(mktemp_d); make_design_stage_repo "$T"
printf 'Status: EXPLORATORY\n\nNotes.\n' > "$T/reg/design/FINDINGS.md"
printf 'exploration\n' > "$T/reg/design/KIND"
if run_dry "$T/reg/design"; then pass "KIND=exploration override passes the gate"; else
  fail "KIND=exploration override was BLOCKED: $LAST_ERR"; fi
rm -rf "$T"

echo "[smoke] case 47: explicit KIND=dataset override (with a valid MANIFEST.md) -> PASS, not the 'unknown KIND override' die (the #358 bug this issue fixes)"
T=$(mktemp_d); make_design_stage_repo "$T"
printf 'R2 path: r2://bucket/dataset-1/\n\n| file | sha256 |\n|---|---|\n| a.jsonl | %s |\n' "$FAKE_SHA256" > "$T/reg/design/MANIFEST.md"
printf 'dataset\n' > "$T/reg/design/KIND"
if run_dry "$T/reg/design"; then pass "KIND=dataset override passes the gate"; else
  fail "KIND=dataset override was BLOCKED: $LAST_ERR"; fi
rm -rf "$T"

echo "[smoke] case 48: exploration record with a real secret in FINDINGS.md -> BLOCK (the shared secret scan still runs for exploration)"
T=$(mktemp_d); make_design_stage_repo "$T"
printf 'Status: EXPLORATORY\n\nkey = %s\n' "$REAL_SK" > "$T/reg/design/FINDINGS.md"
if run_dry "$T/reg/design"; then fail "exploration record with a real secret was NOT blocked"; else
  case "$LAST_ERR" in *"secret-value pattern"*) pass "exploration record's secret scan still runs and blocks";;
    *) fail "blocked but not on the secret scan: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 49: dataset record with a real secret in MANIFEST.md -> BLOCK (the shared secret scan still runs for dataset)"
T=$(mktemp_d); make_design_stage_repo "$T"
printf 'R2 path: r2://bucket/dataset-1/\nkey = %s\n\n| file | sha256 |\n|---|---|\n| a.jsonl | %s |\n' "$REAL_GHP" "$FAKE_SHA256" > "$T/reg/design/MANIFEST.md"
if run_dry "$T/reg/design"; then fail "dataset record with a real secret was NOT blocked"; else
  case "$LAST_ERR" in *"secret-value pattern"*) pass "dataset record's secret scan still runs and blocks";;
    *) fail "blocked but not on the secret scan: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 50: --only against an exploration dir (KIND != note) -> BLOCK (same #374 restriction as design-stage/experiment — its gate reads FINDINGS.md straight from \$DIR, not the staged set)"
T=$(mktemp_d); make_design_stage_repo "$T"
printf 'Status: EXPLORATORY\n\nNotes.\n' > "$T/reg/design/FINDINGS.md"
if run_dry "$T/reg/design" --only FINDINGS.md; then fail "--only on an exploration dir was NOT blocked"; else
  case "$LAST_ERR" in *"--only is only supported for KIND=note"*) pass "--only on an exploration dir refused";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 51: unrecognized KIND override -> BLOCK ('unknown KIND override'), and the message now lists exploration/dataset too"
T=$(mktemp_d); make_design_stage_repo "$T"
printf 'bogus\n' > "$T/reg/design/KIND"
printf 'anything\n' > "$T/reg/design/whatever.md"
if run_dry "$T/reg/design"; then fail "unrecognized KIND override was NOT blocked"; else
  case "$LAST_ERR" in *"unknown KIND override: 'bogus'"*"exploration"*"dataset"*) pass "unrecognized KIND override blocked, message mentions the new kinds";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 52: DESIGN.md + FINDINGS.md both present -> classifies design-stage, not exploration (FINDINGS.md only applies when DESIGN.md is absent)"
T=$(mktemp_d); make_design_stage_repo "$T"
printf '# Design\n' > "$T/reg/design/DESIGN.md"
printf 'Status: EXPLORATORY\n' > "$T/reg/design/FINDINGS.md"
if run_dry "$T/reg/design"; then :; fi
case "$LAST_ERR" in *"classified: design-stage"*) pass "DESIGN.md takes precedence over FINDINGS.md in auto-classification";;
  *) fail "did not classify as design-stage when DESIGN.md is present: $LAST_ERR";; esac
rm -rf "$T"

echo "[smoke] case 53: FINDINGS.md merely MENTIONS 'Status: EXPLORATORY' in prose (not as its own header line) -> BLOCK (P0: gate must not accept a substring match anywhere in the file)"
T=$(mktemp_d); make_design_stage_repo "$T"
printf '# Findings\n\nMissing Status: EXPLORATORY marker in this draft, will add before landing.\n' > "$T/reg/design/FINDINGS.md"
if run_dry "$T/reg/design"; then fail "prose-only mention of Status: EXPLORATORY was NOT blocked (accepted a substring match instead of requiring a header line)"; else
  case "$LAST_ERR" in *"no 'Status: EXPLORATORY' header"*) pass "prose-only mention of the marker blocked, header still required";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 54: FINDINGS.md's own line BEGINS WITH 'Status: EXPLORATORY' but continues as prose (not a bare header) -> BLOCK (round-3 review: the end of the marker must be anchored too, not just the start — case 53 only covers a prefixed prose mention)"
T=$(mktemp_d); make_design_stage_repo "$T"
printf '# Findings\n\nStatus: EXPLORATORY header is missing from the upstream draft.\n' > "$T/reg/design/FINDINGS.md"
if run_dry "$T/reg/design"; then fail "prose continuing past the marker on its own line was NOT blocked (end of marker not anchored)"; else
  case "$LAST_ERR" in *"no 'Status: EXPLORATORY' header"*) pass "prose trailing the marker on its own line blocked, bare header still required";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 55: MANIFEST.md sha256 table names the column but every row is a placeholder (no real 64-hex digest) -> BLOCK (P1: gate must verify an actual digest, not just the word 'sha256')"
T=$(mktemp_d); make_design_stage_repo "$T"
printf '# Manifest\n\nR2 path: r2://bucket/dataset-1/\n\n| file | sha256 |\n|---|---|\n| a.jsonl | abcabc |\n' > "$T/reg/design/MANIFEST.md"
if run_dry "$T/reg/design"; then fail "dataset record with a placeholder (non-hex, non-64-char) hash was NOT blocked"; else
  case "$LAST_ERR" in *"no real 64-character hex digest"*) pass "placeholder sha256 value blocked, real digest still required";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac; fi
rm -rf "$T"

if [ "$FAILS" -eq 0 ]; then echo "[smoke] log-experiment secret-scan: ALL PASS"; exit 0; else
  echo "[smoke] log-experiment secret-scan: $FAILS FAILURE(S)" >&2; exit 1; fi
