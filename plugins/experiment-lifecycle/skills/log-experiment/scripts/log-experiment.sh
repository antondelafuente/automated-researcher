#!/usr/bin/env bash
# log-experiment.sh <registry-dir> [--dry-run] [--skip-ignored] [--only <path>]...
#                   [--page-source <dir> [--page-source-only <path>]... | --page-source-external <url>]
#
#   --page-source <dir> stages a SECOND tree — the experiment's viewer/dashboard page source — into the SAME
#   commit and the SAME gated PR as the record (#819). A close is one event: the record, the page source and
#   LANDED.md were three sequential gated PRs at the end of every run (~10 min of a measured 51-min median
#   close leg) that landed the same close, gated the same way. The dir must live in this same repo and must
#   be note-shaped (no DESIGN.md/RESULTS.md of its own): it is page SOURCE riding the record's gate, never a
#   second record with its own evidence to verify. --page-source-only narrows it exactly like --only narrows
#   the record dir — the dashboard tree is typically multi-tenant, so a co-tenant's untracked files must not
#   sweep in (#374).
#   --page-source-external <url> is for a viewer that lives in a DIFFERENT repo, which no single PR can
#   reach: it records where the page source landed instead of staging it, so the gate below has an answer
#   rather than blocking a close it cannot help.
#   --skip-ignored proceeds WITHOUT the flagged gitignored files (acknowledge-and-exclude) — it never
#   force-includes them into the commit.
#   --only <path> (repeatable) restricts the staged set to exactly the named path(s), each given relative to
#   <registry-dir>. Use this when <registry-dir> is a SHARED, multi-tenant tree (e.g. a viewer dashboard dir
#   several sessions write into) so a co-tenant session's untracked files never sweep into YOUR PR (#374) —
#   without --only, staging is dir-scoped (the whole tree). Applied at staging time (stage_worktree), so
#   every existing staged-set gate (check_ignored_files/symlink_scan/secret_scan) automatically runs against
#   this reduced set — none of them need their own --only awareness. Fail-closed: a named path that does not
#   exist under <registry-dir>, or an allowlist that ends up staging nothing, dies — it never silently falls
#   back to staging the whole dir. A named path is never symlink-resolved (#586 review): the allowlist stages
#   exactly the path you name, even if it is itself a symlink — a staged symlink then wholesale-BLOCKs via
#   symlink_scan same as any other, rather than silently substituting a co-tenant's file at the symlink's
#   target. Restricted to a dir that classifies as KIND=note (the dashboard use case always does): the
#   experiment/design-stage gates read their audit/design evidence straight from <registry-dir>, not the
#   allowlisted staged set, so --only on those KINDs is refused rather than risk approving evidence that
#   never actually gets committed.
#
# Log a research-repo registry directory to GitHub as a GATED pull request and merge it.
# The gate is chosen by the directory's own content (auditability via the registry convention):
#   - experiment   (DESIGN.md + RESULTS.md):   verify the close-audit is present and clean.
#   - design-stage (DESIGN.md, no RESULTS.md): verify the design-audit (DESIGN_AUDIT*.md) is present, the
#                                               Presentation section carries the researcher's lock line, any
#                                               staged CHECKLIST.md is UNSTARTED (#512), + secret scan.
#   - note         (anything else):            deterministic secret scan only.
# Every kind, additionally, gets a deterministic symlink check: a registry record has no legitimate use for a
# staged symlink (the intent is always to copy a reference file's real bytes), so ANY staged symlink is a
# BLOCK regardless of KIND — a committed symlink's target is only ever meaningful on the machine, or worse the
# specific session, that created it. Every kind also gets a TEMP.md check (#332): run-experiment's transient
# successor-handoff scratch is never part of the record convention, so a staged TEMP.md is a BLOCK regardless
# of KIND — belt-and-braces behind run-experiment's own close-checklist deletion step.
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
# Staging copy (#666): the worktree is populated with ONLY the files that could actually be committed — the
# --only allowlist and the ignore rules are both applied BEFORE any bytes move, so a gitignored multi-GB tree
# that can never be committed is never copied into /tmp (it used to be, and a landing died with ENOSPC
# whenever free disk was smaller than the whole input dir). The rules applied are the base tree's PLUS the
# input dir's own `.gitignore` files, which the copy materializes first precisely so the pre-copy verdict and
# the later `git add` can never disagree (#670 review). See copy_stage_paths.
#
# Sparse staging worktree (#805): the /tmp worktree itself is created SPARSE via scripts/sparse_worktree.sh —
# every top-level dir except `registry/`, plus $REL. #666 stopped the INPUT dir from being copied in wholesale;
# this stops the BASE tree from being checked out wholesale (a full checkout of a 5.3G/301-record registry, on
# every log run, to commit one record dir). See stage_worktree.
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
# The sparse-worktree helper (#805) — a byte-identical copy of run-experiment/scripts/sparse_worktree.sh,
# which owns the worktree lifecycle scripts (reap_worktree.sh is its teardown counterpart). stage_worktree
# below is this script's only worktree-creation site.
SPARSE_WORKTREE_HELPER="$SELF_DIR/sparse_worktree.sh"

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
DRY_RUN=0; SKIP_IGNORED=0; DIR=""; PS_DIR=""; PS_EXTERNAL=""
declare -a ONLY_PATHS=() PS_ONLY_PATHS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --skip-ignored) SKIP_IGNORED=1; shift ;;
    --only)
      [ "$#" -ge 2 ] || die "--only requires a <path> argument"
      ONLY_PATHS+=("$2")
      shift 2 ;;
    --page-source)
      [ "$#" -ge 2 ] || die "--page-source requires a <dir> argument"
      [ -z "$PS_DIR" ] || die "--page-source given twice ('$PS_DIR' then '$2') — one page-source tree per landing; if the page spans two trees, put them under one parent dir and name that"
      PS_DIR="$2"; shift 2 ;;
    --page-source-only)
      [ "$#" -ge 2 ] || die "--page-source-only requires a <path> argument"
      PS_ONLY_PATHS+=("$2")
      shift 2 ;;
    --page-source-external)
      [ "$#" -ge 2 ] || die "--page-source-external requires a <url> argument"
      PS_EXTERNAL="$2"; shift 2 ;;
    -*) die "unknown flag: $1" ;;
    *) DIR="$1"; shift ;;
  esac
done
[ -n "$DIR" ] || die "usage: log-experiment.sh <registry-dir> [--dry-run] [--skip-ignored] [--only <path>]... [--page-source <dir> [--page-source-only <path>]... | --page-source-external <url>]"
[ -n "$PS_DIR" ] && [ -n "$PS_EXTERNAL" ] && die "--page-source and --page-source-external are mutually exclusive — the page source either rides this PR or it landed elsewhere, not both"
[ "${#PS_ONLY_PATHS[@]}" -eq 0 ] || [ -n "$PS_DIR" ] || die "--page-source-only needs --page-source (it narrows that dir, exactly as --only narrows the record dir)"
[ -d "$DIR" ] || die "not a directory: $DIR"
DIR="$(cd "$DIR" && pwd)"   # absolute — stable across the later cd into the repo root

REPO_ROOT="$(cd "$DIR" && git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repo: $DIR"
REL="$(cd "$REPO_ROOT" && realpath --relative-to="$REPO_ROOT" "$DIR")"
[ "${REL#..}" = "$REL" ] || die "dir is outside the repo root"
SLUG="$(basename "$REL" | tr -c 'A-Za-z0-9._-' '-' | sed 's/-*$//')"

# assert_physical_parent <abs-root> <rel> <flag> (#820 round 3): the lexical checks cannot see a symlinked
# INTERMEDIATE component — the kernel resolves it in find's starting path and cp --parents materializes the
# result as a REGULAR file under REAL directories, so symlink_scan sees nothing and out-of-tree bytes land
# as ordinary staged content. Resolve the named path's PARENT physically and require it inside the
# physically-resolved root. The FINAL component is deliberately never resolved (#586): a symlink you name
# still stages verbatim and symlink_scan wholesale-BLOCKs it. Resolving the root too keeps a symlinked
# prefix ABOVE the root (e.g. a symlinked /home) working. Call as a plain statement, never via $( ).
assert_physical_parent() {
  local root="$1" rel="$2" flag="$3" phys_root phys_parent
  phys_root="$(realpath -e -- "$root" 2>/dev/null)" || die "internal: cannot physically resolve $root"
  phys_parent="$(realpath -e -- "$root/$(dirname -- "$rel")" 2>/dev/null)" \
    || die "$flag path's parent directory could not be resolved: $rel"
  [ "$phys_parent" = "$phys_root" ] || [ "${phys_parent#"$phys_root"/}" != "$phys_parent" ] \
    || die "$flag path reaches through a symlinked parent that leaves the tree ($rel resolves under $phys_parent) — name the real path instead"
}

# ---- --only allowlist (#374): resolve + validate each named path against $DIR, then build STAGE_PATHS —
# the exact set later staged (stage_worktree) and gitignore-checked (check_ignored_files) against. Doing
# this once, up front, means both of those (and, transitively, symlink_scan/secret_scan, which scan
# whatever ends up staged) automatically operate on the reduced set with no --only-awareness of their own.
# Validated INLINE, not via a helper called through command substitution: `die` calls `exit`, and `exit`
# inside a function invoked as `$(fn ...)` only terminates that subshell, not the script — a die swallowed
# that way would silently fall through to an empty ONLY_REL entry instead of failing closed.
declare -a ONLY_REL=() STAGE_PATHS=()
for _op in "${ONLY_PATHS[@]}"; do
  case "$_op" in
    /*) die "--only path must be relative to the registry dir, not absolute: $_op" ;;
  esac
  [ -e "$DIR/$_op" ] || die "--only path does not exist under $DIR: $_op"
  # realpath resolution runs INSIDE the `cd`'d subshell (no die there — see comment above); only its exit
  # status, checked here outside the subshell, decides pass/fail. `-s`/`--no-symlinks` is DELIBERATE (#586
  # review): plain `realpath --relative-to` resolves symlinks to their CANONICAL target, so `--only mine.py`
  # where `mine.py` is a symlink to a co-tenant's `cotenant.py` would silently rewrite the allowlist entry to
  # `cotenant.py` — staging and scanning the co-tenant's file under a name the caller never asked for, exactly
  # the sweep-in this flag exists to prevent. `-s` still lexically normalizes `.`/`..`/repeated `/` (so the
  # containment check below is unaffected) but leaves the named path's OWN symlink-ness alone. Only the FINAL
  # component stages verbatim that way (#820 round 3 corrects the original claim that a path component does
  # too): if `_op` itself is a symlink it stages as a symlink and symlink_scan (which runs on every KIND right
  # after stage_worktree) wholesale-BLOCKs it — but an INTERMEDIATE component is kernel-resolved during
  # staging and materialized as an ordinary file, which symlink_scan cannot see. assert_physical_parent below
  # is what closes that half.
  _rel="$(cd "$DIR" && realpath -s --relative-to=. "$_op" 2>/dev/null)" || die "--only path could not be resolved under $DIR: $_op"
  [ "${_rel#..}" = "$_rel" ] || die "--only path escapes the registry dir: $_op"
  assert_physical_parent "$DIR" "$_rel" "--only"
  ONLY_REL+=("$_rel")
done
if [ "${#ONLY_REL[@]}" -gt 0 ]; then
  for _r in "${ONLY_REL[@]}"; do STAGE_PATHS+=("$REL/$_r"); done
  note "--only: staging restricted to ${#ONLY_REL[@]} path(s) under $REL: ${ONLY_REL[*]}"
else
  STAGE_PATHS=("$REL")
fi
# STAGE_ROOTS: the dir each staged path belongs to, index-parallel to STAGE_PATHS. Everything that is
# per-ROOT rather than per-PATH reads this — the ancestor .gitignore walk (copy_stage_paths), the sparse
# cone, and the TEMP.md scan — so adding a second root (--page-source, below) needs no second copy of any
# of them. Without --page-source there is exactly one root and the behavior is bit-for-bit what it was.
declare -a STAGE_ROOTS=() ROOT_RELS=("$REL")
for _r in "${STAGE_PATHS[@]}"; do STAGE_ROOTS+=("$REL"); done

# path_contains <ancestor> <descendant> — true when <ancestor> IS <descendant> or an ancestor directory of
# it, over repo-relative paths in the shape `realpath --relative-to` emits. The repo root normalizes to the
# sentinel `.`, and plain prefix arithmetic reads that sentinel exactly backwards: `.` is an ancestor of
# EVERY path in the repo, yet "$anc/" is "./" and no other relative path starts with "./", so the containment
# test says "disjoint" for the one root that contains everything (#820 review round 2: `--page-source
# <repo-root>` against a `registry/<exp>` record therefore passed the guard below and would have routed the
# whole repository through page-source staging). The sentinel is handled here, in the predicate itself,
# rather than at one call site: both directions and the equality case are the same question, and patching
# only the direction that was found would leave the other reachable the moment the roots swap.
path_contains() {
  local anc="$1" desc="$2"
  if [ "$anc" = "." ] || [ "$anc" = "$desc" ]; then return 0; fi
  [ "${desc#"$anc"/}" != "$desc" ]
}

# ---- --page-source (#819): a SECOND staging root landing in the SAME commit/PR as the record ----
PS_REL=""
if [ -n "$PS_DIR" ]; then
  [ -d "$PS_DIR" ] || die "--page-source is not a directory: $PS_DIR"
  PS_DIR="$(cd "$PS_DIR" && pwd)"
  _ps_root="$(cd "$PS_DIR" && git rev-parse --show-toplevel 2>/dev/null)" || die "--page-source dir is not inside a git repo: $PS_DIR"
  [ "$_ps_root" = "$REPO_ROOT" ] \
    || die "--page-source dir lives in a DIFFERENT repo ($_ps_root) than the record ($REPO_ROOT) — one PR cannot land both; land the page source in its own repo and pass --page-source-external <url> instead"
  PS_REL="$(cd "$REPO_ROOT" && realpath -s --relative-to="$REPO_ROOT" "$PS_DIR")"
  [ "${PS_REL#..}" = "$PS_REL" ] || die "--page-source dir is outside the repo root"
  # Disjoint from the record dir in BOTH directions: a page-source root at/inside/containing $REL would put
  # the same paths under two roots (double-staged, and the record's own gate silently governing page files,
  # or worse the page root's rules governing the record).
  if path_contains "$REL" "$PS_REL" || path_contains "$PS_REL" "$REL"; then
    die "--page-source dir ($PS_REL) overlaps the record dir ($REL) — the page source is a separate tree riding the same PR, not part of the record dir (which is staged whole already)"
  fi
  # Note-shaped only: this tree rides the RECORD's gate, so it must carry no evidence of its own to verify.
  # A dir with its own DESIGN.md/RESULTS.md is a record and gets its own gated landing (same reasoning that
  # restricts --only to KIND=note: a gate must never approve evidence it did not read).
  { [ -f "$PS_DIR/DESIGN.md" ] || [ -f "$PS_DIR/RESULTS.md" ] || [ -f "$PS_DIR/KIND" ]; } \
    && die "--page-source dir ($PS_REL) carries DESIGN.md/RESULTS.md/KIND — that is a RECORD, not page source, and a record needs its own gate; log it separately"
  declare -a PS_ONLY_REL=()
  for _op in "${PS_ONLY_PATHS[@]}"; do
    case "$_op" in
      /*) die "--page-source-only path must be relative to the page-source dir, not absolute: $_op" ;;
    esac
    [ -e "$PS_DIR/$_op" ] || die "--page-source-only path does not exist under $PS_DIR: $_op"
    # `-s` (no symlink resolution) for exactly the #586 reason --only uses it: the allowlist must stage the
    # path you named, never a co-tenant's file it happens to point at (symlink_scan then BLOCKs it). That
    # holds for the FINAL component only (#820 round 3): an INTERMEDIATE symlinked component is kernel-resolved
    # at staging time and lands as an ordinary file symlink_scan never sees — assert_physical_parent closes it.
    _rel="$(cd "$PS_DIR" && realpath -s --relative-to=. "$_op" 2>/dev/null)" || die "--page-source-only path could not be resolved under $PS_DIR: $_op"
    [ "${_rel#..}" = "$_rel" ] || die "--page-source-only path escapes the page-source dir: $_op"
    assert_physical_parent "$PS_DIR" "$_rel" "--page-source-only"
    PS_ONLY_REL+=("$_rel")
  done
  if [ "${#PS_ONLY_REL[@]}" -gt 0 ]; then
    for _r in "${PS_ONLY_REL[@]}"; do STAGE_PATHS+=("$PS_REL/$_r"); STAGE_ROOTS+=("$PS_REL"); done
    note "--page-source: staging restricted to ${#PS_ONLY_REL[@]} path(s) under $PS_REL: ${PS_ONLY_REL[*]}"
  else
    STAGE_PATHS+=("$PS_REL"); STAGE_ROOTS+=("$PS_REL")
  fi
  ROOT_RELS+=("$PS_REL")
  note "--page-source: $PS_REL lands in the SAME PR as $REL (#819)"
fi

# ---- classify (registry convention; KIND file is an explicit override) ----
KIND=""
[ -f "$DIR/KIND" ] && KIND="$(tr -d '[:space:]' < "$DIR/KIND")"
if [ -z "$KIND" ]; then
  if   [ -f "$DIR/DESIGN.md" ] && [ -f "$DIR/RESULTS.md" ]; then KIND="experiment"     # results leg: close-audit gate
  elif [ -f "$DIR/DESIGN.md" ];                                then KIND="design-stage"  # design leg: design-audit gate
  else                                                              KIND="note"; fi       # everything else: secret scan
fi
note "classified: $KIND  ($REL)"

# --only is restricted to KIND=note (#374 review): gate_experiment/gate_design_stage validate close-audit /
# design-audit / Presentation-lock evidence by reading RESULTS.md/AUDIT.md/AUDIT_RESPONSE.md/DESIGN.md/
# DESIGN_AUDIT*.md/START.md straight from $DIR, NOT from STAGE_PATHS — so an --only allowlist that leaves
# those files out of the staged set would let the gate verify evidence that never actually lands in the
# commit/PR, while the approval body still claims it did. gate_note reads no evidentiary file at all (secret
# scan runs on the staged set only), so it's the only KIND where narrowing the staged set can't create that
# gap — and it's also the actual reported use case (a shared multi-tenant dashboard dir has no DESIGN.md/
# RESULTS.md, so it always classifies as 'note').
# A page source rides an EXPERIMENT close (that is the only kind with a publish leg, #347/#819). On any other
# kind it would stage an unrelated tree into a PR whose gate never looked at it.
if { [ -n "$PS_DIR" ] || [ -n "$PS_EXTERNAL" ]; } && [ "$KIND" != "experiment" ]; then
  die "--page-source/--page-source-external is only supported for KIND=experiment — this dir classified as '$KIND'; the publish leg belongs to an experiment's close"
fi
if [ "${#ONLY_REL[@]}" -gt 0 ] && [ "$KIND" != "note" ]; then
  die "--only is only supported for KIND=note — this dir classified as '$KIND', whose gate reads audit/design evidence directly from $DIR rather than the staged set, so an --only allowlist could approve/merge a record whose cited evidence was never actually committed; log the whole dir (drop --only), or split the allowlisted content into its own single-owner registry dir"
fi

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
    gate_page_source   # #819 — only on the audited path; see the no-go branch below
  else
    if grep -qiE '^[^A-Za-z0-9]*((decision|status|outcome|result)[^A-Za-z0-9]+)?(ANCHOR_FAILED|NO[ _-]?GO|GATE[ _]PASS=FALSE|GATE[ _]FAILED?|NULL RESULT|DIAGNOSTIC ONLY|STOPPED AT [A-Za-z0-9 _-]*GATE)' "$DIR/RESULTS.md"; then
      APPROVAL_BODY="Experiment record — eval-only/no-go run; no close-audit needed; RESULTS records a closed decision."
      # No publish leg on this path (#819): a run that stopped at an instrument/data/validity gate has no
      # headline page to build, so requiring page source here would block exactly the closes that are
      # supposed to land cheaply. The page-source gate applies to a normal, audited close.
      note "experiment gate ok: no close-audit, RESULTS records a closed decision (no page-source requirement on a no-go close)"
    else
      die "experiment has no AUDIT.md and RESULTS.md records no closed decision — surface for human"
    fi
  fi
}
gate_page_source() {
  # #819: page presence is a MECHANICAL property, so it is checked HERE rather than by making the
  # cross-family close audit see a built page. That ordering ("publish first, so the audit and the landed
  # record see the page") is what exposed the whole publish chain — upload, fresh-pull reproduction, page
  # build, gallery rebuild — to a redo after every audit finding that moved a number. The audit reads the
  # science; this gate reads the tree.
  #
  # The trigger is the FROZEN START.md instance-profile snapshot, not the live profile: the executor's
  # publish leg is defined by what the brief carries (`[recipes.viewer]` in the snapshot block
  # aar_profile_snapshot.sh wrote), and the design-stage gate already owns snapshot freshness. No snapshot,
  # or a snapshot with no viewer recipe, is a legitimate manifest-only close and requires nothing here.
  [ -f "$DIR/START.md" ] || { note "page-source gate: no START.md — nothing to require (manifest-only close)"; return 0; }
  if ! grep -qE '^\[recipes\.viewer\]' "$DIR/START.md"; then
    note "page-source gate: no [recipes.viewer] in the START.md snapshot — manifest-only close, page source not required"
    return 0
  fi
  if [ -n "$PS_DIR" ]; then
    APPROVAL_BODY="$APPROVAL_BODY Page source ($PS_REL) rides this same PR — one landing, not three (#819)."
    note "page-source gate ok: brief carries a [recipes.viewer] recipe and the page source is staged here ($PS_REL)"
  elif [ -n "$PS_EXTERNAL" ]; then
    APPROVAL_BODY="$APPROVAL_BODY Page source landed separately (viewer repo is not this repo): $PS_EXTERNAL (#819)."
    note "page-source gate ok: page source recorded as external ($PS_EXTERNAL)"
  else
    die "this experiment's START.md snapshot carries a [recipes.viewer] recipe, so the publish leg is part of its close (#347) — but no page source is being landed: pass --page-source <dir> to land it in THIS PR (the one-landing close, #819), or --page-source-external <url> if the viewer lives in a different repo and its source already landed there; a viewer-recipe close whose page source lands nowhere is the silent miss #347 exists to prevent"
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
  #
  # Optional pathspec arguments narrow the scan to part of the staged set. Used by the one-landing close
  # (#819): an experiment PR that also carries a --page-source tree must still scan THAT tree, because the
  # page source used to land as its own KIND=note PR and got exactly this scan there — riding the record's
  # gate must not silently drop it. The record half stays unscanned, exactly as before.
  [ -n "${WT:-}" ] && [ -d "$WT" ] || die "internal: secret_scan called before stage_worktree (no staged worktree)"
  local hits rc f pat; local -a files=()
  pat='(ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|(^|[^A-Za-z0-9_-])sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY)'
  # NUL-delimited (`-z`) so a path with a newline / quote / non-ASCII char is read RAW (not git-quoted) — else
  # such a staged file could be skipped by the scan while still being committed (a scan bypass). Keep only
  # existing regular files (a staged deletion names a path that is gone).
  while IFS= read -r -d '' f; do [ -n "$f" ] && [ -f "$WT/$f" ] && files+=("$WT/$f"); done < <(
    git -C "$WT" diff --cached -z --name-only -- "$@")
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
temp_handoff_scan() {
  # Reject a staged TEMP.md (#332): run-experiment's transient successor-handoff scratch (progress
  # timestamps, next-action notes) is never part of the record convention (DESIGN/RESULTS/AUDIT/manifests),
  # and it silently contradicts the final RESULTS.md at whatever checkpoint it was last refreshed if it
  # lands in the merged PR. Belt-and-braces backstop: run-experiment's own close checklist already deletes
  # it before landing (SKILL.md); this catches a close that skipped that step. Runs for EVERY kind, same as
  # symlink_scan, on the EXACT staged set in $WT (MUST be called AFTER stage_worktree).
  [ -n "${WT:-}" ] && [ -d "$WT" ] || die "internal: temp_handoff_scan called before stage_worktree (no staged worktree)"
  local hit root
  hit=""
  for root in "${ROOT_RELS[@]}"; do
    hit="$hit$(git -C "$WT" diff --cached --name-only -z -- "$root" | tr '\0' '\n' | grep -xF "$root/TEMP.md" || true)"
  done
  [ -z "$hit" ] || die "$KIND has a staged TEMP.md (run-experiment's transient successor-handoff scratch — never part of the record convention) — delete it and retry (run-experiment's close checklist deletes it before staging; automated-researcher#332)"
}
# Which kinds get a secret scan (note + design-stage; the experiment gate never scanned — preserved), plus
# the --page-source tree riding an experiment PR (#819), which carries the scan it had when it landed as its
# own note PR.
scan_if_needed() {
  case "$KIND" in
    note|design-stage) secret_scan ;;
    experiment) if [ -n "$PS_REL" ]; then secret_scan "$PS_REL"; fi ;;
  esac
}
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
  # Require an UNSTARTED checklist (#512): a design-stage PR shipped a `CHECKLIST.md` that was already fully
  # ticked — a verbatim copy of a closed sibling's COMPLETED close checklist, string-replaced but with stale
  # fields. A less attentive executor could treat pre-ticked [BLOCK] gates as already satisfied, silently
  # skipping the claim/data-audit/anchor gate. A design-stage record is a pre-registration: every gate must
  # still read ☐ (unstarted) — ticks are the EXECUTOR's, written at run-experiment close, never at design
  # time. Match ticked GATE LIST lines only (a line beginning `- ☑` / `- ☒`), never a bare occurrence of the
  # ☑/☒ characters: the CHECKLIST template's own instruction header uses those characters in PROSE examples
  # (e.g. "☑ PASS ev: <artifact path + numbers>"), and a correctly-seeded UNSTARTED gate line legitimately
  # carries non-empty `ev:` hint text (e.g. `ev: rclone lsf`) — a bare character grep or an ev-payload check
  # would fail-closed on every correctly seeded checklist. This gate adds no new file-presence requirement:
  # N.A. (skipped) when no CHECKLIST.md is staged at all.
  # An alternation `(☑|☒)`, NOT a bracket character class `[☑☒]`, on purpose: under a byte-oriented locale
  # (e.g. LC_ALL=C), grep -E's character class matches on the INDIVIDUAL BYTES of its members, and ☑/☒/☐'s
  # UTF-8 encodings share a byte prefix (e2 98 91 / e2 98 92 / e2 98 90) — so `[☑☒]` also matches an unstarted
  # ☐ line under that locale, false-positive-blocking every correctly seeded checklist. An alternation matches
  # each option as a whole multi-byte literal instead, so it stays correct regardless of locale.
  if [ -f "$DIR/CHECKLIST.md" ]; then
    _ticked="$(grep -nE '^[[:space:]]*-[[:space:]]*(☑|☒)' "$DIR/CHECKLIST.md" || true)"
    [ -z "$_ticked" ] || die "design-stage dir's CHECKLIST.md has ticked gate marker(s) — a design-stage record is a pre-registration with an UNSTARTED checklist (every gate ☐); a ticked ☑/☒ line is executed/completed-record content (e.g. copied from a closed sibling's registry record instead of the design-experiment template) leaking into this seed — reset every gate to ☐ before logging, then retry: $(printf '%s' "$_ticked" | head -n5)"
  fi
  APPROVAL_BODY="Design-stage record — design-audit present (DESIGN_AUDIT.md / DESIGN_AUDIT<N>.md), Presentation section locked with the researcher, instance-profile snapshot in START.md verified (#469), CHECKLIST.md unstarted (#512), and secret scan clean; pre-launch leg of the two-PR flow."
  note "design-stage gate ok: design-audit present + Presentation lock found + instance-profile snapshot verified + checklist unstarted (secret scan runs on the staged set)"
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
# before the first worktree creation on either path. SPARSE since #805 (see stage_worktree): the tree carries
# the base rule files + $REL, not the other 300 registry records.
WT=""; WT_PARENT=""; BRANCH="log/${SLUG}"; CREATED_BRANCH=0   # only delete the branch in cleanup if THIS run created it
# WT_PARENT — the mktemp dir holding the worktree AND copy_stage_paths' path lists (#666) — is rm -rf'd by
# NAME, so stage_worktree validates it is a real, non-empty path before assigning it: an empty value here
# would turn the line below into an `rm -rf /`.
cleanup() { [ -n "$WT" ] && git -C "$REPO_ROOT" worktree remove --force "$WT" >/dev/null 2>&1 || true
            [ -n "$WT_PARENT" ] && rm -rf "$WT_PARENT" >/dev/null 2>&1 || true
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
#
# #467: a basename+commit-claim match alone false-positives when the SAME basename legitimately exists TWICE
# under $REL by design — once committed outside work/, once as a gitignored working copy under work/ (the
# run-experiment R2-mirrored dual-copy layout, close-audit F1 fix). The manifest's claim is then plausibly
# about the STAGED committed copy, not this excluded one. Before dying, check whether a file with this same
# basename IS present in THIS run's own staged set (`git diff --cached` under $REL, already computed by the
# caller's stage_worktree) — if so, downgrade to a printed note instead of a die. Preserves the #331 fail-
# closed behavior EXACTLY when no staged counterpart shares the basename (the original scenario: a doc claims
# committed, the file is staged nowhere) — that path still has no --skip-ignored escape.
check_excluded_claim() {
  local claim_file bn hit f staged_path is_staged
  local -r COMMIT_WORDS='\bcommitted\b|\bcommit\b|in the registry|in this dir'
  local -r NEGATION_RE=' not |n'"'"'t '
  local -a staged_paths=()
  while IFS= read -r -d '' staged_path; do staged_paths+=("$staged_path"); done \
    < <(git -C "$WT" diff --cached -z --name-only -- "$REL")
  for claim_file in "$DIR/RESULTS.md" "$DIR/ARTIFACT_MANIFEST.md"; do
    [ -f "$claim_file" ] || continue
    for f in "$@"; do
      bn="$(basename "$f")"
      if hit="$(grep -niF -- "$bn" "$claim_file" 2>/dev/null | grep -iE -- "$COMMIT_WORDS" | grep -viE -- "$NEGATION_RE")"; then
        is_staged=0
        for staged_path in "${staged_paths[@]}"; do
          [ "$(basename "$staged_path")" = "$bn" ] && { is_staged=1; break; }
        done
        if [ "$is_staged" = 1 ]; then
          note "excluded file '$f' shares a basename with a file that IS staged under $REL — treating $(basename "$claim_file")'s commit-claim as referring to that staged counterpart, not this excluded copy: $hit"
        else
          die "excluded file '$f' is not staged (an ignore rule matched) but $(basename "$claim_file") claims it is committed — fix the ignore rule or the prose before logging: $hit"
        fi
      fi
    done
  done
}
# check_ignored_files (#340): MUST be called AFTER `git add -- "$REL"` in the worktree (check_excluded_claim
# below reads the staged set). Reports any file under STAGE_PATHS that the staging worktree's ignore rules
# excluded from the staged set — the list copy_stage_paths already computed, per-file (an ignored DIRECTORY is
# enumerated as each file inside it, never collapsed to the directory's own basename, which would silently
# miss every filename inside it against check_excluded_claim's per-file prose check below), covering an
# ignored SYMLINK the same as a regular file, and carrying raw byte paths so a non-ASCII path is never
# quoted into a mismatch. A silent exclusion is fine for a genuine R2-scale
# artifact but not for a small pinned file sharing the ignored extension (the #340 incident) — BLOCK by
# default and print the list, unless the caller passed --skip-ignored to explicitly acknowledge the exclusion
# is intentional. #331's check_excluded_claim reuses this SAME excluded-file list (rather than re-deriving it
# with a second present-vs-staged diff) to catch the one thing --skip-ignored must never wave through: a doc
# claiming an excluded file is committed.
check_ignored_files() {
  local path; local -a hits=()
  for path in "${IGNORED_UNDER_STAGE[@]}"; do
    is_trivial_ignore "$path" && continue
    hits+=("$path")
  done
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
# copy_stage_paths (#666): populate the fresh worktree with ONLY the files under STAGE_PATHS that the
# worktree's ignore rules do not exclude — i.e. exactly the set the `git add` below could stage — and record
# the excluded ones in IGNORED_UNDER_STAGE for check_ignored_files.
#
# This used to be a blanket `cp -r "$DIR" …`: the ENTIRE input dir was copied into the /tmp worktree BEFORE
# either --only or .gitignore was applied, so a gitignored multi-GB tree that can never be committed (the
# reported case: a 35G `dashboard/build/` sitting next to the three small source files --only named) was
# copied anyway and the landing died with ENOSPC whenever free disk was smaller than the input dir. The only
# workaround was moving that tree aside and back — a footgun when it also serves live traffic. Both filters
# now apply BEFORE any bytes move, so the staging copy costs what the commit costs, not what the dir weighs.
#
# THE INVARIANT THIS FUNCTION EXISTS TO HOLD (#670 review): the ignore-rule state that decides the copy must
# be the SAME state `git add` applies afterwards. Deciding earlier is only safe if nothing between the two
# changes the rules — and the copy itself does, because a `.gitignore` under $DIR is one of the files being
# copied. So the input's own rule files are materialized FIRST (phase 1), and only then is anything decided.
# Skipping that step made the two disagree in both directions, and the fixtures for both are cases 44-46:
#   * a rule the input ADDS (the common case — a new experiment dir shipping its own `.gitignore` for its
#     own artifacts, which the base tree has never seen): the base worktree says not-ignored, so the tree is
#     copied (the ENOSPC bug, unfixed) and `git add` then skips it — silently, with the #340/#331 guard
#     reporting nothing, since IGNORED_UNDER_STAGE was built from the base-only verdict.
#   * a rule the input REMOVES or negates: the base worktree says ignored, so the file is neither copied nor
#     committed and the guard BLOCKs on it — where the old code committed it. That is a change to "what
#     ultimately gets committed", which #666 declares a non-goal.
#
# The excluded set is ENUMERATED here rather than discovered after the fact: `git ls-files --others
# --ignored` (what check_ignored_files used to call) can only ever report files PRESENT in the worktree, so
# not copying them would have silently turned the #340/#331 guard into a no-op. `git check-ignore` answers
# the same question for paths that were never copied, in the same worktree — same index, same .gitignore /
# exclude files, and the same tracked-file exemption `git add` honors — so the guard's list is the one
# ls-files produced, minus the copy of the bytes. Ignore rules match a file INSIDE an ignored directory too,
# so a wholly-ignored tree is still enumerated file-by-file, which is what check_excluded_claim needs.
declare -a IGNORED_UNDER_STAGE=()
copy_stage_paths() {
  local cand ign copy rules rc=0 p d
  cand="$WT_PARENT/stage-candidates"; ign="$WT_PARENT/stage-ignored"
  copy="$WT_PARENT/stage-copy"; rules="$WT_PARENT/stage-rules"
  local -a roots=()
  for p in "${STAGE_PATHS[@]}"; do roots+=("$REPO_ROOT/$p"); done
  # Absolute roots (so find never reads a leading '-' in a path as an option), stripped back to the
  # repo-root-relative form check-ignore, `git add` and the guard's printed list all use. `-P` (find's
  # default) NEVER follows a symlink, so a symlinked file or dir is listed as ITSELF and copied verbatim
  # below: --only stages exactly the path you name (#586) and symlink_scan still wholesale-BLOCKs it (#416).
  # Only regular files and symlinks are listed — git can stage nothing else, and an empty directory is not
  # representable in a commit. NUL-delimited throughout for the same path-safety reason secret_scan reads
  # paths raw; `LC_ALL=C sort -z` makes both the copy and the guard's printed list deterministic byte order.
  find "${roots[@]}" \( -type f -o -type l \) -print0 \
    | while IFS= read -r -d '' p; do printf '%s\0' "${p#"$REPO_ROOT/"}"; done \
    | LC_ALL=C sort -z > "$cand" || die "could not enumerate the files under $REL to stage"
  # ---- phase 1: materialize the INPUT's own ignore rules, before any verdict is computed -----------------
  # Every `.gitignore` the copy would bring in that can affect a staged path: the ones under the roots (in
  # $cand already), plus the ancestor chain from each root's parent up to $REL — with --only, `$REL/.gitignore`
  # governs `$REL/sub/x` but is not itself under the `$REL/sub/x` root, so find never lists it. A `.gitignore`
  # elsewhere under $DIR (a sibling dir no root descends into) cannot affect any staged path — gitignore rules
  # only ever apply to their own directory and below — so leaving it uncopied keeps --only's walk narrow
  # without changing a single verdict. Rules ABOVE $REL are the base worktree's own and are already in place;
  # $DIR does not contain them, so the old blanket copy did not override them either.
  local -A is_rule=()
  local -a rule_paths=()
  while IFS= read -r -d '' p; do
    [ "${p##*/}" = ".gitignore" ] || continue
    [ -n "${is_rule["$p"]:-}" ] || { is_rule["$p"]=1; rule_paths+=("$p"); }
  done < "$cand"
  local i root
  for i in "${!STAGE_PATHS[@]}"; do
    p="${STAGE_PATHS[$i]}"; root="${STAGE_ROOTS[$i]}"
    d="$(dirname "$p")"
    # Walk up while still at/inside this path's OWN root ($REL, or the --page-source root). A whole-dir run
    # (STAGE_PATHS=("$root")) exits on the first test — its own `$root/.gitignore` is under the root, so
    # $cand already carried it.
    while [ "$d" = "$root" ] || [ "${d#"$root"/}" != "$d" ]; do
      if [ -f "$REPO_ROOT/$d/.gitignore" ] || [ -L "$REPO_ROOT/$d/.gitignore" ]; then
        [ -n "${is_rule["$d/.gitignore"]:-}" ] || { is_rule["$d/.gitignore"]=1; rule_paths+=("$d/.gitignore"); }
      fi
      [ "$d" = "$root" ] && break
      d="$(dirname "$d")"
    done
  done
  # Copied unconditionally — INCLUDING a rule file that turns out to be ignored itself, which the blanket
  # copy also placed there. These are `.gitignore` files: the bytes are negligible, and getting the rule
  # state exactly right is the whole point.
  if [ "${#rule_paths[@]}" -gt 0 ]; then
    printf '%s\0' "${rule_paths[@]}" > "$rules"
    ( cd "$REPO_ROOT" && xargs -0 -r cp -P --parents -t "$WT" -- ) < "$rules" \
      || die "could not copy the input's .gitignore file(s) into the staging worktree under $WT_PARENT"
  fi
  # ---- phase 2: now decide, against the rule state `git add` will see -----------------------------------
  # check-ignore exits 1 when NOTHING matched (not an error) and >1 on a real failure — fail closed on the
  # latter rather than staging against an empty excluded-file list the #340 guard would then read as clean.
  git -C "$WT" check-ignore -z --stdin < "$cand" > "$ign" || rc=$?
  [ "$rc" -le 1 ] || die "internal: git check-ignore failed in the staging worktree (exit $rc) — refusing to stage without a trustworthy gitignore verdict"
  local -A ignored=()
  while IFS= read -r -d '' p; do ignored["$p"]=1; IGNORED_UNDER_STAGE+=("$p"); done < "$ign"
  # ---- phase 3: copy the rest (the rule files are already in place, so they are skipped here) ------------
  while IFS= read -r -d '' p; do
    if [ -z "${ignored["$p"]:-}" ] && [ -z "${is_rule["$p"]:-}" ]; then printf '%s\0' "$p"; fi
  done < "$cand" > "$copy"
  # `cp --parents` recreates each file's directory chain under $WT; -P keeps a symlink a symlink (never
  # dereferenced — see above). xargs batches, so this is a handful of execs, not one per file.
  ( cd "$REPO_ROOT" && xargs -0 -r cp -P --parents -t "$WT" -- ) < "$copy" \
    || die "could not copy the staged set into the staging worktree under $WT_PARENT (out of disk?)"
}
stage_worktree() {
  git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$BRANCH" && die "local branch $BRANCH already exists (a prior run may have failed) — remove it and retry"
  git -C "$REPO_ROOT" rev-parse --verify --quiet "origin/$BASE_BRANCH^{commit}" >/dev/null 2>&1 \
    || die "no origin/$BASE_BRANCH ref to base the log on — fetch origin (or set LOG_EXPERIMENT_BASE_BRANCH)"
  WT_PARENT="$(mktemp -d)" || die "could not create a temp dir for the staging worktree"
  [ -n "$WT_PARENT" ] && [ -d "$WT_PARENT" ] || { WT_PARENT=""; die "internal: mktemp -d returned an empty/non-existent path — refusing to stage (cleanup rm -rf's this dir by name)"; }
  WT="$WT_PARENT/wt"
  # SPARSE by default (#805): this worktree exists to hold the base tree's ignore/rule state plus $REL — it
  # never needs the other 300 registry records, and being a FULL checkout off origin/$BASE_BRANCH on EVERY log
  # run made it one of the scaffold's worktree-creation sites materializing the whole 5.3G registry (~2.2G on
  # disk) transiently in /tmp. The cone MUST cover $REL: `git add` refuses a path outside the sparse set, and
  # that refusal is exactly what makes a too-narrow cone loud instead of a silently short commit. Everything
  # the gates read is still present — cone mode keeps the repo root's files and each ancestor dir's own files
  # (so the base `.gitignore` and `registry/.gitignore` are there for check_ignored_files/copy_stage_paths),
  # and copy_stage_paths writes $REL's bytes itself.
  # $REL == "." (the degenerate "log the repo root" call) takes --full instead: cone mode silently DROPS a "."
  # entry, which would leave the whole tree outside the cone and let `git add -- .` stage only part of it.
  [ -x "$SPARSE_WORKTREE_HELPER" ] || die "missing/non-executable $SPARSE_WORKTREE_HELPER — it ships alongside log-experiment.sh; this install is incomplete"
  # Built as one argv array because the helper takes its flags BEFORE the positionals (a bare `--full` appended
  # after them would be read as an include path, not a flag).
  declare -a sparse_args=(--repo "$REPO_ROOT" -b "$BRANCH")
  [ "$REL" = "." ] && sparse_args+=(--full)
  sparse_args+=("$WT" "origin/$BASE_BRANCH")
  # Every staging ROOT must be in the cone, not just the record's: `git add` refuses a path outside the
  # sparse set, so a --page-source root left out would be a loud error rather than a short commit — but a
  # loud error on the one-landing close is not the behavior we want either.
  if [ "$REL" != "." ]; then
    local _root
    for _root in "${ROOT_RELS[@]}"; do sparse_args+=("$_root"); done
  fi
  # CREATED_BRANCH is set BEFORE the call, not after: the helper can fail at the sparse/checkout step with the
  # `-b` ref already created, and cleanup's `branch -D` must still reclaim it. Safe because the guard above
  # proved no branch of this name pre-existed, so cleanup can only ever delete THIS run's own ref.
  CREATED_BRANCH=1
  "$SPARSE_WORKTREE_HELPER" "${sparse_args[@]}" \
    || die "could not create worktree/branch $BRANCH off origin/$BASE_BRANCH"
  copy_stage_paths
  # STAGE_PATHS is "$REL" (the whole dir) unless --only narrowed it (#374) — either way this `git add` sees
  # only the copy_stage_paths subset, so anything the worktree's .gitignore excludes (large artifacts stay
  # on R2) or that --only left out is never staged/committed/pushed, exactly as before; it is now simply
  # never copied either (#666). Still pathspecs rather than the file list, so this stays the same `git add`
  # invocation as before the #666 change — copy_stage_paths, not the pathspec form, is what narrowed the set.
  # Drop any pathspec that now resolves to NOTHING — neither present in the worktree nor known to the index.
  # `git add` aborts the WHOLE invocation on an unmatched pathspec, which would drop the co-named good paths
  # with it; the only way to get one is `--only` naming a wholly-gitignored path, which the old copy handed
  # to `git add` as a present-but-ignored file: git skipped exactly that path (exit 1, hence the `|| true`
  # below) and staged the rest, then check_ignored_files reported the drop. Filtering here reproduces that —
  # same rest staged, and the ignored path is still in IGNORED_UNDER_STAGE for the guard.
  local -a add_paths=(); local sp
  for sp in "${STAGE_PATHS[@]}"; do
    if [ -e "$WT/$sp" ] || [ -L "$WT/$sp" ] || git -C "$WT" ls-files --error-unmatch -- "$sp" >/dev/null 2>&1; then
      add_paths+=("$sp")
    fi
  done
  # `|| true` is a residual belt: `git add` given an EXPLICITLY-named ignored pathspec (only reachable via
  # --only) adds every OTHER named path but exits 1 for the ignored one, which is what the old
  # copy-everything-then-add path routinely hit. Nothing ignored is copied in now, so that exit should no
  # longer be reachable — but ANY nonzero here must still not kill the script under `set -e` before
  # check_ignored_files (next line) gets to run its own, better-messaged detection of exactly what dropped.
  [ "${#add_paths[@]}" -eq 0 ] || git -C "$WT" add -- "${add_paths[@]}" || true
  check_ignored_files                                 # #340: BLOCK on a non-trivial file the .gitignore silently dropped
  # `if` (not `… && die`): as the last statement of this function, a bare `diff --quiet` returning 1 (the
  # normal has-a-diff case) would make the function return 1 and trip `set -e` in the caller.
  if git -C "$WT" diff --cached --quiet; then
    if [ "${#ONLY_REL[@]}" -gt 0 ]; then
      die "nothing to commit for $REL --only ${ONLY_REL[*]} (unchanged vs origin/$BASE_BRANCH, or all gitignored?)"
    else
      die "nothing to commit for $REL (unchanged vs origin/$BASE_BRANCH, or all gitignored?)"
    fi
  fi
}

if [ "$DRY_RUN" = 1 ]; then
  # Stage off the LOCAL origin/$BASE_BRANCH (no fetch, no tokens) and run the SAME staged secret + symlink +
  # TEMP.md scans a real run would — so --dry-run validates the ACTUAL gate, not an approximation. Worktree
  # is trap-cleaned on exit.
  stage_worktree
  symlink_scan
  temp_handoff_scan
  scan_if_needed
  note "--dry-run: classified=$KIND${PS_REL:+, page source $PS_REL staged in the same commit}, gate PASSED (staged secret/symlink/TEMP.md scan clean); stopping before any push."
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
temp_handoff_scan
scan_if_needed
# Force the bot identity via env (overrides any ambient GIT_AUTHOR_*/GIT_COMMITTER_* + config) for author AND committer.
GIT_AUTHOR_NAME="$GA_NAME" GIT_AUTHOR_EMAIL="$GA_EMAIL" \
GIT_COMMITTER_NAME="$GA_NAME" GIT_COMMITTER_EMAIL="$GA_EMAIL" \
  git -C "$WT" commit -q -m "Log $KIND: $REL${PS_REL:+ (+ page source $PS_REL)}"
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
# The SHA check above and the delete below are two separate round-trips, so a push landing in between would
# otherwise race past an already-passed check. Close that gap with --force-with-lease=<ref>:<expect> on the
# delete itself: git refuses the delete server-side unless the remote ref is STILL at REMOTE_SHA at delete
# time, so a concurrent update lands as a lease rejection, never a deletion of live work (verified against a
# scratch bare repo: a lease keyed to a now-stale SHA is rejected "stale info" and the branch survives; keyed
# to the current SHA it deletes cleanly).
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
  git -C "$WT" -c credential.helper= push -q --force-with-lease="refs/heads/$BRANCH:$REMOTE_SHA" \
    "https://x-access-token:${ATOK}@github.com/${RESEARCH_REPO}.git" ":refs/heads/$BRANCH" \
    || die "could not delete stale remote branch $BRANCH (confirmed MERGED via PR #$STALE_PR, SHA-verified) — the remote ref moved past $REMOTE_SHA since that check (a concurrent push?) and the lease-guarded delete was refused, so no branch was destroyed; re-run to re-check the branch's current state"
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
        -t "Log $KIND: $REL${PS_REL:+ (+ page source $PS_REL)}" -b "$BODY")"
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
echo "OK: logged $KIND '$REL'${PS_REL:+ + page source '$PS_REL'} as PR #$PR (merged)."   # the EXIT trap removes the temp worktree + its local branch
