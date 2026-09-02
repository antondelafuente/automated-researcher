#!/usr/bin/env bash
# log_experiment_page_source_smoke.sh — behavior smoke for log-experiment.sh's ONE-LANDING close
# (`--page-source`, automated-researcher#819) under the invariants #821 states for it.
#
# Why a separate smoke from log_experiment_secret_scan_smoke.sh: that one owns the staged-set scan surface
# (#306/#340/#374/#416/#586/#666/#670); this one owns the second staging ROOT — its containment, its mirror
# semantics, and the page-source gate. Both run on any log-experiment.sh change, so the split is editorial,
# not a coverage gap.
#
# Every regression PR #820 accumulated on this half has a NAMED case here (#821 invariant 12); the cases
# marked `regression:` each FAIL on the pre-fix code:
#   regression: P1 — the root-overlap guard tested "disjoint from every path" instead of "contains all", so
#               the repo root (which normalizes to the sentinel `.`) read as disjoint from `reg/exp` and
#               `--page-source <repo-root>` would have staged the WHOLE repository as page source.
#   regression: P2 — `--page-source-only` used lexical `realpath -s`, so a path reached through a symlinked
#               PARENT pointing outside the tree passed: the kernel resolves that component during staging
#               and `cp -P --parents` materializes the outside bytes as an ordinary staged file, which the
#               staged-symlink check never sees.
#   regression: P3 — deletions in the page-source dir were silently omitted: the existing files were
#               overlaid onto a fresh base worktree without clearing the staged root first, so `git add`
#               never saw a removal and the landed page kept serving a file its source no longer had.
#
# PR #823's own review round 1 added two more, same convention (`regression: 823-P0`, and case 27 for its P1):
#   regression: 823-P0 — the page-source half of the approval body was written by the pre-staging gate, from
#               the FLAG's presence alone. A page-source dir that reached the commit nowhere (empty, or
#               wholly ignore-excluded and waved through with --skip-ignored) therefore merged a PR whose
#               paperwork said the page source rode it, because the RECORD's changes kept the overall
#               staged diff non-empty and "nothing to commit" never fired.
#   823-P1    — the allowlist refused a --page-source-only path that was already deleted, so the one thing
#               the mirror exists to express could not be named directly: you had to widen the allowlist to
#               a surviving parent dir.
#
# Plus the invariants #821 states, beyond the regressions: two roots landing in one commit (7), behaviour
# unchanged without `--page-source` (7), PHYSICAL root containment (8), mirror-with-delete and its
# `--page-source-only` narrowing (9), the record root's guards applied to the page tree (10), and
# `--page-source-external` mutual exclusion (11).
#
# Hermetic: `--dry-run` only (no tokens, no network, no remote) — it runs the SAME staging + gate path a real
# landing does, so the fixtures below assert on the real behaviour. Where a property is about what ends up
# STAGED (the mirror), the fixture is built so that the property decides pass/fail: the record dir is already
# in the base commit byte-identically, so the ONLY thing that can be staged is the page-source change, and
# `nothing to commit` is exactly the pre-fix outcome.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/log-experiment.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: log-experiment.sh not found next to smoke" >&2; exit 1; }

FAILS=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILS=$((FAILS+1)); }

# mktemp_d: mktemp -d, but refuses to hand back an empty/non-existent path — every fixture dir here is
# rm -rf'd by name, so a bad path would turn that into an op against the caller's own cwd/root.
mktemp_d() {
  local d
  d="$(mktemp -d)"
  [ -n "$d" ] && [ -d "$d" ] || { echo "FAIL: mktemp -d returned an empty/non-existent path" >&2; exit 1; }
  printf '%s\n' "$d"
}
REAL_GHP="ghp_$(printf 'A%.0s' {1..30})"

# make_experiment_repo <dir> [no-viewer]: a repo whose base commit carries no records, checked out onto
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
  git -C "$root" update-ref refs/remotes/origin/main main   # local stand-in for origin/main
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

# make_landed_repo <dir>: the record AND the page source are already in the base commit byte-identically, so
# the record half stages NOTHING and the only thing that can reach the commit is a page-source change. This
# is the fixture the mirror cases need: with no mirror, a page-source DELETION stages nothing at all and the
# run dies "nothing to commit" — which is precisely the pre-fix behaviour (#820 round 5).
make_landed_repo() {
  local root="$1"
  make_experiment_repo "$root"
  mkdir -p "$root/dashboard/exp/sub"
  printf 'old page\n' > "$root/dashboard/exp/stale.py"
  printf 'scratch note\n' > "$root/reg/exp/notes.txt"
  printf 'inside sub\n' > "$root/dashboard/exp/sub/inner.py"
  git -C "$root" add -A; git -C "$root" commit -qm 'record + page source landed'
  git -C "$root" update-ref refs/remotes/origin/main change/x   # base now HAS both trees
}

# run_dry <dir> [extra-args...]: run the gate under a clean XDG_CONFIG_HOME (no profile) + BASE_BRANCH=main.
# Returns the script's exit code (0 = gate passed; non-zero = BLOCK); combined output in $LAST_ERR.
LAST_ERR=""
run_dry() {
  local dir="$1"; shift; local cfg; cfg="$(mktemp_d)" || return 1
  local out; out="$(XDG_CONFIG_HOME="$cfg" AAR_PROFILE="" LOG_EXPERIMENT_BASE_BRANCH=main \
      bash "$SCRIPT" "$dir" --dry-run "$@" 2>&1)"; local rc=$?
  LAST_ERR="$out"; rm -rf "$cfg"; return $rc
}

echo "[smoke] case 1: invariant 7 — an experiment whose START.md snapshot carries [recipes.viewer] and NO page source -> BLOCK (#347: the publish leg's page must not land nowhere)"
T=$(mktemp_d); make_experiment_repo "$T"
if run_dry "$T/reg/exp"; then fail "a viewer-recipe experiment logged with no page source at all"; else
  case "$LAST_ERR" in *"no page source is being landed"*) pass "viewer-recipe close without page source blocked";;
    *) fail "blocked, but not on the page-source gate: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 2: invariant 7 — the same close WITH --page-source -> PASS, staged into the SAME commit (one landing, not three)"
T=$(mktemp_d); make_experiment_repo "$T"
if run_dry "$T/reg/exp" --page-source "$T/dashboard/exp"; then
  case "$LAST_ERR" in *"page source dashboard/exp staged (mirrored) in the same commit"*) pass "page source rides the record's PR";;
    *) fail "passed but the page source was not staged in the same commit: $LAST_ERR";; esac
else fail "the one-landing close BLOCKED: $LAST_ERR"; fi
rm -rf "$T"

echo "[smoke] case 3: invariant 7 — no --page-source at all on a manifest-only instance -> PASS unchanged (the flagless path is untouched)"
T=$(mktemp_d); make_experiment_repo "$T" no-viewer
if run_dry "$T/reg/exp"; then pass "manifest-only close requires no page source"; else fail "manifest-only close BLOCKED: $LAST_ERR"; fi
rm -rf "$T"

echo "[smoke] case 4: invariant 7 — an eval-only/no-go close (closed decision, no close-audit) with a [recipes.viewer] brief -> PASS with no page source"
T=$(mktemp_d); make_experiment_repo "$T"
rm -f "$T/reg/exp/AUDIT.md"
printf '# results\n\nDecision: ANCHOR_FAILED\n' > "$T/reg/exp/RESULTS.md"
if run_dry "$T/reg/exp"; then pass "a no-go close is not held to the page-source gate"; else fail "no-go close BLOCKED: $LAST_ERR"; fi
rm -rf "$T"

echo "[smoke] case 5: invariant 11 — --page-source-external <url> records a viewer in ANOTHER repo; the two flags are mutually exclusive; --page-source-only needs --page-source"
T=$(mktemp_d); make_experiment_repo "$T"
if run_dry "$T/reg/exp" --page-source-external "https://example.invalid/viewer/pull/7"; then pass "external page source recorded"; else fail "external page source BLOCKED: $LAST_ERR"; fi
if run_dry "$T/reg/exp" --page-source "$T/dashboard/exp" --page-source-external "https://example.invalid/x"; then fail "mutually exclusive page-source flags accepted"; else
  case "$LAST_ERR" in *"mutually exclusive"*) pass "--page-source + --page-source-external refused";;
    *) fail "blocked, but not on the mutual-exclusion check: $LAST_ERR";; esac; fi
if run_dry "$T/reg/exp" --page-source-only page.py; then fail "--page-source-only accepted without --page-source"; else
  case "$LAST_ERR" in *"--page-source-only needs --page-source"*) pass "--page-source-only requires --page-source";;
    *) fail "blocked, but not on the dangling-flag check: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 6: invariant 8 — a --page-source dir INSIDE the record dir -> BLOCK (overlapping roots double-stage and cross the two gates' scopes)"
T=$(mktemp_d); make_experiment_repo "$T"
mkdir -p "$T/reg/exp/page"; printf 'x\n' > "$T/reg/exp/page/p.py"
if run_dry "$T/reg/exp" --page-source "$T/reg/exp/page"; then fail "an overlapping page-source root was accepted"; else
  case "$LAST_ERR" in *"overlaps the record dir"*) pass "overlapping page-source root refused";;
    *) fail "blocked, but not on the overlap check: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 7: regression P1 — --page-source = the REPOSITORY ROOT -> BLOCK (the root normalizes to '.', which prefix arithmetic reads as disjoint from every path instead of containing all of them)"
T=$(mktemp_d); make_experiment_repo "$T"
if run_dry "$T/reg/exp" --page-source "$T"; then fail "regression P1: the repository root was accepted as a page-source root — the entire repo would stage as page source"; else
  case "$LAST_ERR" in *"IS the repository root"*|*"overlaps the record dir"*) pass "regression P1: repo-root page-source root refused";;
    *) fail "regression P1: blocked, but not on the containment check: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 8: regression P1 (roots swapped) — the RECORD dir is the repository root -> BLOCK (patching only the direction that was found would leave this one open)"
T=$(mktemp_d); make_experiment_repo "$T"
printf '# design\n' > "$T/DESIGN.md"; printf '# results\n' > "$T/RESULTS.md"
if run_dry "$T" --page-source "$T/dashboard/exp"; then fail "regression P1: a repo-root record dir accepted a page-source root inside it"; else
  case "$LAST_ERR" in *"overlaps the record dir"*) pass "regression P1: repo-root record dir refuses a contained page-source root";;
    *) fail "regression P1: blocked, but not on the containment check: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 9: invariant 8 — a page-source root merely sharing a name PREFIX with the record dir -> PASS (containment, not string prefix: reg/exp and reg/exp-page are disjoint trees)"
T=$(mktemp_d); make_experiment_repo "$T"
mkdir -p "$T/reg/exp-page"; printf 'x\n' > "$T/reg/exp-page/p.py"
if run_dry "$T/reg/exp" --page-source "$T/reg/exp-page"; then pass "a sibling sharing a name prefix is not treated as overlapping"; else
  fail "a disjoint sibling page-source root was refused: $LAST_ERR"; fi
rm -rf "$T"

echo "[smoke] case 10: invariant 8 — a --page-source root that is a SYMLINK into the record dir -> BLOCK (root containment is PHYSICAL: a lexically-disjoint path that really is inside the record would double-stage it)"
T=$(mktemp_d); make_experiment_repo "$T"
mkdir -p "$T/reg/exp/page"; printf 'x\n' > "$T/reg/exp/page/p.py"
ln -s "$T/reg/exp/page" "$T/dashboard/linked"
if run_dry "$T/reg/exp" --page-source "$T/dashboard/linked"; then fail "a symlinked page-source root pointing INTO the record dir was accepted as disjoint"; else
  case "$LAST_ERR" in *"overlaps the record dir"*) pass "root containment is judged physically, not lexically";;
    *) fail "blocked, but not on the overlap check: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 11: invariant 8 — a --page-source root symlinked OUTSIDE the repo -> BLOCK (a root's real path must be inside the repo's real root)"
T=$(mktemp_d); OUTSIDE=$(mktemp_d); make_experiment_repo "$T"
printf 'outside page\n' > "$OUTSIDE/p.py"
ln -s "$OUTSIDE" "$T/dashboard/outside"
if run_dry "$T/reg/exp" --page-source "$T/dashboard/outside"; then fail "a page-source root physically outside the repo was accepted"; else
  case "$LAST_ERR" in *"not inside a git repo"*|*"DIFFERENT repo"*|*"outside the repo root"*) pass "an out-of-repo page-source root is refused (its REAL path decides, so the symlink buys nothing)";;
    *) fail "blocked, but not on the repo-containment check: $LAST_ERR";; esac; fi
rm -rf "$T" "$OUTSIDE"

echo "[smoke] case 12: invariant 10 — a --page-source dir that is itself a RECORD (has DESIGN.md) -> BLOCK (a record needs its own gate; this one would ride the experiment's)"
T=$(mktemp_d); make_experiment_repo "$T"
printf '# other design\n' > "$T/dashboard/exp/DESIGN.md"
if run_dry "$T/reg/exp" --page-source "$T/dashboard/exp"; then fail "a second RECORD was staged as page source under the experiment's gate"; else
  case "$LAST_ERR" in *"that is a RECORD"*) pass "record-shaped page-source dir refused";;
    *) fail "blocked, but not on the record-shaped check: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 13: invariant 10 — a secret in the --page-source tree of an EXPERIMENT PR -> BLOCK (the page source used to land as its own note PR and got the scan there)"
T=$(mktemp_d); make_experiment_repo "$T"
printf 'key = %s\n' "$REAL_GHP" > "$T/dashboard/exp/creds.py"
if run_dry "$T/reg/exp" --page-source "$T/dashboard/exp"; then fail "a secret in the staged page source was NOT scanned on an experiment PR"; else
  case "$LAST_ERR" in *"secret-value pattern"*) pass "page source is secret-scanned on the experiment PR";;
    *) fail "blocked, but not on the secret scan: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 14: invariant 10 — a TEMP.md staged from the PAGE-SOURCE root -> BLOCK (#332's guard covers every staging root, not just the record's)"
T=$(mktemp_d); make_experiment_repo "$T"
printf 'next: rebuild the gallery\n' > "$T/dashboard/exp/TEMP.md"
if run_dry "$T/reg/exp" --page-source "$T/dashboard/exp"; then fail "a TEMP.md in the page-source root was not caught"; else
  case "$LAST_ERR" in *"staged TEMP.md"*) pass "TEMP.md caught at the page-source root too";;
    *) fail "blocked, but not on the TEMP.md guard: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 15: invariant 10 — a .gitignore at the PAGE-SOURCE root governs a --page-source-only subdir copy (the ancestor-rule walk is per-root, not only the record's)"
T=$(mktemp_d); make_experiment_repo "$T"
printf '*.bin\n' > "$T/dashboard/exp/.gitignore"          # at the page-source root, OUTSIDE the --page-source-only root
mkdir -p "$T/dashboard/exp/sub"
printf 'keep\n' > "$T/dashboard/exp/sub/keep.py"
printf 'blob\n' > "$T/dashboard/exp/sub/big.bin"
chmod 000 "$T/dashboard/exp/sub/big.bin"                  # unreadable: a copy that touched it would fail loudly
if run_dry "$T/reg/exp" --page-source "$T/dashboard/exp" --page-source-only sub; then
  fail "the page-source root's own .gitignore was missed — the .bin was copied and then silently dropped"; else
  case "$LAST_ERR" in *"gitignored file"*"dashboard/exp/sub/big.bin"*) pass "the page-source root's ancestor .gitignore governs its narrowed copy";;
    *) fail "blocked, but not on the ignored-file guard: $LAST_ERR";; esac; fi
chmod 644 "$T/dashboard/exp/sub/big.bin"; rm -rf "$T"

echo "[smoke] case 16: invariant 9 — --page-source-only narrows the multi-tenant dashboard tree (a co-tenant's secret-bearing file is never staged or scanned, #374's reason at the second root)"
T=$(mktemp_d); make_experiment_repo "$T"
printf 'key = %s\n' "$REAL_GHP" > "$T/dashboard/exp/cotenant.py"
if run_dry "$T/reg/exp" --page-source "$T/dashboard/exp" --page-source-only page.py; then pass "the co-tenant's file is neither staged nor scanned";
else fail "the allowlist did not narrow the page-source root: $LAST_ERR"; fi
if run_dry "$T/reg/exp" --page-source "$T/dashboard/exp"; then fail "without the allowlist the co-tenant's secret was not caught"; else
  case "$LAST_ERR" in *"secret-value pattern"*) pass "without the allowlist the same file blocks (the narrowing is what excluded it)";;
    *) fail "blocked, but not on the secret scan: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 17: regression P2 — --page-source-only reaching through a parent symlinked OUTSIDE the repo -> BLOCK (lexical guards cannot see an intermediate symlink; the kernel resolves it and the copy materializes the outside bytes as ordinary staged content)"
T=$(mktemp_d); OUTSIDE=$(mktemp_d); make_experiment_repo "$T"
printf 'key = %s\n' "$REAL_GHP" > "$OUTSIDE/secret.txt"
ln -s "$OUTSIDE" "$T/dashboard/exp/link"
if run_dry "$T/reg/exp" --page-source "$T/dashboard/exp" --page-source-only link/secret.txt; then
  fail "regression P2: an out-of-tree file reached through a symlinked parent was accepted into the page-source allowlist"; else
  case "$LAST_ERR" in
    *"reaches through a symlinked parent"*)
      # The BLOCK must land BEFORE staging: if the bytes had been copied in, the secret scan would have been
      # the thing that fired. Either message is a "BLOCK"; only one of them means nothing was staged.
      case "$LAST_ERR" in *"secret-value pattern"*|*"$REAL_GHP"*) fail "regression P2: blocked, but the outside file's content was staged/read first";;
        *) pass "regression P2: the out-of-tree file is refused before staging, so its bytes never enter the worktree";; esac;;
    *) fail "regression P2: blocked, but not on the physical-parent guard: $LAST_ERR";; esac; fi
rm -rf "$T" "$OUTSIDE"

echo "[smoke] case 18: invariant 8 — a whole-dir page-source staging whose subdir is a symlink OUTSIDE the repo -> BLOCK (nobody named that path, so only the enumerated-set check can catch it)"
T=$(mktemp_d); OUTSIDE=$(mktemp_d); make_experiment_repo "$T"
printf 'key = %s\n' "$REAL_GHP" > "$OUTSIDE/secret.txt"
ln -s "$OUTSIDE" "$T/dashboard/exp/link"
if run_dry "$T/reg/exp" --page-source "$T/dashboard/exp"; then
  fail "a symlinked subdir pointing outside the repo staged its target's bytes as ordinary content"; else
  case "$LAST_ERR" in
    *"symlinked parent directory that leaves the tree"*) pass "the enumerated staged set is physically contained per file";;
    *"staged symlink"*) pass "the staged symlink itself is refused (the older wholesale rule, #416)";;
    *) fail "blocked, but not on a containment/symlink guard: $LAST_ERR";; esac; fi
rm -rf "$T" "$OUTSIDE"

echo "[smoke] case 19: invariant 8 — a legitimate nested path under a REAL subdirectory still passes (the guard rejects symlinked parents, not nesting)"
T=$(mktemp_d); make_experiment_repo "$T"
mkdir -p "$T/dashboard/exp/sub"; printf 'def s():\n    return 19\n' > "$T/dashboard/exp/sub/p.py"
if run_dry "$T/reg/exp" --page-source "$T/dashboard/exp" --page-source-only sub/p.py; then
  pass "a nested page-source path under a real directory is unaffected"; else
  fail "the physical-parent guard rejected a legitimate nested path: $LAST_ERR"; fi
rm -rf "$T"

echo "[smoke] case 20: regression P3 — a file DELETED from the page-source dir lands as a deletion in the same commit (mirror, not overlay)"
# The record and the page source are already in base byte-identically, so a deletion in the page-source tree
# is the ONLY thing that can be staged. Pre-fix, the existing files were overlaid onto the base checkout and
# `git add` saw no removal at all -> the run died "nothing to commit".
T=$(mktemp_d); make_landed_repo "$T"
rm -f "$T/dashboard/exp/stale.py"
if run_dry "$T/reg/exp" --page-source "$T/dashboard/exp"; then
  pass "regression P3: the page-source deletion is staged (the mirror clears the staged root first)"; else
  case "$LAST_ERR" in *"nothing to commit"*) fail "regression P3: the deletion was silently omitted — the page-source tree was overlaid, not mirrored";;
    *) fail "regression P3: blocked for another reason: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 21: invariant 9 — --page-source-only narrows the MIRROR: a deletion INSIDE the named subtree lands, one OUTSIDE it does not"
T=$(mktemp_d); make_landed_repo "$T"
rm -f "$T/dashboard/exp/sub/inner.py"
if run_dry "$T/reg/exp" --page-source "$T/dashboard/exp" --page-source-only sub; then
  pass "a deletion inside the narrowed subtree lands with the same delete semantics"; else
  fail "the narrowed mirror missed a deletion inside its own subtree: $LAST_ERR"; fi
rm -rf "$T"
T=$(mktemp_d); make_landed_repo "$T"
rm -f "$T/dashboard/exp/stale.py"          # OUTSIDE the --page-source-only subtree
if run_dry "$T/reg/exp" --page-source "$T/dashboard/exp" --page-source-only sub; then
  fail "the narrowed mirror deleted a file outside the subtree it was told to mirror"; else
  case "$LAST_ERR" in *"nothing to commit"*) pass "a deletion outside the narrowed subtree is NOT staged (the narrowing bounds the delete)";;
    *) fail "blocked for another reason: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 22: invariant 7 — the RECORD root is NOT mirrored: a file deleted from the record dir is left exactly as before (unchanged semantics)"
T=$(mktemp_d); make_landed_repo "$T"
rm -f "$T/reg/exp/notes.txt"              # deleted from the record dir; base still has it
printf 'new page\n' > "$T/dashboard/exp/new.py"   # something to commit, so this tests the record half only
if run_dry "$T/reg/exp" --page-source "$T/dashboard/exp"; then
  pass "the record root still overlays (its deletions are not staged) — no behaviour change on the record half"; else
  fail "the record half changed behaviour: $LAST_ERR"; fi
rm -rf "$T"

echo "[smoke] case 23: invariant 7 — --page-source on a KIND=note landing -> BLOCK (the publish leg belongs to an experiment close)"
T=$(mktemp_d); make_experiment_repo "$T"
mkdir -p "$T/reg/notes"; printf 'a note\n' > "$T/reg/notes/note.md"
if run_dry "$T/reg/notes" --page-source "$T/dashboard/exp"; then fail "--page-source accepted on a note landing"; else
  case "$LAST_ERR" in *"only supported for KIND=experiment"*) pass "--page-source refused for a non-experiment kind";;
    *) fail "blocked, but not on the kind check: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 24: regression 823-P0 — a --page-source dir that stages NOTHING and is absent from base -> BLOCK (the approval must be read off the staged set, not off the flag)"
# PR #823 round 1 P0: gate_page_source runs BEFORE staging, so it could only ever see that the flag was
# PASSED. An EMPTY page-source dir contributed nothing while the record's own changes kept the overall
# staged diff non-empty, so stage_worktree's "nothing to commit" never fired either — the PR merged with
# paperwork saying the page source rode it and no page source in it.
T=$(mktemp_d); make_experiment_repo "$T"
rm -f "$T/dashboard/exp/page.py"          # the page was never built into the dir; base has nothing there
if run_dry "$T/reg/exp" --page-source "$T/dashboard/exp"; then
  fail "regression 823-P0: a page source that reaches the commit nowhere was approved as having landed"; else
  case "$LAST_ERR" in *"contributes NOTHING to this commit"*) pass "regression 823-P0: an empty page-source landing is refused";;
    *) fail "regression 823-P0: blocked, but not on the staged-landing check: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 25: regression 823-P0 — the same dir, wholly gitignored and waved through with --skip-ignored -> still BLOCK (the ignore guard's escape hatch must not buy a false landing claim)"
T=$(mktemp_d); make_experiment_repo "$T"
printf '*\n' > "$T/dashboard/exp/.gitignore"   # every page file excluded; .gitignore itself is copied as a rule file, and is ignored by its own '*'
if run_dry "$T/reg/exp" --page-source "$T/dashboard/exp" --skip-ignored; then
  fail "regression 823-P0: --skip-ignored waved through a PR claiming a page source none of which is staged"; else
  case "$LAST_ERR" in *"contributes NOTHING to this commit"*) pass "regression 823-P0: an all-ignored page source cannot be acknowledged into a landing claim";;
    *) fail "regression 823-P0: blocked, but not on the staged-landing check: $LAST_ERR";; esac; fi
rm -rf "$T"

echo "[smoke] case 26: invariant 7 — a page source UNCHANGED from base is recorded as unchanged, not claimed as a landing (and does not deadlock the re-log)"
# The counterpart to case 24: nothing staged, but the tree this PR lands on already carries the page source.
# Nothing is missing, so blocking would deadlock a legitimate re-log (the gate REQUIRES --page-source on a
# viewer-recipe close, and --page-source-external means a DIFFERENT repo) — only the wording was ever wrong.
T=$(mktemp_d); make_landed_repo "$T"
printf 'a late audit response\n' > "$T/reg/exp/AUDIT_RESPONSE.md"   # the record changed; the page source did not
if run_dry "$T/reg/exp" --page-source "$T/dashboard/exp"; then
  case "$LAST_ERR" in *"already carries it"*) pass "an unchanged page source is stated as unchanged, and the re-log proceeds";;
    *) fail "passed, but the unchanged page source was not stated as such: $LAST_ERR";; esac
  # The --dry-run summary previews the real landing, so it must not report "staged" either (case 2 asserts
  # the positive form of this same line, so the two together pin both verdicts to the staged set).
  case "$LAST_ERR" in *"staged (mirrored) in the same commit"*) fail "the dry-run summary still claimed the unchanged page source was staged";;
    *) pass "the dry-run summary reports it as unchanged rather than staged";; esac
else fail "a re-log whose page source was already landed was BLOCKED: $LAST_ERR"; fi
rm -rf "$T"

echo "[smoke] case 27: invariant 9 — --page-source-only can NAME a deleted file directly (a mirror that cannot express one deletion is not a mirror)"
# PR #823 round 1 P1: the allowlist's existence check refused the deleted path outright, so the only way to
# mirror one deletion was to widen the allowlist to a surviving parent dir.
T=$(mktemp_d); make_landed_repo "$T"
rm -f "$T/dashboard/exp/stale.py"
if run_dry "$T/reg/exp" --page-source "$T/dashboard/exp" --page-source-only stale.py; then
  case "$LAST_ERR" in *"mirroring it as a DELETION"*) pass "a deleted page file can be named directly and lands as a deletion";;
    *) fail "passed, but the deletion was not recognized as one: $LAST_ERR";; esac
else fail "naming the deleted file directly was refused: $LAST_ERR"; fi
rm -rf "$T"

echo "[smoke] case 28: invariant 9 — a --page-source-only path in NEITHER the working tree nor base is still a typo -> BLOCK (the deletion allowance must not become a silent no-op)"
T=$(mktemp_d); make_landed_repo "$T"
if run_dry "$T/reg/exp" --page-source "$T/dashboard/exp" --page-source-only nosuchfile.py; then
  fail "a page-source allowlist path that exists nowhere was accepted"; else
  case "$LAST_ERR" in *"nothing at dashboard/exp/nosuchfile.py to mirror as a deletion"*) pass "a nonexistent, never-committed allowlist path still fails closed";;
    *) fail "blocked, but not on the allowlist existence check: $LAST_ERR";; esac; fi
rm -rf "$T"

if [ "$FAILS" -eq 0 ]; then echo "[smoke] log-experiment page-source: ALL PASS"; exit 0; else
  echo "[smoke] log-experiment page-source: $FAILS FAILURE(S)" >&2; exit 1; fi
