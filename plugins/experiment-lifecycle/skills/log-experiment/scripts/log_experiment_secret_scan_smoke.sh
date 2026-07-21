#!/usr/bin/env bash
# log_experiment_secret_scan_smoke.sh — offline behavior smoke for log-experiment.sh's secret_scan (#306),
# symlink_scan (#416), and its ignored-file guard (#340) + committed-claim check (#331).
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
#
# #374: also covers the `--only <path>` allowlist — a co-tenant's file left OUT of the allowlist is never
# staged and so never scanned/blocked by secret_scan or the #340 ignored-file guard, even when it sits right
# alongside the allowlisted file(s) in the same shared registry dir; a nonexistent or escaping (`/abs`,
# `../`) --only path BLOCKs (fail-closed — never silently falls back to staging the whole dir); an allowlist
# that stages nothing (the named file is unchanged vs base) BLOCKs on nothing-to-commit same as the
# unscoped case; and a --only path that is itself gitignored is still caught by the #340 guard (the
# allowlist narrows scope, it does not disable the existing gates).
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

# run_dry <dir> [extra-args...]: run the gate under a clean XDG_CONFIG_HOME (no profile) + BASE_BRANCH=main.
# Echoes nothing; returns the script's exit code (0 = gate passed; non-zero = BLOCK). stderr captured to $LAST_ERR.
LAST_ERR=""
run_dry() {
  local dir="$1"; shift; local cfg; cfg="$(mktemp -d)"
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

echo "[smoke] case 10: a pinned .jsonl silently gitignored alongside other content that stages fine -> BLOCK (#340)"
T=$(mktemp -d); make_repo_with_gitignore "$T" '*.jsonl'
printf 'notes\n' > "$T/reg/note/note10.md"                      # a normal new file — stages fine
printf '{"in": "battery"}\n' > "$T/reg/note/battery.jsonl"      # pinned instrument file — silently gitignored
if run_dry "$T/reg/note"; then fail "gitignored pinned file was NOT blocked (#340 regression) — record looked complete but dropped battery.jsonl"; else
  case "$LAST_ERR" in *"gitignored file"*"battery.jsonl"*) pass "gitignored pinned file blocked and listed, even though other content staged fine";; *) fail "blocked but not on the ignored-file guard: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 11: same gitignored pinned file, but with --skip-ignored -> PASS (explicit acknowledgment)"
T=$(mktemp -d); make_repo_with_gitignore "$T" '*.jsonl'
printf 'notes\n' > "$T/reg/note/note11.md"
printf '{"in": "battery"}\n' > "$T/reg/note/battery.jsonl"
if run_dry "$T/reg/note" --skip-ignored; then pass "--skip-ignored proceeds past the ignored-file guard"; else
  fail "--skip-ignored did NOT bypass the guard: $LAST_ERR"; fi
rm -rf "$T"

echo "[smoke] case 12: only a trivial ignored file (.DS_Store) -> PASS, no block (junk filter)"
T=$(mktemp -d); make_repo_with_gitignore "$T" '.DS_Store'
printf 'notes\n' > "$T/reg/note/note12.md"
touch "$T/reg/note/.DS_Store"
if run_dry "$T/reg/note"; then pass "trivial .DS_Store ignore does not block"; else
  fail "trivial-only ignore blocked (should not): $LAST_ERR"; fi
rm -rf "$T"

echo "[smoke] case 13: gitignored file with no committed-claim, --skip-ignored -> PASS, still PRINTED as excluded (#331)"
T=$(mktemp -d); make_repo_with_gitignore "$T" 'reg/**/*.jsonl'
printf 'row\n' > "$T/reg/note/rollout_samples.jsonl"
printf 'a fresh note, no artifact claims\n' > "$T/reg/note/RESULTS.md"
if run_dry "$T/reg/note" --skip-ignored; then
  case "$LAST_ERR" in *"gitignored file"*"rollout_samples.jsonl"*) pass "excluded drop printed, log still passes";;
    *) fail "logged but the exclusion was not printed: $LAST_ERR";; esac
else fail "clean case BLOCKED (regression): $LAST_ERR"; fi
rm -rf "$T"

echo "[smoke] case 14: RESULTS.md verbatim-claims the dropped file is committed, WITHOUT --skip-ignored -> BLOCK with the specific claims message (#331 gate composed into the #340 default-block path)"
T=$(mktemp -d); make_repo_with_gitignore "$T" 'reg/**/*.jsonl'
printf 'row\n' > "$T/reg/note/rollout_samples.jsonl"
printf 'rollout_samples.jsonl is committed in the registry dir.\n' > "$T/reg/note/RESULTS.md"
if run_dry "$T/reg/note"; then fail "false 'committed' claim on a dropped file was NOT blocked"; else
  case "$LAST_ERR" in *"excluded file"*"rollout_samples.jsonl"*"claims it is committed"*) pass "false committed-claim blocked with the specific message";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 15: same false 'committed' claim, but WITH --skip-ignored -> still BLOCK (the #331 bug: --skip-ignored must never wave through a doc/tree divergence)"
T=$(mktemp -d); make_repo_with_gitignore "$T" 'reg/**/*.jsonl'
printf 'row\n' > "$T/reg/note/rollout_samples.jsonl"
printf 'rollout_samples.jsonl is committed in the registry dir.\n' > "$T/reg/note/RESULTS.md"
if run_dry "$T/reg/note" --skip-ignored; then fail "--skip-ignored bypassed a false 'committed' claim (the #331 incident)"; else
  case "$LAST_ERR" in *"excluded file"*"rollout_samples.jsonl"*"claims it is committed"*) pass "--skip-ignored does NOT bypass a false committed-claim";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 16: ARTIFACT_MANIFEST.md verbatim-claims the dropped file is committed, --skip-ignored -> BLOCK"
T=$(mktemp -d); make_repo_with_gitignore "$T" 'reg/**/*.jsonl'
printf 'row\n' > "$T/reg/note/rollout_samples.jsonl"
printf 'no artifact claims here\n' > "$T/reg/note/RESULTS.md"
printf '| rollout_samples.jsonl | committed | 67 rows |\n' > "$T/reg/note/ARTIFACT_MANIFEST.md"
if run_dry "$T/reg/note" --skip-ignored; then fail "false 'committed' claim in ARTIFACT_MANIFEST.md was NOT blocked"; else
  case "$LAST_ERR" in *"excluded file"*"rollout_samples.jsonl"*"claims it is committed"*) pass "ARTIFACT_MANIFEST.md false claim blocked";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 17: RESULTS.md mentions the dropped filename WITHOUT 'committed' wording, --skip-ignored -> PASS (no false-positive)"
T=$(mktemp -d); make_repo_with_gitignore "$T" 'reg/**/*.jsonl'
printf 'row\n' > "$T/reg/note/rollout_samples.jsonl"
printf 'rollout_samples.jsonl (67 rows) lives on R2, not in git.\n' > "$T/reg/note/RESULTS.md"
if run_dry "$T/reg/note" --skip-ignored; then pass "filename mention without 'committed' wording does not false-positive block"; else
  fail "blocked despite no committed-claim wording: $LAST_ERR"; fi
rm -rf "$T"

echo "[smoke] case 18: an IGNORED symlink claimed committed, --skip-ignored -> BLOCK (check_ignored_files' status --ignored=matching list covers symlinks too, not just regular files)"
T=$(mktemp -d); make_repo_with_gitignore "$T" 'reg/**/*.jsonl'
ln -s page.html "$T/reg/note/rollout_samples.jsonl"               # matches the base's reg/**/*.jsonl ignore rule
printf 'rollout_samples.jsonl is committed in the registry dir.\n' > "$T/reg/note/RESULTS.md"
if run_dry "$T/reg/note" --skip-ignored; then fail "ignored symlink falsely claimed committed was NOT blocked"; else
  case "$LAST_ERR" in *"excluded file"*"rollout_samples.jsonl"*"claims it is committed"*) pass "ignored symlink claimed committed is blocked";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 19: RESULTS.md uses bare 'commit' (not 'committed') on the same line, --skip-ignored -> BLOCK (a real claim, not just a false-positive fix)"
T=$(mktemp -d); make_repo_with_gitignore "$T" 'reg/**/*.jsonl'
printf 'row\n' > "$T/reg/note/rollout_samples.jsonl"
printf 'We commit rollout_samples.jsonl to the registry after review.\n' > "$T/reg/note/RESULTS.md"
if run_dry "$T/reg/note" --skip-ignored; then fail "bare 'commit' claim on a dropped file was NOT blocked"; else
  case "$LAST_ERR" in *"excluded file"*"rollout_samples.jsonl"*"claims it is committed"*) pass "bare 'commit' claim blocked";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 20: RESULTS.md claims 'in this dir' (no 'commit'/'committed' word) on the same line, --skip-ignored -> BLOCK"
T=$(mktemp -d); make_repo_with_gitignore "$T" 'reg/**/*.jsonl'
printf 'row\n' > "$T/reg/note/rollout_samples.jsonl"
printf 'rollout_samples.jsonl is in this dir, alongside the other artifacts.\n' > "$T/reg/note/RESULTS.md"
if run_dry "$T/reg/note" --skip-ignored; then fail "'in this dir' claim on a dropped file was NOT blocked"; else
  case "$LAST_ERR" in *"excluded file"*"rollout_samples.jsonl"*"claims it is committed"*) pass "'in this dir' claim blocked";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 21: dropped filename and a 'committed' claim about something else appear on DIFFERENT lines, --skip-ignored -> PASS (no false-positive; same-line co-occurrence only)"
T=$(mktemp -d); make_repo_with_gitignore "$T" 'reg/**/*.jsonl'
printf 'row\n' > "$T/reg/note/rollout_samples.jsonl"
printf 'rollout_samples.jsonl (67 rows) lives on R2, not in git.\nEverything else in this note is committed.\n' > "$T/reg/note/RESULTS.md"
if run_dry "$T/reg/note" --skip-ignored; then pass "filename and unrelated 'committed' line on separate lines does not false-positive block"; else
  fail "blocked despite the commit-claim word being on a different line: $LAST_ERR"; fi
rm -rf "$T"

echo "[smoke] case 22: RESULTS.md says the dropped file is 'not committed' (negated), --skip-ignored -> PASS (courtesy negation filter)"
T=$(mktemp -d); make_repo_with_gitignore "$T" 'reg/**/*.jsonl'
printf 'row\n' > "$T/reg/note/rollout_samples.jsonl"
printf 'rollout_samples.jsonl is not committed; it lives on R2.\n' > "$T/reg/note/RESULTS.md"
if run_dry "$T/reg/note" --skip-ignored; then pass "negated 'is not committed' claim does not false-positive block"; else
  fail "blocked despite the claim being negated ('not committed'): $LAST_ERR"; fi
rm -rf "$T"

echo "[smoke] case 23: dropped file lives inside a WHOLLY-ignored directory (not an individually-ignored file), RESULTS.md claims it's committed, WITHOUT --skip-ignored -> BLOCK (ls-files enumerates files inside the ignored dir, not just the dir's own basename)"
T=$(mktemp -d); make_repo_with_gitignore "$T" 'artifacts/'
mkdir -p "$T/reg/note/artifacts"
printf 'row\n' > "$T/reg/note/artifacts/rollout_samples.jsonl"
printf 'rollout_samples.jsonl is committed in the registry dir.\n' > "$T/reg/note/RESULTS.md"
if run_dry "$T/reg/note"; then fail "false 'committed' claim on a file inside a wholly-ignored directory was NOT blocked"; else
  case "$LAST_ERR" in *"excluded file"*"rollout_samples.jsonl"*"claims it is committed"*) pass "claim about a file inside a wholly-ignored directory is blocked";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 24: design-stage DESIGN.md with a valid locked Presentation header + a valid instance-profile snapshot -> PASS (#469/#470/#471)"
T=$(mktemp -d); make_design_stage_repo "$T"
printf '# Design\n\n## Presentation (locked with the researcher 2026-07-14)\nDetails.\n' > "$T/reg/design/DESIGN.md"
printf 'design-audit findings, clean\n' > "$T/reg/design/DESIGN_AUDIT.md"
cfg24="$(mktemp -d)"; mkdir -p "$cfg24/experiment-lifecycle"
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
T=$(mktemp -d); make_design_stage_repo "$T"
printf '# Design\n\n## Presentation\nDetails, not yet locked.\n' > "$T/reg/design/DESIGN.md"
printf 'design-audit findings, clean\n' > "$T/reg/design/DESIGN_AUDIT.md"
if run_dry "$T/reg/design"; then fail "design-stage with no lock header was NOT blocked"; else
  case "$LAST_ERR" in *"no locked Presentation section"*) pass "missing lock header blocked";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 26: design-stage DESIGN.md with a malformed calendar date in the lock header -> BLOCK (digit-shape alone would accept this)"
T=$(mktemp -d); make_design_stage_repo "$T"
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
T=$(mktemp -d); make_repo "$T"
printf 'my own clean file\n' > "$T/reg/note/mine.md"
printf 'token %s\n' "$REAL_GHP" > "$T/reg/note/cotenant_secret.md"
if run_dry "$T/reg/note" --only mine.md; then pass "--only stages just the named file; the co-tenant's secret file alongside it is never scanned"; else
  fail "--only mine.md was BLOCKED despite the co-tenant secret file being outside the allowlist: $LAST_ERR"; fi
rm -rf "$T"

echo "[smoke] case 28: repeated --only flags name two files; a co-tenant's secret file is left out -> PASS"
T=$(mktemp -d); make_repo "$T"
printf 'file a\n' > "$T/reg/note/a.md"
printf 'file b\n' > "$T/reg/note/b.md"
printf 'token %s\n' "$REAL_GHP" > "$T/reg/note/cotenant_secret.md"
if run_dry "$T/reg/note" --only a.md --only b.md; then pass "repeated --only flags stage exactly the two named files"; else
  fail "--only a.md --only b.md was BLOCKED: $LAST_ERR"; fi
rm -rf "$T"

echo "[smoke] case 29: --only names a path that does not exist under the registry dir -> BLOCK (fail closed, never falls back to the whole dir)"
T=$(mktemp -d); make_repo "$T"
printf 'my own clean file\n' > "$T/reg/note/mine.md"
if run_dry "$T/reg/note" --only missing.md; then fail "--only missing.md was NOT blocked"; else
  case "$LAST_ERR" in *"--only path does not exist under"*) pass "nonexistent --only path blocked";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 30: --only given an absolute path -> BLOCK"
T=$(mktemp -d); make_repo "$T"
if run_dry "$T/reg/note" --only /etc/passwd; then fail "--only with an absolute path was NOT blocked"; else
  case "$LAST_ERR" in *"must be relative to the registry dir, not absolute"*) pass "absolute --only path blocked";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 31: --only escapes the registry dir via '../' to a real file OUTSIDE it -> BLOCK (existence alone is not enough; containment is also checked)"
T=$(mktemp -d); make_repo "$T"
mkdir -p "$T/reg/sibling"
printf 'not mine\n' > "$T/reg/sibling/file.txt"
if run_dry "$T/reg/note" --only ../sibling/file.txt; then fail "--only escaping via '../' to a real file was NOT blocked"; else
  case "$LAST_ERR" in *"escapes the registry dir"*) pass "'../'-escaping --only path blocked";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 32: --only names the one file changed, but it is UNCHANGED vs base -> BLOCK on nothing-to-commit (never silently stages the whole dir instead)"
T=$(mktemp -d); make_repo "$T"   # page.html is already committed on origin/main, unchanged
if run_dry "$T/reg/note" --only page.html; then fail "--only on an unchanged file did NOT refuse (should be nothing to commit)"; else
  case "$LAST_ERR" in *"nothing to commit"*"--only"*) pass "--only on an unchanged file refuses on nothing-to-commit";;
    *) fail "failed but not on the expected nothing-to-commit message: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 33: --only names a clean file; a co-tenant's GITIGNORED file sits alongside it -> PASS (the ignored-file guard is scoped to the allowlist too, not just the secret scan)"
T=$(mktemp -d); make_repo_with_gitignore "$T" '*.jsonl'
printf 'my own clean file\n' > "$T/reg/note/mine.md"
printf '{"not": "mine"}\n' > "$T/reg/note/cotenant.jsonl"
if run_dry "$T/reg/note" --only mine.md; then pass "--only scopes the gitignored-file guard too — a co-tenant's ignored file elsewhere in the dir does not block"; else
  fail "--only mine.md was BLOCKED by a co-tenant's unrelated gitignored file: $LAST_ERR"; fi
rm -rf "$T"

echo "[smoke] case 34: --only names a file that is itself GITIGNORED -> still BLOCK (the guard still catches an allowlisted path that silently failed to stage)"
T=$(mktemp -d); make_repo_with_gitignore "$T" '*.jsonl'
printf '{"in": "battery"}\n' > "$T/reg/note/mine.jsonl"
if run_dry "$T/reg/note" --only mine.jsonl; then fail "--only on a gitignored path was NOT blocked (#340 guard should still apply within the allowlist)"; else
  case "$LAST_ERR" in *"gitignored file"*"mine.jsonl"*) pass "gitignored --only path still caught by the ignored-file guard";;
    *) fail "blocked but not on the expected message: $LAST_ERR";; esac; fi
rm -rf "$T"

if [ "$FAILS" -eq 0 ]; then echo "[smoke] log-experiment secret-scan: ALL PASS"; exit 0; else
  echo "[smoke] log-experiment secret-scan: $FAILS FAILURE(S)" >&2; exit 1; fi
