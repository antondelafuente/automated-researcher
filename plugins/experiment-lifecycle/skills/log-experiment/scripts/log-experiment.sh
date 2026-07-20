#!/usr/bin/env bash
# log-experiment.sh <registry-dir> [--dry-run] [--skip-ignored]
#   --skip-ignored proceeds WITHOUT the flagged gitignored files (acknowledge-and-exclude) — it never
#   force-includes them into the commit.
#
# Log a research-repo registry directory to GitHub as a GATED pull request and merge it.
# The gate is chosen by the directory's own content (auditability via the registry convention):
#   - experiment   (DESIGN.md + RESULTS.md):   verify the close-audit is present and clean.
#   - design-stage (DESIGN.md, no RESULTS.md): verify the design-audit (DESIGN_AUDIT*.md) is present, the
#                                               Presentation section carries the researcher's lock line, + secret scan.
#   - note         (anything else):            deterministic secret scan only.
# Every kind, additionally, gets a deterministic symlink check: a registry record has no legitimate use for a
# staged symlink (the intent is always to copy a reference file's real bytes), so ANY staged symlink is a
# BLOCK regardless of KIND — a committed symlink's target is only ever meaningful on the machine, or worse the
# specific session, that created it.
# A cross-family engineer-bot approval satisfies the research repo's branch protection
# (the author cannot approve their own PR). Self-contained: this does NOT source wf.sh.
#
# Ignored-file guard (#340): a plain `git add` silently drops anything the BASE tree's .gitignore matches —
# fine for the R2-scale artifacts it's meant to keep out of git, but a small *pinned* file (e.g. a frozen
# instrument the DESIGN.md declares "committed with this design") can share the same ignored extension and
# vanish with no trace. After staging, any non-trivial (not `.DS_Store`/`__pycache__`/etc.) file under the
# dir that the .gitignore excluded is printed and BLOCKS; pass --skip-ignored to acknowledge and proceed
# when the exclusion really is an intentional R2-scale one.
#
# Config (instance, env-overridable; NO instance defaults — fail closed):
#   RESEARCH_REPO                    the research repo (owner/repo). REQUIRED; the input dir's origin must match it.
#                                    Env is the OVERRIDE; if unset it is bridged from the instance profile's
#                                    [github] research_repo (#258 — see the profile bridge below).
#   LOG_EXPERIMENT_BASE_BRANCH       the branch to fork/target (default 'main'); if unset, bridged from
#                                    [github] base_branch, else 'main'.
#   LOG_EXPERIMENT_AUTHOR_FAMILY     claude|codex. Defaults to $AAR_SUBSTRATE; fail-closed if neither is set
#                                    (a wrong default must not make the review same-family). Reviewer = OPPOSITE family.
#   LOG_EXPERIMENT_TOKEN_CMD_CLAUDE  command taking <owner/repo> that mints a claude-engineer token.
#   LOG_EXPERIMENT_TOKEN_CMD_CODEX   command taking <owner/repo> that mints a codex-engineer token.
#                                    AUTHOR family -> writes; OPPOSITE family -> approval. Fail-closed if unset.
#   LOG_EXPERIMENT_GIT_AUTHOR_CLAUDE the 'Name <email>' the claude bot commits as.
#   LOG_EXPERIMENT_GIT_AUTHOR_CODEX  the 'Name <email>' the codex bot commits as.
set -euo pipefail

# Config (instance, env-overridable). RESEARCH_REPO has NO hardcoded default — the env OVERRIDES; if unset it
# is bridged from the instance profile below, then fail-closed if still empty.
RESEARCH_REPO="${RESEARCH_REPO:-}"
AUTHOR_FAMILY="${LOG_EXPERIMENT_AUTHOR_FAMILY:-${AAR_SUBSTRATE:-}}"   # the running family (NO default — fail closed if unknown); reviewer is the OPPOSITE family

die()  { echo "BLOCK: $*" >&2; exit 1; }
note() { echo "[log-experiment] $*" >&2; }

# The aar-profile snapshot helper (#469) — a byte-identical copy of design-experiment/scripts/
# aar_profile_snapshot.sh (checks.sh asserts the two stay in sync). gate_design_stage below is this
# product's single deterministic owner of the `check` verb.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAPSHOT_HELPER="$SELF_DIR/aar_profile_snapshot.sh"

# ---- instance-profile bridge (#258): fill UNSET non-secret config from aar-profile.{toml,json} ----
# The #245 profile (`[github] research_repo`, `base_branch`) is the config home, but nothing bridged those
# values into the vars this script reads, so a MANUAL/scripted `log-experiment.sh <dir>` on a correctly-
# configured instance died with "RESEARCH_REPO is required". This fallback fixes that WITHOUT re-reading live
# config on the executor path: it fills ONLY vars the env left unset (env stays the override), and it touches
# ONLY non-secret config (research_repo + base_branch). Identity seams stay env-only (the profile merely NAMES
# those env vars, which must be set regardless). Contract note (SCHEMA role split): the executor close path
# derives config from its frozen START.md snapshot exported to env — that env OVERRIDES this bridge, so the
# live profile is consulted only by the MANUAL logging path (no snapshot in play). Tolerant + fail-open: a
# missing/unparseable profile, absent python3, or an unknown schema_version leaves the env-only behavior intact
# (a still-empty RESEARCH_REPO fails closed downstream as before).
# read_profile_field <key>: print the string value of `[github].<key>` from the resolved profile, or nothing.
# NOTE: the value is emitted RAW on stdout and read straight into a bash variable by the caller (no `eval` —
# a profile value is never shell-interpreted, so a value like `$(cmd)` stays an inert literal). It is then
# format-validated below before use. python3 stdlib only (tomllib/json), matching the SCHEMA parser policy.
read_profile_field() {
  command -v python3 >/dev/null 2>&1 || return 0
  PROFILE_KEY="$1" python3 - <<'PY' 2>/dev/null || true
import os, sys, json
try:
    import tomllib
except Exception:
    tomllib = None
cands = []
if os.environ.get("AAR_PROFILE"):
    cands.append(os.environ["AAR_PROFILE"])
base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
d = os.path.join(base, "experiment-lifecycle")
cands += [os.path.join(d, "aar-profile.toml"), os.path.join(d, "aar-profile.json")]   # .toml wins (SCHEMA)
path = next((c for c in cands if c and os.path.isfile(c)), None)
if not path:
    sys.exit(0)
try:
    if path.endswith(".toml"):
        if tomllib is None:
            sys.exit(0)
        with open(path, "rb") as f:
            data = tomllib.load(f)
    else:
        with open(path) as f:
            data = json.load(f)
except Exception:
    sys.exit(0)
# Tolerant: bridge a v1 profile OR a pre-#153 profile that omits schema_version; never interpret an unknown MAJOR.
sv = data.get("schema_version")
if sv is not None and sv != 1:
    sys.exit(0)
v = (data.get("github", {}) or {}).get(os.environ["PROFILE_KEY"])
if isinstance(v, str) and v and "\n" not in v:
    sys.stdout.write(v)   # RAW, single value, no newline — caller reads it literally (no eval)
PY
}
# Fill ONLY unset config from the profile (env stays the override); validate any profile-sourced value to a
# conservative charset (owner/repo, branch names) so a malformed/hostile profile can't inject a shell metachar.
_valid_ref() { [[ "$1" =~ ^[A-Za-z0-9._/-]+$ ]]; }
if [ -z "$RESEARCH_REPO" ]; then
  _pv="$(read_profile_field research_repo)"
  if [ -n "$_pv" ]; then
    _valid_ref "$_pv" || die "profile [github].research_repo has invalid characters: '$_pv'"
    RESEARCH_REPO="$_pv"
  fi
fi
BASE_BRANCH="${LOG_EXPERIMENT_BASE_BRANCH:-}"
if [ -z "$BASE_BRANCH" ]; then
  _pv="$(read_profile_field base_branch)"
  if [ -n "$_pv" ]; then
    _valid_ref "$_pv" || die "profile [github].base_branch has invalid characters: '$_pv'"
    BASE_BRANCH="$_pv"
  fi
fi
BASE_BRANCH="${BASE_BRANCH:-main}"

# ---- args ----
DRY_RUN=0; SKIP_IGNORED=0; DIR=""
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    --skip-ignored) SKIP_IGNORED=1 ;;
    -*) die "unknown flag: $a" ;;
    *) DIR="$a" ;;
  esac
done
[ -n "$DIR" ] || die "usage: log-experiment.sh <registry-dir> [--dry-run] [--skip-ignored]"
[ -d "$DIR" ] || die "not a directory: $DIR"
DIR="$(cd "$DIR" && pwd)"   # absolute — stable across the later cd into the repo root

REPO_ROOT="$(cd "$DIR" && git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repo: $DIR"
REL="$(cd "$REPO_ROOT" && realpath --relative-to="$REPO_ROOT" "$DIR")"
[ "${REL#..}" = "$REL" ] || die "dir is outside the repo root"
SLUG="$(basename "$REL" | tr -c 'A-Za-z0-9._-' '-' | sed 's/-*$//')"

# ---- classify (registry convention; KIND file is an explicit override) ----
KIND=""
[ -f "$DIR/KIND" ] && KIND="$(tr -d '[:space:]' < "$DIR/KIND")"
if [ -z "$KIND" ]; then
  if   [ -f "$DIR/DESIGN.md" ] && [ -f "$DIR/RESULTS.md" ]; then KIND="experiment"     # results leg: close-audit gate
  elif [ -f "$DIR/DESIGN.md" ];                                then KIND="design-stage"  # design leg: design-audit gate
  else                                                              KIND="note"; fi       # everything else: secret scan
fi
note "classified: $KIND  ($REL)"

# A close-audit triage/response section, recognized in EITHER form (#263): a separate AUDIT_RESPONSE.md, OR a
# response section appended INLINE in AUDIT.md (a markdown heading whose text mentions 'respons…'/'triage' —
# e.g. `## Executor responses`, `## Author triage`). Shared by the experiment gate and post_audit_thread so
# both agree on what counts as triage. `audit_experiment.sh` itself already treats an inline "audit-response
# section" as valid triage in its re-run debate, so the log gate should not force a separate file.
AUDIT_RESPONSE_HEADING_RE='^#{1,6}[[:space:]].*(respons|triage)'
# echo the line number of the first inline response heading in $1 (empty if none)
inline_response_line() { grep -niE "$AUDIT_RESPONSE_HEADING_RE" "$1" 2>/dev/null | head -n1 | cut -d: -f1; }

# ---- gate (fail-closed) ----
gate_experiment() {
  [ -f "$DIR/RESULTS.md" ] || die "experiment missing RESULTS.md"
  if [ -f "$DIR/AUDIT.md" ]; then
    # Require the close-audit to have been TRIAGED, accepting either the separate-file or inline form (#263).
    # This VERIFIES the audit ran and was triaged; it does not re-derive triage (a machine-readable
    # close-triage contract is a future hardening — see proposal #240 "Gate detail").
    if [ -f "$DIR/AUDIT_RESPONSE.md" ]; then
      APPROVAL_BODY="Experiment record — close-audit ran and was triaged (AUDIT.md + AUDIT_RESPONSE.md present). Verified per registry convention."
      note "experiment gate ok: close-audit present and triaged (separate AUDIT_RESPONSE.md)"
    elif [ -n "$(inline_response_line "$DIR/AUDIT.md")" ]; then
      APPROVAL_BODY="Experiment record — close-audit ran and was triaged (AUDIT.md with an inline response/triage section). Verified per registry convention."
      note "experiment gate ok: close-audit present and triaged (inline response section in AUDIT.md)"
    else
      die "experiment has AUDIT.md but no triage — add an AUDIT_RESPONSE.md OR an inline response/triage section (e.g. '## Executor responses') in AUDIT.md — surface for human"
    fi
    # The gate VERIFIES the close-audit ran and was triaged. It deliberately does NOT prose-grep the responses
    # for unresolved HIGHs — that heuristic is unreliable (negation/scope games) and not a real proof.
    # Per-finding HIGH-resolution verification needs a machine-readable triage status (a documented future
    # hardening); the actual triage is done with discipline in run-experiment's close.
  else
    if grep -qiE '^[^A-Za-z0-9]*((decision|status|outcome|result)[^A-Za-z0-9]+)?(ANCHOR_FAILED|NO[ _-]?GO|GATE[ _]PASS=FALSE|GATE[ _]FAILED?|NULL RESULT|DIAGNOSTIC ONLY|STOPPED AT [A-Za-z0-9 _-]*GATE)' "$DIR/RESULTS.md"; then
      APPROVAL_BODY="Experiment record — eval-only/no-go run; no close-audit needed; RESULTS records a closed decision."
      note "experiment gate ok: no close-audit, RESULTS records a closed decision"
    else
      die "experiment has no AUDIT.md and RESULTS.md records no closed decision — surface for human"
    fi
  fi
}
secret_scan() {
  # Deterministic scan for secret-VALUE patterns in the EXACT set git has STAGED in the commit worktree $WT
  # (`git diff --cached`); dies (fail-closed) on a hit or an incomplete scan. Shared by the note gate and the
  # design-stage gate (a DESIGN-only dir was scanned as a 'note' before the design-stage kind existed — moving
  # it to design-stage must not drop that scan). MUST be called AFTER stage_worktree.
  #
  # SCOPE = the staged set == precisely what the PR will introduce, computed against the SAME base the worktree
  # was created from and under that base's .gitignore. This is why a pre-existing merged file (e.g. a committed
  # HTML page) no longer blocks a log that leaves it unchanged — `cp` writes identical bytes over the base
  # checkout, so `git add` stages nothing for it and it is not scanned (#306). Scanning the staged set (not a
  # working-tree-vs-base reconstruction) also means the scanned set can never diverge from the committed set:
  # no stale-base skew (we scan the post-fetch base the worktree holds) and no ignore-rule skew (the worktree's
  # index, not the dirty checkout's, decides what is staged).
  #
  # The sk- alternative carries a LEFT word-boundary guard ((^|[^A-Za-z0-9_-])) so it no longer matches inside a
  # long hyphenated identifier that merely contains 'sk-' (e.g. 'task-always-succeeds-…') (#306). The other
  # patterns (ghp_/github_pat_/AKIA/PEM) are distinctive enough to leave unguarded.
  [ -n "${WT:-}" ] && [ -d "$WT" ] || die "internal: secret_scan called before stage_worktree (no staged worktree)"
  local hits rc f pat; local -a files=()
  pat='(ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|(^|[^A-Za-z0-9_-])sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY)'
  # NUL-delimited (`-z`) so a path with a newline / quote / non-ASCII char is read RAW (not git-quoted) — else
  # such a staged file could be skipped by the scan while still being committed (a scan bypass). Keep only
  # existing regular files (a staged deletion names a path that is gone).
  while IFS= read -r -d '' f; do [ -n "$f" ] && [ -f "$WT/$f" ] && files+=("$WT/$f"); done < <(
    git -C "$WT" diff --cached -z --name-only)
  # stage_worktree already fails closed on an empty staged set ("nothing to commit"), so a scan reaching here
  # normally has files; guard anyway (a staged pure-deletion would leave nothing to scan — nothing to leak).
  [ "${#files[@]}" -gt 0 ] || { note "secret scan: no staged file content — nothing to scan"; return 0; }
  # -l: report only matching FILES, never the matched secret text. grep status: 0=match, 1=clean, >1=error
  # (unreadable file/traversal) -> fail closed (an incomplete scan must not read as clean). The `if` keeps
  # `set -e` from exiting on grep's normal exit 1.
  if hits="$(grep -laIE "$pat" -- "${files[@]}" 2>/dev/null)"; then rc=0; else rc=$?; fi
  [ "$rc" -le 1 ] || die "secret scan failed (grep exit $rc) — scan incomplete, refusing to log"
  [ -z "$hits" ] || { echo "secret-value pattern found in staged content (values redacted):" >&2
    printf '%s\n' "$hits" | sed "s#^$WT/#  #" >&2; die "$KIND contains secret-value patterns"; }
}
symlink_scan() {
  # Deterministic check for staged git symlinks (mode 120000) in the EXACT set git has STAGED in the commit
  # worktree $WT (same `git diff --cached` staged set secret_scan walks) — dies (fail-closed) on ANY hit.
  # MUST be called AFTER stage_worktree. Runs for EVERY kind (unlike secret_scan, which skips 'experiment'):
  # a registry record has no legitimate use for a symlink, whichever gate it's under — the intent is always
  # to copy the referenced file's real bytes, not a path.
  #
  # A committed symlink's target is only ever meaningful on the machine (absolute host path) or, worse, the
  # SPECIFIC SESSION (a path into that session's ephemeral /tmp scratchpad) that created it — it breaks the
  # registry's "reproduce from this dir alone" durability the moment that machine/session goes away, and it's
  # invisible to a normal file-content review (only `git ls-files -s` / `find -type l` surface the mode bit).
  # Rather than resolve each target and judge whether it happens to currently resolve inside the repo (fragile:
  # relative vs absolute, dangling, or a target that today lives in-repo by accident), reject ALL staged
  # symlinks wholesale — simpler, and a real copy is never the wrong choice for a registry record.
  [ -n "${WT:-}" ] && [ -d "$WT" ] || die "internal: symlink_scan called before stage_worktree (no staged worktree)"
  local hits="" meta mode path
  # --no-renames + raw mode line keeps the parse to one <meta>\0<path>\0 pair per entry (a rename/copy status
  # would otherwise emit a second path and desync the read loop). New-mode is the raw line's 2nd field.
  while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
    mode="${meta#* }"; mode="${mode%% *}"
    [ "$mode" = "120000" ] && hits="${hits}${hits:+$'\n'}$path"
  done < <(git -C "$WT" diff --cached --raw -z --no-renames --)
  [ -z "$hits" ] || { echo "staged symlink(s) found (a registry record must contain real file content, not a symlink):" >&2
    printf '%s\n' "$hits" | sed 's/^/  /' >&2; die "$KIND contains staged symlink(s)"; }
}
# Which kinds get a secret scan (note + design-stage; the experiment gate never scanned — preserved).
scan_if_needed() { case "$KIND" in note|design-stage) secret_scan ;; esac; }
gate_note() {
  APPROVAL_BODY="Record — deterministic secret scan clean; no experiment, so no audit."
  note "note gate ok (secret scan runs on the staged set)"
}
gate_design_stage() {
  # The design PR — the pre-launch leg of the two-PR flow. Verify the design-audit RAN (its numbered
  # DESIGN_AUDIT*.md chain is the validity record design-experiment emits), then run the same secret scan a
  # note gets. Like the experiment gate it verifies the audit is PRESENT, not that every finding was resolved
  # (a machine-readable triage status is a documented future hardening; the researcher invoking this at design
  # time is the clearance act — same human-in-the-loop trust model as the close gate).
  # Defend the invariant on the KIND-override path too (auto-classify only reaches here when DESIGN.md exists,
  # but a KIND=design-stage file bypasses that): a design-stage record IS a pre-registration.
  [ -f "$DIR/DESIGN.md" ]  || die "design-stage dir missing DESIGN.md — a design-stage record is a pre-registration"
  [ -f "$DIR/RESULTS.md" ] && die "design-stage dir unexpectedly has RESULTS.md — should classify as experiment"
  # Require a real design-audit OUTPUT — basename is EXACTLY DESIGN_AUDIT.md or DESIGN_AUDIT<digits>.md.
  # A DESIGN_AUDIT_RESPONSE.md / DESIGN_AUDIT2_RESPONSE.md shares the prefix but is NOT an audit -> excluded.
  _da=0
  for _f in "$DIR"/DESIGN_AUDIT*.md; do
    [ -f "$_f" ] || continue
    if [[ "$(basename "$_f")" =~ ^DESIGN_AUDIT[0-9]*\.md$ ]]; then _da=1; break; fi
  done
  [ "$_da" = 1 ] || die "design-stage dir has DESIGN.md but no design-audit output (DESIGN_AUDIT.md / DESIGN_AUDIT<N>.md; a *_RESPONSE.md does not count) — surface for human"
  # Require the machine-checkable presentation lock (#470): design-audit (above) runs BEFORE final clearance,
  # so it cannot check a lock that clearance itself produces — this is why enforcement lives HERE, at
  # design-stage logging, not in design-audit. The header convention is `## Presentation (locked with the
  # researcher <ISO date>)` (design-experiment SKILL.md, per the good example in
  # registry/csp1-author-sweep-1/DESIGN.md); a rerun inheriting a prior presentation by citation still carries
  # its own fresh lock date on this same header. Any heading level (#-######) is accepted.
  # The digit-shape [0-9]{4}-[0-9]{2}-[0-9]{2} alone accepts a nonsense date like 2026-99-99, so the extracted
  # date must additionally round-trip through GNU `date` (CI is Linux) — a real calendar date reproduces
  # itself, a fabricated one either fails to parse (empty output, redirected to /dev/null) or normalizes to a
  # different string.
  # `|| true` inside the substitution: under `pipefail` (set at the script top), a DESIGN.md with NO matching
  # header at all makes the first grep exit non-zero with no output, which would otherwise trip `set -e` on
  # this assignment and exit the script silently — before the `die` below ever runs.
  _lock_date="$(grep -oE '^#{1,6}[[:space:]]*Presentation[[:space:]]*\(locked with the researcher [0-9]{4}-[0-9]{2}-[0-9]{2}\)' "$DIR/DESIGN.md" \
    | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -n1 || true)"
  [ -n "$_lock_date" ] && [ "$(date -ud "$_lock_date" +%F 2>/dev/null)" = "$_lock_date" ] \
    || die "design-stage dir's DESIGN.md has no locked Presentation section — expected a header like '## Presentation (locked with the researcher <ISO date>)' recording the researcher's explicit in-chat lock on what to plot/rollouts/page story, with a real calendar date — surface for human"
  # #469: verify the START.md instance-profile snapshot is present, parseable, and NOT STALE relative to
  # the live profile — the deterministic gate that closes the silent viewer-publish miss (three closed
  # experiments never got a dashboard entry because nothing ever wrote or checked this block; only a
  # parenthetical mention of it existed in design-experiment/SKILL.md). This is the SINGLE enforcement
  # owner (not design-audit, which stays scoped to data-trustability) — a profile-less or unknown-schema
  # instance already failed closed at `aar_profile_snapshot.sh snapshot` time; this only re-verifies the
  # frozen block still matches. A viewer-less profile is a legitimate manifest-only instance and passes.
  [ -f "$DIR/START.md" ] || die "design-stage dir missing START.md — cannot verify its instance-profile snapshot (#469)"
  _snap_out="$("$SNAPSHOT_HELPER" check "$DIR/START.md" 2>&1)" || die "instance-profile snapshot check failed: $_snap_out"
  note "instance-profile snapshot: $_snap_out"
  APPROVAL_BODY="Design-stage record — design-audit present (DESIGN_AUDIT.md / DESIGN_AUDIT<N>.md), Presentation section locked with the researcher, instance-profile snapshot in START.md verified (#469), and secret scan clean; pre-launch leg of the two-PR flow."
  note "design-stage gate ok: design-audit present + Presentation lock found + instance-profile snapshot verified (secret scan runs on the staged set)"
}
case "$KIND" in
  experiment)   gate_experiment ;;
  design-stage) gate_design_stage ;;
  note)         gate_note ;;
  *)            die "unknown KIND override: '$KIND' (expected experiment|design-stage|note)" ;;
esac

# ---- dedicated worktree: stage $REL off origin/$BASE_BRANCH so the secret scan sees EXACTLY the commit set ----
# Used by BOTH the --dry-run gate and the real push path, so the SCANNED tree IS the COMMITTED tree — there is
# no working-tree-vs-index or stale-base skew between what we scan and what we push. cleanup + trap are armed
# before the first worktree creation on either path.
WT=""; BRANCH="log/${SLUG}"; CREATED_BRANCH=0   # only delete the branch in cleanup if THIS run created it
cleanup() { [ -n "$WT" ] && git -C "$REPO_ROOT" worktree remove --force "$WT" >/dev/null 2>&1 || true
            [ "$CREATED_BRANCH" = 1 ] && git -C "$REPO_ROOT" branch -D "$BRANCH" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# is_trivial_ignore <path>: well-known junk that is never meant to be committed regardless of context —
# excluded from the guard below so its output stays signal, not noise.
is_trivial_ignore() {
  case "$1" in
    */.DS_Store|.DS_Store|*/__pycache__/*|__pycache__/*|*.pyc|*.pyo|*/.ipynb_checkpoints/*|.ipynb_checkpoints/*|*~|*.swp) return 0 ;;
    *) return 1 ;;
  esac
}
# check_excluded_claim <excluded-file>...: BLOCK if RESULTS.md / ARTIFACT_MANIFEST.md verbatim-claims one of
# the given (already-known-excluded) files is "committed" — the exact prose/tree divergence #331 caught a day
# late (a curated 67-row sample dropped by a registry/**/*.jsonl ignore rule while the audited docs said it
# was committed). Match: basename (fixed-string, so a filename with regex metachars can't misfire) + a
# commit-claim word on the SAME line — a loose 'committ' substring both over-matches ("is NOT committed") and
# under-matches (bare "commit" lacks that substring); a doc mentioning the file in an R2/not-committed context
# is legitimate, only a same-line claim it's actually committed is the lie. A trailing negation-word filter
# (NEGATION_RE) is a cheap courtesy for the common "is not committed" / "isn't committed" phrasing — it is
# NOT exhaustive NL negation detection (that's out of scope for a bash heuristic; the chase never ends). This
# check is a best-effort belt-and-braces layer, not the only safeguard: the excluded-file list above is ALWAYS
# printed regardless of this check's verdict, so a human still sees every drop even on a miss, and a false
# BLOCK here has no --skip-ignored escape (fail-closed is the safe direction to err in): called from
# check_ignored_files BEFORE its --skip-ignored bypass, since an intentional R2 exclusion is fine but a doc
# that still claims the file landed is not, and that flag must never wave a committed-claim through. The real
# escape on a false positive is per the die message below — fix the ignore rule or reword the offending prose
# line, then retry.
check_excluded_claim() {
  local claim_file bn hit f
  local -r COMMIT_WORDS='\bcommitted\b|\bcommit\b|in the registry|in this dir'
  local -r NEGATION_RE=' not |n'"'"'t '
  for claim_file in "$DIR/RESULTS.md" "$DIR/ARTIFACT_MANIFEST.md"; do
    [ -f "$claim_file" ] || continue
    for f in "$@"; do
      bn="$(basename "$f")"
      if hit="$(grep -niF -- "$bn" "$claim_file" 2>/dev/null | grep -iE -- "$COMMIT_WORDS" | grep -viE -- "$NEGATION_RE")"; then
        die "excluded file '$f' is not staged (an ignore rule matched) but $(basename "$claim_file") claims it is committed — fix the ignore rule or the prose before logging: $hit"
      fi
    done
  done
}
# check_ignored_files (#340): MUST be called AFTER `git add -- "$REL"` in the worktree. Lists any file under
# $REL that the BASE tree's .gitignore excluded from the just-staged set (`git ls-files --others --ignored
# --exclude-standard`, NOT `git status`, which collapses a wholly-ignored directory to a single `!! dir/`
# entry and so would only ever surface the directory's own basename — silently missing every filename inside
# it against check_excluded_claim's per-file prose check below). `ls-files` walks INTO an ignored directory
# and lists each file individually, NUL-delimited for the same path-safety reason secret_scan reads paths raw
# — see its comment; this also means an ignored SYMLINK is caught the same as a regular file, and a
# non-ASCII path is never git-quoted into a mismatch. A silent exclusion is fine for a genuine R2-scale
# artifact but not for a small pinned file sharing the ignored extension (the #340 incident) — BLOCK by
# default and print the list, unless the caller passed --skip-ignored to explicitly acknowledge the exclusion
# is intentional. #331's check_excluded_claim reuses this SAME excluded-file list (rather than re-deriving it
# with a second present-vs-staged diff) to catch the one thing --skip-ignored must never wave through: a doc
# claiming an excluded file is committed.
check_ignored_files() {
  local path; local -a hits=()
  while IFS= read -r -d '' path; do
    is_trivial_ignore "$path" && continue
    hits+=("$path")
  done < <(git -C "$WT" ls-files --others --ignored --exclude-standard -z -- "$REL")
  [ "${#hits[@]}" -eq 0 ] && return 0
  note "gitignored file(s) under $REL were NOT staged (excluded by a .gitignore rule):"
  printf '  %s\n' "${hits[@]}" >&2
  check_excluded_claim "${hits[@]}"
  if [ "$SKIP_IGNORED" = 1 ]; then
    note "--skip-ignored: proceeding anyway (acknowledged)"
    return 0
  fi
  die "$KIND has gitignored file(s) excluded from the staged commit (listed above) — if this is an intentional R2-scale exclusion, re-run with --skip-ignored; if any of these should have been committed (e.g. a small pinned instrument file sharing an ignored extension), fix the .gitignore or rename/relocate the file, then retry — NOTE: a per-branch 'git add -f' does NOT make a file survive this staging step (this worktree is fresh off origin/$BASE_BRANCH and stages with a plain 'git add'); see run-experiment's SKILL.md R2-vs-git guidance for the rename-to-a-non-ignored-extension fix (automated-researcher#553)"
}
stage_worktree() {
  git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$BRANCH" && die "local branch $BRANCH already exists (a prior run may have failed) — remove it and retry"
  git -C "$REPO_ROOT" rev-parse --verify --quiet "origin/$BASE_BRANCH^{commit}" >/dev/null 2>&1 \
    || die "no origin/$BASE_BRANCH ref to base the log on — fetch origin (or set LOG_EXPERIMENT_BASE_BRANCH)"
  WT="$(mktemp -d)/wt"
  git -C "$REPO_ROOT" worktree add -q -b "$BRANCH" "$WT" "origin/$BASE_BRANCH" || die "could not create worktree/branch $BRANCH off origin/$BASE_BRANCH"
  CREATED_BRANCH=1
  mkdir -p "$WT/$(dirname "$REL")"
  cp -r "$DIR" "$WT/$(dirname "$REL")/"
  git -C "$WT" add -- "$REL"                          # respects the BASE tree's .gitignore (large artifacts stay on R2)
  check_ignored_files                                 # #340: BLOCK on a non-trivial file the .gitignore silently dropped
  # `if` (not `… && die`): as the last statement of this function, a bare `diff --quiet` returning 1 (the
  # normal has-a-diff case) would make the function return 1 and trip `set -e` in the caller.
  if git -C "$WT" diff --cached --quiet; then die "nothing to commit for $REL (unchanged vs origin/$BASE_BRANCH, or all gitignored?)"; fi
}

if [ "$DRY_RUN" = 1 ]; then
  # Stage off the LOCAL origin/$BASE_BRANCH (no fetch, no tokens) and run the SAME staged secret + symlink
  # scans a real run would — so --dry-run validates the ACTUAL gate, not an approximation. Worktree is
  # trap-cleaned on exit.
  stage_worktree
  symlink_scan
  scan_if_needed
  note "--dry-run: classified=$KIND, gate PASSED (staged secret/symlink scan clean); stopping before any push."
  exit 0
fi

# ---- resolve identities + mint the cross-family reviewer token up front (fail before mutating remote) ----
[ -n "$RESEARCH_REPO" ] || die "RESEARCH_REPO is required (instance config; no default target)"
case "$AUTHOR_FAMILY" in
  claude) REVIEWER_FAMILY=CODEX  ;;
  codex)  REVIEWER_FAMILY=CLAUDE ;;
  *) die "LOG_EXPERIMENT_AUTHOR_FAMILY (or AAR_SUBSTRATE) must be claude|codex (got '$AUTHOR_FAMILY') — fail closed to keep the review cross-family" ;;
esac
# F2: the input dir's repo must BE the research repo — never push/leak the record to the wrong origin.
origin_url="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
# Require a github.com remote, then EXACT owner/repo. Never print the raw URL (it may carry a token).
case "$origin_url" in
  https://github.com/*|git@github.com:*|ssh://git@github.com/*) : ;;
  *) die "input dir's origin is not a github.com remote — refusing to push" ;;
esac
origin_slug="$(printf '%s' "$origin_url" | sed -E 's#^.*github\.com[/:]##; s#\.git$##; s#/$##')"
[ "$origin_slug" = "$RESEARCH_REPO" ] || die "input dir's origin ($origin_slug) is not RESEARCH_REPO ($RESEARCH_REPO)"
# Two engineer-bot tokens, both EXPLICIT family-keyed instance config (commands taking <owner/repo>):
#   AUTHOR family -> the bot that pushes / creates / merges; REVIEWER = OPPOSITE family -> the bot that
#   approves (cross-family independence; the author bot cannot approve its own PR). Fail closed if unset.
mint_var="LOG_EXPERIMENT_TOKEN_CMD_${REVIEWER_FAMILY}"
REVIEWER_MINT="${LOG_EXPERIMENT_REVIEWER_TOKEN_CMD:-${!mint_var:-}}"
[ -n "$REVIEWER_MINT" ] || die "no reviewer token command — set $mint_var (or LOG_EXPERIMENT_REVIEWER_TOKEN_CMD), a command taking <owner/repo> minting a ${REVIEWER_FAMILY,,}-engineer token"
TOK="$($REVIEWER_MINT "$RESEARCH_REPO" 2>/dev/null || true)"
[ -n "$TOK" ] || die "could not mint ${REVIEWER_FAMILY,,}-engineer reviewer token for $RESEARCH_REPO"
# Validate repo access BEFORE any mutation (a token that can't reach the repo would strand a half-open PR).
GH_TOKEN="$TOK" gh api "repos/$RESEARCH_REPO" -q .full_name >/dev/null 2>&1 \
  || die "reviewer token cannot access $RESEARCH_REPO (is the ${REVIEWER_FAMILY,,}-engineer App installed there?)"
# #560 defense-in-depth: best-effort, read-only heads-up if $RESEARCH_REPO's own "Automatically delete head
# branches" setting is off — that setting fixes the stale-reused-branch push failure (below) at the source,
# but it's a DIFFERENT repo's setting than this one, so this script can only surface the recommendation, not
# flip it. Never fails the run on this (informational only).
# NOTE: no `// empty` here — jq's alternative operator treats `false` the same as `null` (both falsy), so
# `.delete_branch_on_merge // empty` printed nothing (not "false") whenever the setting was actually off,
# and the check below never matched. `.delete_branch_on_merge` alone prints the literal false/true/null.
_delete_on_merge="$(GH_TOKEN="$TOK" gh api "repos/$RESEARCH_REPO" -q '.delete_branch_on_merge' 2>/dev/null || true)"
[ "$_delete_on_merge" = "false" ] && note "heads-up: $RESEARCH_REPO has 'Automatically delete head branches' OFF (repo Settings > General > Pull Requests) — turning it on fixes stale-reused-branch push failures (#560) at the source; the push-time recovery below covers it either way"
# Author-family token (the bot that pushes / creates / merges) + its commit identity. Fail closed.
amint_var="LOG_EXPERIMENT_TOKEN_CMD_${AUTHOR_FAMILY^^}"
AUTHOR_MINT="${!amint_var:-}"
[ -n "$AUTHOR_MINT" ] || die "no author token command — set $amint_var, a command taking <owner/repo> minting a ${AUTHOR_FAMILY}-engineer token"
ATOK="$($AUTHOR_MINT "$RESEARCH_REPO" 2>/dev/null || true)"
[ -n "$ATOK" ] || die "could not mint ${AUTHOR_FAMILY}-engineer author token for $RESEARCH_REPO"
GH_TOKEN="$ATOK" gh api "repos/$RESEARCH_REPO" -q .full_name >/dev/null 2>&1 \
  || die "author token cannot access $RESEARCH_REPO (is the ${AUTHOR_FAMILY}-engineer App installed there?)"
gitauthor_var="LOG_EXPERIMENT_GIT_AUTHOR_${AUTHOR_FAMILY^^}"
GIT_AUTHOR="${!gitauthor_var:-}"
[ -n "$GIT_AUTHOR" ] || die "no author git identity — set $gitauthor_var to the ${AUTHOR_FAMILY}-engineer 'Name <email>'"
[[ "$GIT_AUTHOR" =~ ^.+\ \<[^@[:space:]]+@[^@[:space:]]+\>$ ]] || die "$gitauthor_var is malformed (expected 'Name <email>'): $GIT_AUTHOR"
GA_NAME="${GIT_AUTHOR% <*}"; GA_EMAIL="${GIT_AUTHOR#*<}"; GA_EMAIL="${GA_EMAIL%>}"

# ---- stage in the DEDICATED worktree off the FRESH base, then scan the EXACT staged set for symlinks + secrets ----
# (never disturbs the shared tree). Fetch first so the PR is based on latest origin/$BASE_BRANCH AND the scans
# run against that same fetched base (the scanned set can't diverge from the committed set).
cd "$REPO_ROOT"
git fetch origin --quiet
stage_worktree
symlink_scan
scan_if_needed
# Force the bot identity via env (overrides any ambient GIT_AUTHOR_*/GIT_COMMITTER_* + config) for author AND committer.
GIT_AUTHOR_NAME="$GA_NAME" GIT_AUTHOR_EMAIL="$GA_EMAIL" \
GIT_COMMITTER_NAME="$GA_NAME" GIT_COMMITTER_EMAIL="$GA_EMAIL" \
  git -C "$WT" commit -q -m "Log $KIND: $REL"
# Push as the AUTHOR bot via a token-scoped remote, with credential helpers DISABLED so no ambient
# credential machinery can participate (matches the hardened push convention). URL not persisted as a remote.
# #560: a plain non-force push can be rejected non-fast-forward when a PRIOR run reused this same
# deterministic branch name ($BRANCH = log/$SLUG, built above) and its merge left the remote head undeleted
# (the merge step below already passes --delete-branch, so this means that deletion was skipped/failed on an
# earlier run, or predates the flag — not routine). Recover exactly ONCE, and only when confirmed safe: the
# stale branch's own PR (looked up by head=$BRANCH) must be MERGED **and** its recorded head SHA must match
# the branch's CURRENT remote SHA. The SHA check matters because branch names are reused across separate
# eras, not just once: `gh pr list --state merged --head=$BRANCH` matches on NAME alone, so it can surface an
# old, unrelated merged PR while a concurrent run (or a newer, still-open PR) currently owns this exact
# branch name with different, un-merged content — without the SHA check that live branch would be deleted
# out from under it. Never merge-base/ancestry (unsound for a squash-merged branch — the head SHA is never
# an ancestor of base) and never a force-push. Any other push failure (auth, network, a genuinely conflicting
# live branch) dies immediately with no recovery attempt.
push_to_branch() {
  local out rc=0
  out="$(git -C "$WT" -c credential.helper= push -q "https://x-access-token:${ATOK}@github.com/${RESEARCH_REPO}.git" "HEAD:refs/heads/$BRANCH" 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] && return 0
  PUSH_ERR="${out//$ATOK/***}"   # redact the embedded token before this is ever printed
  return "$rc"
}
if ! push_to_branch; then
  case "$PUSH_ERR" in
    *"[rejected]"*|*"non-fast-forward"*|*"stale info"*) : ;;
    *) die "push to $BRANCH failed: $PUSH_ERR" ;;
  esac
  note "push to $BRANCH rejected (stale remote branch from a prior run?) — checking whether a PR with head=$BRANCH is MERGED before recovering"
  STALE_PR="$(GH_TOKEN="$TOK" gh pr list -R "$RESEARCH_REPO" --state merged --head "$BRANCH" --json number -q '.[0].number // empty' 2>/dev/null || true)"
  [ -n "$STALE_PR" ] || die "push to $BRANCH rejected (stale remote branch) and no MERGED PR found with head=$BRANCH — refusing to delete an unconfirmed branch; manual recovery: check the branch's PR state on $RESEARCH_REPO, and if it's really a stale merged leak, 'git push origin --delete $BRANCH' then retry ($PUSH_ERR)"
  STALE_PR_SHA="$(GH_TOKEN="$TOK" gh pr view "$STALE_PR" -R "$RESEARCH_REPO" --json headRefOid -q '.headRefOid // empty' 2>/dev/null || true)"
  REMOTE_SHA="$(GH_TOKEN="$TOK" gh api "repos/$RESEARCH_REPO/git/ref/heads/$BRANCH" -q '.object.sha // empty' 2>/dev/null || true)"
  [ -n "$STALE_PR_SHA" ] && [ -n "$REMOTE_SHA" ] \
    || die "push to $BRANCH rejected and PR #$STALE_PR (head=$BRANCH) is MERGED, but could not resolve both its head SHA and the branch's current remote SHA to cross-check them — refusing to delete an unconfirmed branch; manual recovery: check the branch's current PR/commits on $RESEARCH_REPO, and if it's really a stale merged leak, 'git push origin --delete $BRANCH' then retry ($PUSH_ERR)"
  [ "$STALE_PR_SHA" = "$REMOTE_SHA" ] \
    || die "push to $BRANCH rejected; PR #$STALE_PR (head=$BRANCH) is MERGED, but its head SHA ($STALE_PR_SHA) does not match the branch's CURRENT remote SHA ($REMOTE_SHA) — the branch name has been reused since that merge (e.g. a concurrent run or a newer un-merged PR owns it now) and deleting it would destroy live work; manual recovery: check the branch's current PR/commits on $RESEARCH_REPO before deciding ($PUSH_ERR)"
  note "PR #$STALE_PR (head=$BRANCH) is MERGED and its head SHA matches the branch's current remote SHA — deleting the stale remote branch and retrying the push once"
  git -C "$WT" -c credential.helper= push -q "https://x-access-token:${ATOK}@github.com/${RESEARCH_REPO}.git" --delete "$BRANCH" \
    || die "could not delete stale remote branch $BRANCH (confirmed MERGED via PR #$STALE_PR, SHA-verified) — manual recovery needed"
  push_to_branch || die "push to $BRANCH still failed after deleting its stale merged branch (PR #$STALE_PR): $PUSH_ERR"
fi
HEAD_SHA="$(git -C "$WT" rev-parse HEAD)"   # bind the merge to exactly the reviewed commit

# ---- post the already-run audit onto the PR as a browsable thread (additive, best-effort — NOT a re-run) ----
# A PR review/comment body caps ~65k chars; truncate large bodies (the full file is committed in the PR diff).
_clip(){ local b; [ -f "$1" ] || return 1; b="$(cat "$1")"; [ -n "$b" ] || return 1; if [ "${#b}" -gt 60000 ]; then b="${b:0:60000}"$'\n\n…truncated; full file in the PR diff.'; fi; printf '%s' "$b"; }
# post a single findings body (as the reviewer) or triage body (as the author); label is display text, file the source.
_post_findings(){ local label=$1 file=$2 body; body="$(_clip "$file")" || return 0
  GH_TOKEN="$TOK" gh pr review "$PR" -R "$RESEARCH_REPO" --comment --body "**${label}**"$'\n\n'"$body" >/dev/null 2>&1 \
    || note "warn: could not post audit findings ($label) to PR #$PR (gate/merge unaffected)"; }
_post_triage(){ local label=$1 file=$2 body; body="$(_clip "$file")" || return 0
  GH_TOKEN="$ATOK" gh pr comment "$PR" -R "$RESEARCH_REPO" --body "**${label}**"$'\n\n'"$body" >/dev/null 2>&1 \
    || note "warn: could not post author triage ($label) to PR #$PR (gate/merge unaffected)"; }
post_audit_thread(){
  local f ln ftmp rtmp
  local _tmps=()
  case "$KIND" in
    experiment)
      [ -f "$DIR/AUDIT.md" ] || return 0
      if [ -f "$DIR/AUDIT_RESPONSE.md" ]; then
        # Separate-file form: whole AUDIT.md is reviewer findings; AUDIT_RESPONSE.md is author triage.
        _post_findings "Cross-family experiment audit — \`AUDIT.md\` (posted by the ${REVIEWER_FAMILY,,}-engineer reviewer):" "$DIR/AUDIT.md"
        _post_triage   "Author triage — \`AUDIT_RESPONSE.md\` (posted by the ${AUTHOR_FAMILY}-engineer author):"        "$DIR/AUDIT_RESPONSE.md"
      elif ln="$(inline_response_line "$DIR/AUDIT.md")" && [ -n "$ln" ]; then
        # Inline form (#263): SPLIT at the response heading so author triage is posted AS author triage, NOT
        # inside the reviewer's findings body (preserves the findings -> author-responses trail — F4).
        ftmp="$(mktemp)"; rtmp="$(mktemp)"; _tmps=("$ftmp" "$rtmp")
        head -n "$((ln - 1))" "$DIR/AUDIT.md" > "$ftmp"    # findings: everything above the response heading
        tail -n "+$ln"        "$DIR/AUDIT.md" > "$rtmp"    # triage: the response section onward
        _post_findings "Cross-family experiment audit — \`AUDIT.md\` findings (posted by the ${REVIEWER_FAMILY,,}-engineer reviewer):" "$ftmp"
        _post_triage   "Author triage — inline response section of \`AUDIT.md\` (posted by the ${AUTHOR_FAMILY}-engineer author):"     "$rtmp"
      else
        # No triage section found (the gate would have blocked) — post the whole file as findings, best-effort.
        _post_findings "Cross-family experiment audit — \`AUDIT.md\` (posted by the ${REVIEWER_FAMILY,,}-engineer reviewer):" "$DIR/AUDIT.md"
      fi ;;
    design-stage)
      for f in "$DIR"/DESIGN_AUDIT*.md; do
        [ -f "$f" ] || continue
        if [[ "$(basename "$f")" =~ ^DESIGN_AUDIT[0-9]*\.md$ ]]; then
          _post_findings "Cross-family design-stage audit — \`$(basename "$f")\` (posted by the ${REVIEWER_FAMILY,,}-engineer reviewer):" "$f"
        fi
      done
      [ -f "$DIR/DESIGN_AUDIT_RESPONSE.md" ] && _post_triage "Author triage — \`DESIGN_AUDIT_RESPONSE.md\` (posted by the ${AUTHOR_FAMILY}-engineer author):" "$DIR/DESIGN_AUDIT_RESPONSE.md" ;;
    *) return 0 ;;   # notes get no audit thread
  esac
  [ ${#_tmps[@]} -gt 0 ] && rm -f "${_tmps[@]}"
  return 0
}

# ---- PR -> bot approve -> merge ----
BODY="$(printf '%s\n\nLogged by log-experiment.sh (gate: %s).' "$APPROVAL_BODY" "$KIND")"
URL="$(GH_TOKEN="$ATOK" gh pr create -R "$RESEARCH_REPO" --head "$BRANCH" --base "$BASE_BRANCH" \
        -t "Log $KIND: $REL" -b "$BODY")"
PR="$(echo "$URL" | grep -oE '[0-9]+$')"
note "opened PR #$PR ($URL)"
post_audit_thread   # surface the already-run audit as a findings -> responses thread (experiment/design-stage only)
GH_TOKEN="$TOK" gh pr review "$PR" -R "$RESEARCH_REPO" --approve --body "$APPROVAL_BODY" >/dev/null
GH_TOKEN="$ATOK" gh pr merge "$PR" -R "$RESEARCH_REPO" --squash --delete-branch --match-head-commit "$HEAD_SHA" >/dev/null
note "merged PR #$PR (head $HEAD_SHA)"

# ---- sync local base branch (ff-only, ONLY if this checkout is on it; never touches other uncommitted work) ----
git fetch origin --quiet
if [ "$(git rev-parse --abbrev-ref HEAD)" = "$BASE_BRANCH" ]; then
  git merge --ff-only "origin/$BASE_BRANCH" >/dev/null 2>&1 || note "local $BASE_BRANCH not fast-forwardable; left as-is"
else
  note "checkout is on $(git rev-parse --abbrev-ref HEAD), not $BASE_BRANCH; skipping local sync"
fi
echo "OK: logged $KIND '$REL' as PR #$PR (merged)."   # the EXIT trap removes the temp worktree + its local branch
