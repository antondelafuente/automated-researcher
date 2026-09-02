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
#
# #819: also covers the one-landing close — `--page-source <dir>` staging the viewer page source into the
# SAME commit/PR as the record (the record, the page source and LANDED.md were three sequential gated PRs at
# the end of every run), the page-source GATE (an experiment whose frozen START.md snapshot carries
# `[recipes.viewer]` must land a page source or record an external one — the mechanical half of the publish
# leg the close audit no longer has to see), that the page-source tree is still secret-scanned on an
# experiment PR (it used to get that scan as its own note PR), and that every per-root gate (the TEMP.md
# scan, the ancestor-.gitignore walk behind the #340 guard) covers the second root too.
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

# #666 (cases 41-46): the staging copy must apply BOTH filters — the worktree's ignore rules and the --only
# allowlist — BEFORE any bytes move, so a gitignored multi-GB tree that can never be committed is never
# copied into the /tmp worktree (the reported ENOSPC landing: a 35G `dashboard/build/` copied alongside the
# three small source files --only named). The fixtures prove "never copied" behaviorally, without needing a
# multi-GB tree or a full disk: a file the copy MUST NOT touch is made unreadable (mode 000), which the old
# blanket `cp -r "$DIR"` died on and a copy that skips the path cannot notice. NOTE: mode 000 does not stop
# root, so these cases only DISCRIMINATE when the smoke runs unprivileged (as it does on CI and on a dev
# box); as root they still assert the correct end state, just without reproducing the old failure.
echo "[smoke] case 41: a gitignored subtree the copy must never touch (unreadable file inside it) -> BLOCK listing the file, not a copy failure (#666: enumerated for the #340 guard without being copied)"
T=$(mktemp_d); make_repo_with_gitignore "$T" 'reg/note/build/'
printf 'notes\n' > "$T/reg/note/note41.md"                      # a normal new file — stages fine
mkdir -p "$T/reg/note/build/deep"
printf 'bundle\n' > "$T/reg/note/build/deep/bundle.js"          # inside a WHOLLY-ignored dir; never committable
chmod 000 "$T/reg/note/build/deep/bundle.js"
if run_dry "$T/reg/note"; then fail "gitignored subtree was NOT flagged by the #340 guard (#666 regression: enumeration lost with the copy)"; else
  case "$LAST_ERR" in *"gitignored file"*"reg/note/build/deep/bundle.js"*) pass "gitignored subtree enumerated per-file for the guard without being copied";;
    *) fail "blocked, but not on the ignored-file guard (the copy likely still touched the ignored subtree): $LAST_ERR";; esac; fi
chmod 644 "$T/reg/note/build/deep/bundle.js"; rm -rf "$T"

echo "[smoke] case 42: same gitignored subtree, with --skip-ignored -> PASS (the landing no longer costs a copy of a tree it can never commit — the ENOSPC incident)"
T=$(mktemp_d); make_repo_with_gitignore "$T" 'reg/note/build/'
printf 'notes\n' > "$T/reg/note/note42.md"
mkdir -p "$T/reg/note/build/deep"
printf 'bundle\n' > "$T/reg/note/build/deep/bundle.js"
chmod 000 "$T/reg/note/build/deep/bundle.js"
if run_dry "$T/reg/note" --skip-ignored; then pass "log proceeds without ever reading the gitignored subtree";
else fail "acknowledged gitignored subtree still failed the log (the copy touched it): $LAST_ERR"; fi
chmod 644 "$T/reg/note/build/deep/bundle.js"; rm -rf "$T"

echo "[smoke] case 43: --only names one clean file; a co-tenant's (non-ignored) file the allowlist leaves out is never copied either -> PASS (#666: --only applies BEFORE the copy, not after)"
T=$(mktemp_d); make_repo "$T"
printf 'my page\n' > "$T/reg/note/mine43.html"
printf 'co-tenant build output\n' > "$T/reg/note/cotenant43.bin"
chmod 000 "$T/reg/note/cotenant43.bin"
if run_dry "$T/reg/note" --only mine43.html; then pass "--only narrows the copy itself; the co-tenant's file is never read";
else fail "--only run failed on a co-tenant file it never stages (copied before filtering): $LAST_ERR"; fi
chmod 644 "$T/reg/note/cotenant43.bin"; rm -rf "$T"

# #670 review (cases 44-46): the ignore-rule state that decides the copy must be the SAME state the later
# `git add` applies. The copy itself changes that state — a `.gitignore` under $DIR is one of the files being
# copied — so copy_stage_paths materializes the input's own rule files BEFORE computing any verdict. Cases 41-43
# above all put the rules in the BASE commit, where the two states coincide and the bug is invisible; these
# three put them in the INPUT dir, where a pre-copy verdict taken against the base worktree alone diverges.
echo "[smoke] case 44: the input dir ships its OWN new .gitignore (not in base) for its build tree -> the tree is neither copied (unreadable file inside) nor silently dropped: BLOCK listing it"
# The common first-land shape: a brand-new experiment dir the base tree has never seen, carrying the very
# .gitignore that excludes its artifacts. Deciding against the base worktree alone would call the tree
# not-ignored (copy it — the ENOSPC bug, unfixed), then `git add` would skip it under the just-copied rule
# with the #340/#331 guard reporting nothing at all.
T=$(mktemp_d); make_repo "$T"
printf 'build/\n' > "$T/reg/note/.gitignore"                    # NEW rule, present only in the input dir
printf 'notes\n' > "$T/reg/note/note44.md"
mkdir -p "$T/reg/note/build/deep"
printf 'bundle\n' > "$T/reg/note/build/deep/bundle.js"
chmod 000 "$T/reg/note/build/deep/bundle.js"
if run_dry "$T/reg/note"; then fail "a rule the INPUT dir adds was ignored by the pre-copy filter — the tree was copied and then silently dropped from the commit with no guard report"; else
  case "$LAST_ERR" in *"gitignored file"*"reg/note/build/deep/bundle.js"*) pass "the input's own .gitignore governs the copy and the guard alike";;
    *) fail "blocked, but not on the ignored-file guard (the copy likely still touched the ignored subtree): $LAST_ERR";; esac; fi
chmod 644 "$T/reg/note/build/deep/bundle.js"; rm -rf "$T"

echo "[smoke] case 45: the input dir's .gitignore NEGATES a base rule -> the re-included file still lands (no change to what gets committed)"
# The other direction: a base-only verdict calls keep.jsonl ignored, so it is never copied and the guard
# BLOCKs on it — where the pre-#666 blanket copy staged and committed it. #666 declares that a non-goal.
T=$(mktemp_d); make_repo_with_gitignore "$T" 'reg/**/*.jsonl'
printf '!keep.jsonl\n' > "$T/reg/note/.gitignore"
printf 'row\n' > "$T/reg/note/keep.jsonl"
if run_dry "$T/reg/note"; then pass "a base rule the input re-includes still commits (the guard does not fire)";
else fail "a file the input's .gitignore re-includes was treated as excluded: $LAST_ERR"; fi
rm -rf "$T"

echo "[smoke] case 46: --only a subdir, with the governing .gitignore one level UP in the input dir -> that ancestor rule still applies"
# find's roots are the --only paths, so `reg/note/.gitignore` is never enumerated under `reg/note/sub` — the
# ancestor chain from each root's parent up to \$REL has to be collected separately, or an --only run decides
# against rules the `git add` will then apply.
T=$(mktemp_d); make_repo "$T"
printf '*.bin\n' > "$T/reg/note/.gitignore"                     # at $REL, OUTSIDE the --only root
mkdir -p "$T/reg/note/sub"
printf 'keep\n' > "$T/reg/note/sub/keep46.md"
printf 'blob\n' > "$T/reg/note/sub/big46.bin"
chmod 000 "$T/reg/note/sub/big46.bin"
if run_dry "$T/reg/note" --only sub; then fail "an ancestor .gitignore in the input dir was missed by the --only copy filter — the .bin was copied and then silently dropped"; else
  case "$LAST_ERR" in *"gitignored file"*"reg/note/sub/big46.bin"*) pass "the ancestor .gitignore governs an --only-narrowed copy too";;
    *) fail "blocked, but not on the ignored-file guard (the copy likely still touched the ignored file): $LAST_ERR";; esac; fi
chmod 644 "$T/reg/note/sub/big46.bin"; rm -rf "$T"

# ---- #819: the one-landing close — --page-source rides the record's PR, and the page-source gate ----
# make_experiment_repo <dir> [no-viewer]: a repo whose base commit is empty of records, checked out onto
# change/x with a brand-new reg/exp record (DESIGN.md + RESULTS.md + a triaged AUDIT.md, so gate_experiment
# passes) and a dashboard/exp page-source tree beside it. START.md carries the frozen instance-profile
# snapshot; by default it declares a [recipes.viewer] recipe (the publish-leg instance), pass "no-viewer" for
# the manifest-only instance.
make_experiment_repo() {
  local root="$1" viewer="${2:-viewer}"
  git init -q -b main "$root"
  git -C "$root" config user.email smoke@test; git -C "$root" config user.name smoke
  mkdir -p "$root/reg" "$root/dashboard"
  printf 'placeholder\n' > "$root/reg/.keep"; printf 'placeholder\n' > "$root/dashboard/.keep"
  git -C "$root" add -A; git -C "$root" commit -qm base
  git -C "$root" update-ref refs/remotes/origin/main main
  git -C "$root" checkout -q -b change/x
  mkdir -p "$root/reg/exp" "$root/dashboard/exp"
  printf '# design\n' > "$root/reg/exp/DESIGN.md"
  printf '# results\n\nthe numbers\n' > "$root/reg/exp/RESULTS.md"
  printf '# audit\n\nno HIGH findings\n\n## Executor responses\n\nall addressed\n' > "$root/reg/exp/AUDIT.md"
  {
    printf '## Instance profile (snapshot)\n\n```toml\n[github]\nresearch_repo = "o/r"\nbase_branch = "main"\n'
    [ "$viewer" = "no-viewer" ] || printf '\n[recipes.viewer]\nkind = "repo"\n'
    printf '```\n'
  } > "$root/reg/exp/START.md"
  printf 'def build():\n    return "page"\n' > "$root/dashboard/exp/page.py"
}

echo "[smoke] case 47: experiment whose START.md snapshot carries [recipes.viewer], NO page source -> BLOCK (#819/#347: the publish leg's page must not land nowhere)"
T=$(mktemp_d); make_experiment_repo "$T"
if run_dry "$T/reg/exp"; then fail "a viewer-recipe experiment logged with no page source at all"; else
  case "$LAST_ERR" in *"no page source is being landed"*) pass "viewer-recipe close without page source blocked";;
    *) fail "blocked, but not on the page-source gate: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 48: same, WITH --page-source -> PASS, and the page source is staged into the SAME commit (one landing, not three)"
T=$(mktemp_d); make_experiment_repo "$T"
if run_dry "$T/reg/exp" --page-source "$T/dashboard/exp"; then
  case "$LAST_ERR" in *"page source dashboard/exp staged in the same commit"*) pass "page source rides the record's PR";;
    *) fail "passed but the page source was not staged in the same commit: $LAST_ERR";; esac
else fail "the one-landing close BLOCKED: $LAST_ERR"; fi
rm -rf "$T"

echo "[smoke] case 49: a secret in the --page-source tree of an EXPERIMENT PR -> BLOCK (the page source used to land as its own note PR and got the scan there; riding the record's gate must not drop it)"
T=$(mktemp_d); make_experiment_repo "$T"
printf 'key = %s\n' "$REAL_GHP" > "$T/dashboard/exp/creds.py"
if run_dry "$T/reg/exp" --page-source "$T/dashboard/exp"; then fail "a secret in the staged page source was NOT scanned on an experiment PR"; else
  case "$LAST_ERR" in *"secret-value pattern"*) pass "page source is secret-scanned on the experiment PR";;
    *) fail "blocked, but not on the secret scan: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 50: experiment with NO [recipes.viewer] in the snapshot -> PASS with no page source (manifest-only close stays legitimate)"
T=$(mktemp_d); make_experiment_repo "$T" no-viewer
if run_dry "$T/reg/exp"; then pass "manifest-only close requires no page source"; else fail "manifest-only close BLOCKED: $LAST_ERR"; fi
rm -rf "$T"

echo "[smoke] case 51: --page-source-external <url> for a viewer that lives in ANOTHER repo -> PASS (recorded, not blocked)"
T=$(mktemp_d); make_experiment_repo "$T"
if run_dry "$T/reg/exp" --page-source-external "https://example.invalid/viewer/pull/7"; then pass "external page source recorded"; else fail "external page source BLOCKED: $LAST_ERR"; fi
rm -rf "$T"

echo "[smoke] case 52: --page-source dir that is itself a RECORD (has DESIGN.md) -> BLOCK (a record needs its own gate; this one rides the experiment's)"
T=$(mktemp_d); make_experiment_repo "$T"
printf '# other design\n' > "$T/dashboard/exp/DESIGN.md"
if run_dry "$T/reg/exp" --page-source "$T/dashboard/exp"; then fail "a second RECORD was staged as page source under the experiment's gate"; else
  case "$LAST_ERR" in *"that is a RECORD"*) pass "record-shaped page-source dir refused";;
    *) fail "blocked, but not on the record-shaped check: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 53: --page-source dir INSIDE the record dir -> BLOCK (overlapping roots would double-stage and cross the two gates' scopes)"
T=$(mktemp_d); make_experiment_repo "$T"
mkdir -p "$T/reg/exp/page"; printf 'x\n' > "$T/reg/exp/page/p.py"
if run_dry "$T/reg/exp" --page-source "$T/reg/exp/page"; then fail "an overlapping page-source root was accepted"; else
  case "$LAST_ERR" in *"overlaps the record dir"*) pass "overlapping page-source root refused";;
    *) fail "blocked, but not on the overlap check: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 53b: --page-source = the REPOSITORY ROOT -> BLOCK (#820 review round 2: the root normalizes to '.', which prefix arithmetic reads as disjoint from every path instead of containing all of them, so the whole repo would have staged as page source)"
T=$(mktemp_d); make_experiment_repo "$T"
if run_dry "$T/reg/exp" --page-source "$T"; then fail "the repository root was accepted as a page-source root — the entire repo would stage as page source"; else
  case "$LAST_ERR" in *"overlaps the record dir"*) pass "repo-root page-source root refused";;
    *) fail "blocked, but not on the overlap check: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 53c: the record dir IS the repository root -> BLOCK (the same sentinel with the roots swapped: patching only the direction that was found would leave this one open)"
T=$(mktemp_d); make_experiment_repo "$T"
printf '# design\n' > "$T/DESIGN.md"; printf '# results\n' > "$T/RESULTS.md"
if run_dry "$T" --page-source "$T/dashboard/exp"; then fail "a repo-root record dir accepted a page-source root inside it"; else
  case "$LAST_ERR" in *"overlaps the record dir"*) pass "repo-root record dir refuses a contained page-source root";;
    *) fail "blocked, but not on the overlap check: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 53d: a page-source root merely sharing a name PREFIX with the record dir -> PASS (the guard tests containment, not string prefix: reg/exp and reg/exp-page are disjoint trees)"
T=$(mktemp_d); make_experiment_repo "$T"
mkdir -p "$T/reg/exp-page"; printf 'x\n' > "$T/reg/exp-page/p.py"
if run_dry "$T/reg/exp" --page-source "$T/reg/exp-page"; then pass "a sibling sharing a name prefix is not treated as overlapping"; else
  fail "a disjoint sibling page-source root was refused: $LAST_ERR"; fi
rm -rf "$T"

echo "[smoke] case 54: --page-source on a KIND=note landing -> BLOCK (the publish leg belongs to an experiment close)"
T=$(mktemp_d); make_experiment_repo "$T"
mkdir -p "$T/reg/notes"; printf 'a note\n' > "$T/reg/notes/note.md"
if run_dry "$T/reg/notes" --page-source "$T/dashboard/exp"; then fail "--page-source accepted on a note landing"; else
  case "$LAST_ERR" in *"only supported for KIND=experiment"*) pass "--page-source refused for a non-experiment kind";;
    *) fail "blocked, but not on the kind check: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 55: --page-source and --page-source-external together -> BLOCK; --page-source-only without --page-source -> BLOCK"
T=$(mktemp_d); make_experiment_repo "$T"
if run_dry "$T/reg/exp" --page-source "$T/dashboard/exp" --page-source-external "https://example.invalid/x"; then fail "mutually exclusive page-source flags accepted"; else
  case "$LAST_ERR" in *"mutually exclusive"*) pass "--page-source + --page-source-external refused";;
    *) fail "blocked, but not on the mutual-exclusion check: $LAST_ERR";; esac; fi
if run_dry "$T/reg/exp" --page-source-only page.py; then fail "--page-source-only accepted without --page-source"; else
  case "$LAST_ERR" in *"--page-source-only needs --page-source"*) pass "--page-source-only requires --page-source";;
    *) fail "blocked, but not on the dangling-flag check: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 56: --page-source-only narrows the multi-tenant dashboard tree — a co-tenant's secret-bearing file is never staged or scanned (#374's reason, at the second root)"
T=$(mktemp_d); make_experiment_repo "$T"
printf 'key = %s\n' "$REAL_SK" > "$T/dashboard/exp/cotenant.py"
if run_dry "$T/reg/exp" --page-source "$T/dashboard/exp" --page-source-only page.py; then pass "the co-tenant's file is neither staged nor scanned";
else fail "the allowlist did not narrow the page-source root: $LAST_ERR"; fi
if run_dry "$T/reg/exp" --page-source "$T/dashboard/exp"; then fail "without the allowlist the co-tenant's secret was not caught"; else
  case "$LAST_ERR" in *"secret-value pattern"*) pass "without the allowlist the same file blocks (the narrowing is what excluded it)";;
    *) fail "blocked, but not on the secret scan: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 57: a TEMP.md staged from the PAGE-SOURCE root -> BLOCK (#332's guard covers every staging root, not just the record's)"
T=$(mktemp_d); make_experiment_repo "$T"
printf 'next: rebuild the gallery\n' > "$T/dashboard/exp/TEMP.md"
if run_dry "$T/reg/exp" --page-source "$T/dashboard/exp"; then fail "a TEMP.md in the page-source root was not caught"; else
  case "$LAST_ERR" in *"staged TEMP.md"*) pass "TEMP.md caught at the page-source root too";;
    *) fail "blocked, but not on the TEMP.md guard: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 58: a .gitignore at the PAGE-SOURCE root governs a --page-source-only subdir copy (the ancestor-rule walk is per-root, not only the record's)"
T=$(mktemp_d); make_experiment_repo "$T"
printf '*.bin\n' > "$T/dashboard/exp/.gitignore"          # at the page-source root, OUTSIDE the --page-source-only root
mkdir -p "$T/dashboard/exp/sub"
printf 'keep\n' > "$T/dashboard/exp/sub/keep58.py"
printf 'blob\n' > "$T/dashboard/exp/sub/big58.bin"
chmod 000 "$T/dashboard/exp/sub/big58.bin"
if run_dry "$T/reg/exp" --page-source "$T/dashboard/exp" --page-source-only sub; then
  fail "the page-source root's own .gitignore was missed — the .bin was copied and then silently dropped"; else
  case "$LAST_ERR" in *"gitignored file"*"dashboard/exp/sub/big58.bin"*) pass "the page-source root's ancestor .gitignore governs its narrowed copy";;
    *) fail "blocked, but not on the ignored-file guard: $LAST_ERR";; esac; fi
chmod 644 "$T/dashboard/exp/sub/big58.bin"; rm -rf "$T"

echo "[smoke] case 59: an eval-only/no-go experiment (closed decision, no close-audit) with a [recipes.viewer] brief -> PASS with no page source (a run stopped at a gate has no page to build)"
T=$(mktemp_d); make_experiment_repo "$T"
rm -f "$T/reg/exp/AUDIT.md"
printf '# results\n\nDecision: ANCHOR_FAILED\n' > "$T/reg/exp/RESULTS.md"
if run_dry "$T/reg/exp"; then pass "a no-go close is not held to the page-source gate"; else fail "no-go close BLOCKED: $LAST_ERR"; fi
rm -rf "$T"

if [ "$FAILS" -eq 0 ]; then echo "[smoke] log-experiment secret-scan: ALL PASS"; exit 0; else
  echo "[smoke] log-experiment secret-scan: $FAILS FAILURE(S)" >&2; exit 1; fi
