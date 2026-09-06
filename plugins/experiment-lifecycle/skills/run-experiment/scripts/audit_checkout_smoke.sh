#!/usr/bin/env bash
# Smoke for audit_checkout.sh — the close-audit clean-room checkout lifecycle (automated-researcher#840).
# Runs OFFLINE against real local git fixtures (no network): worktree/sparse-checkout behavior is exactly
# git's own, so faking it would just re-implement git badly. Covers the properties the incident turns on:
#   - create: the path is MINTED, never taken from the caller — `<temp root>/<exp>-audit.<random>`, the one
#     shape repo-janitor's backstop glob can name (10.7G of ad-hoc-named clones from ONE close is what made
#     the sweep unable to catch them), and only that path is printed on stdout so `$( )` capture is exact
#   - create is SPARSE (#805): the named `registry/<exp>` record materializes and the rest of the heavy
#     tree does not, and it lands DETACHED so the ordinary `create <exp> main` call cannot be refused for
#     "branch already checked out" and the verdict names a fixed commit
#   - reap: removes the checkout via `git worktree remove` (leaving no stale administrative record), and is
#     idempotent — a second reap of an already-gone path is a silent success, not an error a close trips on
#   - reap's STATICALLY BOUNDED delete, every guard fail-closed to "reported, still on disk": a path
#     outside the temp root, a nested (non-direct-child) path, a name without the `-audit.` shape, a
#     symlink, and a directory that is not a linked worktree
#   - the slug is RESTRICTED, not sanitized: a '/' or a glob metacharacter is refused, because the slug
#     becomes both a path segment and the backstop glob's own target
#   - audit_experiment.sh --reap-checkout carries the path through to the verdict-written moment, and an
#     unresolvable helper prints a reap-by-hand line rather than deriving a delete of its own
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
A="$HERE/audit_checkout.sh"
AUDIT="$HERE/../../../../verify-claims/skills/verify-claims/scripts/audit_experiment.sh"
[ -f "$A" ] || { echo "FAIL: missing $A"; exit 1; }

TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

fails=0
ok(){ echo "ok   $1"; }
no(){ echo "FAIL $1"; fails=1; }

g(){ git -C "$1" "${@:2}" >/dev/null 2>&1 || { echo "FIXTURE SETUP FAILED: git -C $1 ${*:2}" >&2; exit 1; }; }

REPO="$TMP/repo"
git init -q -b main "$REPO"
g "$REPO" config user.email t@example.com
g "$REPO" config user.name smoke
mkdir -p "$REPO/pipelines" "$REPO/registry/exp-1" "$REPO/registry/exp-2"
echo driver   > "$REPO/pipelines/run.py"
echo results1 > "$REPO/registry/exp-1/RESULTS.md"
echo results2 > "$REPO/registry/exp-2/RESULTS.md"
g "$REPO" add -A
g "$REPO" commit -q -m init

ROOT="$TMP/audit-tmp"; mkdir -p "$ROOT"
export AUDIT_CHECKOUT_TMPDIR="$ROOT"
cd "$TMP" || { echo "FAIL: cd $TMP"; exit 1; }

# --- create ----------------------------------------------------------------------------------------
WT=$(bash "$A" create exp-1 --repo "$REPO" -- main registry/exp-1 2>"$TMP/create.err")
rc=$?
[ "$rc" = 0 ] && ok create-exit0 || no "create-exit0 (rc=$rc, stderr: $(cat "$TMP/create.err"))"
# STDOUT is the path and nothing else — a log line leaking onto stdout corrupts every `$( )` caller.
[ -d "$WT" ] && ok create-path-exists || no "create-path-exists (stdout was '$WT')"
case "$WT" in "$ROOT"/exp-1-audit.*) ok create-fixed-prefix ;; *) no "create-fixed-prefix (got '$WT')" ;; esac
[ "$(dirname "$WT")" = "$ROOT" ] && ok create-direct-child || no "create-direct-child (got '$WT')"
# ...and it is not the caller's chosen name: a second create for the same experiment gets its own path.
WT2=$(bash "$A" create exp-1 --repo "$REPO" -- main registry/exp-1 2>/dev/null)
[ -n "$WT2" ] && [ "$WT2" != "$WT" ] && ok create-unique-per-call || no "create-unique-per-call ('$WT2' vs '$WT')"

# sparse (#805): the NAMED record is materialized, the other one is not, and the non-heavy trees are.
[ -f "$WT/registry/exp-1/RESULTS.md" ] && ok create-sparse-includes-named-record || no create-sparse-includes-named-record
[ -e "$WT/registry/exp-2" ] && no "create-sparse-excludes-other-records (registry/exp-2 materialized)" || ok create-sparse-excludes-other-records
[ -f "$WT/pipelines/run.py" ] && ok create-sparse-keeps-code || no create-sparse-keeps-code

# detached: `create <exp> main` must not be refused for "branch already checked out" (main is checked out
# in the shared checkout, which is the normal state), and the verdict must name a fixed commit.
git -C "$WT" symbolic-ref -q HEAD >/dev/null 2>&1 && no "create-detached (HEAD is on a branch)" || ok create-detached
[ "$(git -C "$WT" rev-parse HEAD)" = "$(git -C "$REPO" rev-parse main)" ] && ok create-at-committish || no create-at-committish

# a linked worktree, so repo-janitor sees it in `git worktree list` and removal has git's refusals behind it
git -C "$REPO" worktree list --porcelain | grep -qxF "worktree $WT" && ok create-is-listed-worktree || no create-is-listed-worktree

# --- the slug is restricted, not sanitized ----------------------------------------------------------
for bad in "../escape" "exp/1" 'exp*1' ".hidden" ""; do
  if bash "$A" create "$bad" --repo "$REPO" -- main >/dev/null 2>&1; then
    no "slug-refused ('$bad' accepted — it becomes a path segment and the backstop glob's target)"
  else
    ok "slug-refused ('$bad')"
  fi
done
# nothing was created by any of those
[ "$(find "$ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" = 2 ] && ok slug-refused-created-nothing \
  || no "slug-refused-created-nothing ($(find "$ROOT" -mindepth 1 -maxdepth 1 -type d))"

# --- reap: bounded delete, every guard fail-closed --------------------------------------------------
# outside the temp root
outside="$TMP/outside-audit.aaa"; mkdir -p "$outside"
if bash "$A" reap "$outside" >/dev/null 2>&1; then no reap-outside-root-refused; else ok reap-outside-root-refused; fi
[ -d "$outside" ] && ok reap-outside-root-kept || no reap-outside-root-kept

# not a DIRECT child (the bound is exactly one level, not "anywhere under the root")
nested="$ROOT/deeper/x-audit.bbb"; mkdir -p "$nested"
if bash "$A" reap "$nested" >/dev/null 2>&1; then no reap-nested-refused; else ok reap-nested-refused; fi
[ -d "$nested" ] && ok reap-nested-kept || no reap-nested-kept

# right place, wrong NAME shape — an unrelated dir under the temp root is not an audit checkout
wrongname="$ROOT/some-build-dir"; mkdir -p "$wrongname"
if bash "$A" reap "$wrongname" >/dev/null 2>&1; then no reap-wrong-name-refused; else ok reap-wrong-name-refused; fi
[ -d "$wrongname" ] && ok reap-wrong-name-kept || no reap-wrong-name-kept

# a symlink: removing it would leave the tree it points at (and could remove a real one via the link)
ln -s "$WT" "$ROOT/linked-audit.ccc"
if bash "$A" reap "$ROOT/linked-audit.ccc" >/dev/null 2>&1; then no reap-symlink-refused; else ok reap-symlink-refused; fi
[ -d "$WT" ] && ok reap-symlink-target-kept || no "reap-symlink-target-kept (the real checkout was removed through the link)"
rm -f "$ROOT/linked-audit.ccc"

# right place, right name, but NOT a linked worktree — `create` never made it, so it is reported
plain="$ROOT/hand-made-audit.ddd"; mkdir -p "$plain"; echo data > "$plain/keep.txt"
if bash "$A" reap "$plain" >/dev/null 2>&1; then no reap-non-worktree-refused; else ok reap-non-worktree-refused; fi
[ -f "$plain/keep.txt" ] && ok reap-non-worktree-kept || no reap-non-worktree-kept

# ...and a full CLONE at the right shape is not a linked worktree either (its git dir IS its own), so the
# clone-shaped leftovers the incident actually found are reported rather than destroyed by this helper.
git clone -q "$REPO" "$ROOT/cloned-audit.eee" 2>/dev/null
if bash "$A" reap "$ROOT/cloned-audit.eee" >/dev/null 2>&1; then no reap-clone-refused; else ok reap-clone-refused; fi
[ -d "$ROOT/cloned-audit.eee" ] && ok reap-clone-kept || no reap-clone-kept

# the happy path: really removed, with no stale administrative record left behind
if bash "$A" reap "$WT" >/dev/null 2>&1; then ok reap-exit0; else no reap-exit0; fi
[ -e "$WT" ] && no reap-removed || ok reap-removed
git -C "$REPO" worktree list --porcelain | grep -qxF "worktree $WT" && no "reap-no-stale-record (still listed)" || ok reap-no-stale-record

# idempotent: a close that reaps twice (or after repo-janitor got there first) must not fail
if bash "$A" reap "$WT" >/dev/null 2>&1; then ok reap-idempotent; else no reap-idempotent; fi

# --- audit_experiment.sh --reap-checkout carries the path through ------------------------------------
if [ -f "$AUDIT" ]; then
  expdir="$TMP/exp"; mkdir -p "$expdir"
  echo "RESULTS" > "$expdir/RESULTS.md"
  echo "DESIGN"  > "$expdir/DESIGN.md"
  # The flag must compose with the mode flags in EITHER order — a caller shouldn't have to know which
  # comes first. AUDIT_PRINT_VERIFIER echoes the parsed value without invoking a model.
  for order in "--reap-checkout;$WT2;--design" "--design;--reap-checkout;$WT2"; do
    IFS=';' read -r -a argv <<< "$order"
    out=$(AAR_SUBSTRATE=claude AUDIT_PRINT_VERIFIER=1 bash "$AUDIT" "${argv[@]}" "$expdir" 2>/dev/null) || true
    case "$out" in
      *"REAP_CHECKOUT=$WT2"*) ok "audit-flag-parsed ($order)" ;;
      *) no "audit-flag-parsed ($order) (output was: $out)" ;;
    esac
  done

  # A stub auditor as a shell command line — AUDIT_VERIFIER_CMD's documented contract: it is eval'd in the
  # script's own shell and writes its final answer to "$OUT_TMP". Single-quoted here so $OUT_TMP is
  # expanded THERE, not by this smoke.
  STUB_VERIFIER='printf "FINDING 1: LOW [smoke]\nSUMMARY: high=0 med=0 low=1\n" > "$OUT_TMP"'

  # An unresolvable helper prints a reap-by-hand line and NEVER deletes: verify-claims is independently
  # installable, so an absent sibling plugin must not become an `rm -rf` reimplemented there.
  keep=$(bash "$A" create exp-2 --repo "$REPO" -- main registry/exp-2 2>/dev/null)
  errout=$(AAR_SUBSTRATE=claude AUDIT_VERIFIER_CMD="$STUB_VERIFIER" AUDIT_CHECKOUT_HELPER="$TMP/no-such-helper.sh" \
    bash "$AUDIT" --reap-checkout "$keep" "$expdir" 2>&1 >/dev/null) || true
  case "$errout" in
    *"REAP BY HAND"*"$keep"*) ok audit-unresolvable-helper-says-so ;;
    *) no "audit-unresolvable-helper-says-so (stderr was: $errout)" ;;
  esac
  [ -d "$keep" ] && ok audit-unresolvable-helper-deletes-nothing || no "audit-unresolvable-helper-deletes-nothing (the checkout was deleted without the helper)"
  [ -f "$expdir/AUDIT.md" ] && ok audit-verdict-written || no audit-verdict-written

  # ...and with the helper resolvable, the verdict being written is what reaps it.
  rm -f "$expdir/AUDIT.md"
  AAR_SUBSTRATE=claude AUDIT_VERIFIER_CMD="$STUB_VERIFIER" AUDIT_CHECKOUT_HELPER="$A" \
    bash "$AUDIT" --reap-checkout "$keep" "$expdir" >/dev/null 2>&1 || true
  [ -e "$keep" ] && no "audit-reaps-on-verdict (the checkout survived a written verdict)" || ok audit-reaps-on-verdict
  [ -f "$expdir/AUDIT.md" ] && ok audit-reaps-after-verdict-written || no audit-reaps-after-verdict-written

  # A FAILED audit keeps its clean-room tree for forensics — the same disposition a parked run's scratch
  # gets. A verifier that writes nothing is the "auditor produced no findings file" block.
  rm -f "$expdir/AUDIT.md"
  forensic=$(bash "$A" create exp-2 --repo "$REPO" -- main registry/exp-2 2>/dev/null)
  AAR_SUBSTRATE=claude AUDIT_VERIFIER_CMD='true' AUDIT_CHECKOUT_HELPER="$A" \
    bash "$AUDIT" --reap-checkout "$forensic" "$expdir" >/dev/null 2>&1 && \
    no "audit-failed-run-exits-nonzero" || ok audit-failed-run-exits-nonzero
  [ -d "$forensic" ] && ok audit-failed-run-keeps-checkout || no "audit-failed-run-keeps-checkout (a blocked audit lost its clean-room tree)"
  bash "$A" reap "$forensic" >/dev/null 2>&1 || true
else
  echo "note: $AUDIT not present (verify-claims not checked out beside experiment-lifecycle) — integration cases skipped"
fi

[ "$fails" = 0 ] && { echo "audit_checkout smoke PASS"; exit 0; } || { echo "audit_checkout smoke FAIL"; exit 1; }
