#!/usr/bin/env python3
"""worktree_sweep.py — the deterministic, box-independent worktree/repo janitor (automated-researcher#364).

THE CONTRACT: sweep one or more repos' `git worktree list`, and for every entry compute a small set of
FAIL-CLOSED facts (dirty? untracked? merged into the default branch? how old? — for the repo's own primary
checkout, how far behind/ahead of origin?), then route each flagged entry into exactly one of three tiers:

  tier 1 (deterministic "safe to reap")  — merged + clean + old, or the worktree's administrative record is
                                            plain PRUNABLE (working directory already gone). No one is asked.
  tier 2 (owner-session investigates)    — stray content, or a stale unmerged branch, whose candidate owner
                                            (derived from --worktree-root) reads as a LIVE session.
  tier 3 (researcher residual)          — everything flagged that isn't tier 1 and has no live owner to ask,
                                            plus the shared/main checkout's own drift (it has no "owner").

STATE: none. Every sweep recomputes every fact from scratch — the git state IS the state (#364 pinned
out-of-scope: no database of past reports). DELETION: `--reap-tier1` performs it, but this flag is a
deliberate researcher opt-in an instance's timer must not pass by default (#364 pinned out-of-scope: no
auto-reap) — see the plugin's SKILL.md.

FAIL-CLOSED, throughout: a `git status`/`log`/`merge-base` call that errors or times out leaves that fact
UNKNOWN (`None`), never a guessed default — an UNKNOWN fact disqualifies a worktree from tier 1 and routes
it to tier 2/3 tagged "inspection needed" instead (mirrors gpu-job's pod_reaper.sh: an unreadable result is
reported, never silently treated as the safe value).

Seams (mirroring gpu-job's GPU_JOB_*_CMD provider-seam pattern — instance-supplied, never product-side):
  REPO_JANITOR_LIVE_SESSIONS_CMD   "<cmd>" -> prints one LIVE session id per line. Unset -> empty set ->
                                    every owner reads as not-live (fail-safe: nothing is silently routed to
                                    tier 2 without a wired seam; it all surfaces to the researcher instead).
Session enumeration + message delivery are instance work; this script's contract ends at the report.
"""
import argparse
import json
import os
import shlex
import subprocess
import sys
import time

DEFAULT_MIN_AGE_DAYS = 7
DEFAULT_OWNER_DEPTH = 1
DEFAULT_DEFAULT_BRANCH = "main"

# Report-ergonomics collapse threshold (automated-researcher#533): the 2026-07-19 real sweep produced 40
# entries sharing the EXACT SAME "inspection needed" reason string (one root cause hitting every worktree
# identically), which buried the one actionable fact in noise instead of surfacing it once. A reason
# string is collapsed to one summary line + a flat path list once it accounts for at least this fraction of
# the sweep's total flagged entries, with a minimum absolute count so a small sweep with a few genuinely
# identical reasons isn't collapsed just for reaching the percentage.
REPORT_COLLAPSE_FRACTION = 0.2
REPORT_COLLAPSE_MIN_COUNT = 5


def log(msg):
    print(f"[janitor {time.strftime('%H:%M:%S', time.gmtime())}] {msg}", file=sys.stderr)


def die(msg):
    print(f"worktree_sweep: {msg}", file=sys.stderr)
    sys.exit(2)


def run_git(args, cwd, timeout=30):
    """Returns (returncode, stdout, stderr). returncode is None on timeout/missing-git — callers treat
    None the same as any other non-zero/non-one exit: UNKNOWN, never a guessed pass/fail."""
    try:
        p = subprocess.run(["git", "-C", cwd] + args, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return None, "", "timeout"
    except (FileNotFoundError, OSError) as e:
        return None, "", str(e)


def run_git_bytes(args, cwd, timeout=30):
    """Same contract as run_git, but stdout/stderr stay raw bytes — used for `git show <ref>:<path>`, where
    decoding through `text=True` (locale-dependent, universal-newline-translating) would corrupt a
    byte-for-byte comparison against a binary or non-UTF8 file."""
    try:
        p = subprocess.run(["git", "-C", cwd] + args, capture_output=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return None, b"", b"timeout"
    except (FileNotFoundError, OSError) as e:
        return None, b"", str(e).encode()


def load_live_sessions():
    """Returns (live_set, seam_failed). seam_failed distinguishes "no seam configured" (empty set is the
    deliberate fail-safe default) from "a configured seam errored" (liveness is UNKNOWN this sweep, not
    "nobody's live" — code-review Finding 1: silently folding a provider failure into the empty set would
    let a live owner's worktree read as ownerless and reach tier 1)."""
    cmd = os.environ.get("REPO_JANITOR_LIVE_SESSIONS_CMD", "").strip()
    if not cmd:
        return set(), False
    try:
        parts = shlex.split(cmd)
        p = subprocess.run(parts, capture_output=True, text=True, timeout=30)
        if p.returncode != 0:
            log(f"REPO_JANITOR_LIVE_SESSIONS_CMD failed (rc={p.returncode}) — liveness UNKNOWN this sweep")
            return set(), True
        return {line.strip() for line in p.stdout.splitlines() if line.strip()}, False
    except Exception as e:  # noqa: BLE001 - any seam failure is UNKNOWN, never fatal
        log(f"REPO_JANITOR_LIVE_SESSIONS_CMD errored ({e}) — liveness UNKNOWN this sweep")
        return set(), True


def owner_live_status(owner, live, seam_failed):
    """"live" | "not_live" | "unknown" for a candidate owner id (None owner -> "not_live": no owner
    question applies). "unknown" (seam configured but failed) is treated the same as "live" everywhere
    that matters for safety (never tier 1, never silently reaped) but is reported distinctly."""
    if owner is None:
        return "not_live"
    if seam_failed:
        return "unknown"
    return "live" if owner in live else "not_live"


def resolve_default_ref(repo, default_branch):
    """Returns the ref to compare against (remote-tracking preferred, local branch as fallback), or None
    (UNKNOWN) if neither can be verified to exist. The old version treated ANY non-zero rev-parse — a
    confirmed "ref absent" (rc==1) and an unrelated lookup failure (timeout, git missing, ...) alike — as
    "remote ref absent" and fell back to the bare `default_branch` string unverified. That bare name could
    resolve to a same-named TAG (`refs/tags/<name>` is checked before `refs/heads/<name>` in git's revision
    lookup order) or to nothing at all, silently corrupting every merged/behind/ahead fact derived from it.
    Each candidate ref is now verified fully-qualified and independently; a lookup error on either one
    propagates as UNKNOWN rather than being read as "try the next candidate"."""
    remote_ref = f"refs/remotes/origin/{default_branch}"
    rc, _, _ = run_git(["rev-parse", "-q", "--verify", remote_ref], cwd=repo)
    if rc == 0:
        return remote_ref
    if rc != 1:
        return None  # lookup error, not a confirmed "absent" — never guess

    local_ref = f"refs/heads/{default_branch}"
    rc, _, _ = run_git(["rev-parse", "-q", "--verify", local_ref], cwd=repo)
    if rc == 0:
        return local_ref
    return None  # confirmed absent (rc==1) or a lookup error (any other rc) — either way, UNKNOWN


def parse_worktrees(repo):
    """Parse `git worktree list --porcelain`. Returns None on a repo-level failure (report, not a crash)."""
    rc, out, _ = run_git(["worktree", "list", "--porcelain"], cwd=repo)
    if rc != 0:
        return None
    entries = []
    cur = {}

    def flush():
        if cur:
            entries.append(dict(cur))

    for line in out.splitlines():
        if line == "":
            flush()
            cur.clear()
        elif line.startswith("worktree "):
            flush()
            cur.clear()
            cur.update({"path": line[len("worktree "):], "detached": False, "prunable": False, "bare": False})
        elif line.startswith("HEAD "):
            cur["head"] = line[len("HEAD "):]
        elif line.startswith("branch "):
            cur["branch"] = line[len("branch "):]
        elif line == "detached":
            cur["detached"] = True
        elif line.startswith("prunable"):
            cur["prunable"] = True
        elif line == "bare":
            cur["bare"] = True
    flush()
    for i, e in enumerate(entries):
        e["is_main"] = (i == 0)
    return entries


def status_facts(path):
    """(dirty, untracked_count, ignored_count) — all None (UNKNOWN) on any status failure.

    Forces `--untracked-files=all` (code-review Finding 1): a repo/global `status.showUntrackedFiles=no`
    config would otherwise make `git status --porcelain` report ZERO untracked files even when real
    untracked content is present, letting a genuinely non-clean worktree read as "clean" and reach tier 1.
    Also forces `--ignored`: verified empirically that `git worktree remove` deletes the ENTIRE directory
    tree once it judges the tree clean — it does NOT spare .gitignore'd content (git has no
    "preserve ignored files" mode for worktree removal). Plain `git status --porcelain` never lists
    ignored files at all, so without this an ignored-but-valuable file (a local `.env`, unstaged secrets,
    anything a broad gitignore pattern happens to match) would be silently destroyed by a tier-1 reap.
    """
    rc, out, _ = run_git(["status", "--porcelain", "--untracked-files=all", "--ignored"], cwd=path)
    if rc != 0:
        return None, None, None
    lines = [l for l in out.splitlines() if l]
    untracked = sum(1 for l in lines if l.startswith("??"))
    ignored = sum(1 for l in lines if l.startswith("!!"))
    dirty = any(not l.startswith("??") and not l.startswith("!!") for l in lines)
    return dirty, untracked, ignored


def age_days_fact(path, now_ts):
    rc, out, _ = run_git(["log", "-1", "--format=%ct"], cwd=path)
    out = out.strip()
    if rc == 0 and out.isdigit():
        return (now_ts - int(out)) // 86400
    return None


def merged_fact(repo, head, default_ref):
    if not head or not default_ref:
        return None
    rc, _, _ = run_git(["merge-base", "--is-ancestor", head, default_ref], cwd=repo)
    if rc == 0:
        return True
    if rc == 1:
        return False
    return None  # any other exit (bad ref, unresolvable object, timeout) -> UNKNOWN, never a guess


def dirty_untracked_entries(path):
    """(entries, ok) — entries is the list of (status_code, relpath) for every dirty (tracked, changed) or
    untracked file in `path`, never ignored. Used only by content_identical_fact below. NUL-parsed (`-z`)
    rather than line-based, so a path containing a space/newline/quote can't be mis-split the way the
    plain-line `--porcelain` parsing in status_facts() would (that parsing only ever needs prefix/count,
    never the exact path, so it's safe as-is; this one hands paths to `open()`, so it isn't). ok=False
    (entries=None) on any status failure — fails that fact closed, same as every other check here."""
    rc, out, _ = run_git(["status", "--porcelain=v1", "--untracked-files=all", "--ignored", "-z"], cwd=path)
    if rc != 0:
        return None, False
    entries = []
    tokens = out.split("\0")
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        i += 1
        if not tok:
            continue
        code, filepath = tok[:2], tok[3:]
        if code[0] in ("R", "C") and i < len(tokens):
            i += 1  # skip the old-path token git emits for renames/copies in -z mode
        if code == "!!":
            continue
        entries.append((code, filepath))
    return entries, True


def content_identical_fact(repo, path, head, default_ref):
    """Squash-merge-aware ALTERNATIVE to `merged_fact` (automated-researcher#533): under a squash-merge PR
    flow, a worktree's branch is never itself merged into the default branch — its content lands as a new,
    unrelated squashed commit — so `merged_fact` returns a confirmed False forever, and no experiment/design
    worktree from such a repo could ever reach tier 1, however clean and old.

    Reaping the WORKTREE (never the branch ref itself — `remove_action`'s best-effort `git branch -d` is a
    no-op here since the branch genuinely isn't an ancestor, and that failure is already non-fatal, so the
    ref simply survives) only risks losing content that exists NOWHERE else: every file this worktree's
    HEAD commit records, plus everything `git status` reports on top of it (besides ignored files, which
    already block tier 1 independently). True when ALL of that is byte-identical to `default_ref` — i.e.
    the tree contains zero content the default branch doesn't already have.

    Two passes, deliberately not one uniform per-file scan (efficiency, and it changes what a "no" means):

    1. **Committed tree vs `default_ref`** — a single `git diff --name-only <default_ref> <head>` (a plain
       two-tree diff; no common-ancestor requirement, so it works precisely when `merged_fact` can't). An
       EMPTY result is a confirmed "every tracked file already matches" — this is what actually lets a
       clean, already-squash-landed worktree through (a fully clean worktree has nothing else to check). A
       NON-EMPTY result is a confirmed, deterministic "no" (`False`, not UNKNOWN): git has just told us
       specific files genuinely differ, which is a real answer, not a failed check — this is what keeps an
       otherwise-clean-but-genuinely-unmerged branch (real content of its own, not reflected on the default
       branch under any commit) correctly OUT of this alternative, the same as before this feature existed.
    2. **Working-tree residue on top of that** (untracked files, and uncommitted edits to tracked files —
       git diff's tree comparison above never sees these) — compared file-by-file against `default_ref`.
       None (UNKNOWN) on ANY failure to complete one of these comparisons: the local file can't be read, or
       `git show <default_ref>:<path>` errors for ANY reason, including the path simply not existing at
       `default_ref` at all. That last case reads as UNKNOWN rather than a confirmed "different" on purpose
       (scope note, automated-researcher#533): a per-file compare failure fails this fact closed exactly
       like every other fact in this script, rather than the script guessing which kind of failure it saw.
    """
    rc, out, _ = run_git(["diff", "--name-only", default_ref, head], cwd=repo)
    if rc != 0:
        return None
    if out.strip():
        return False  # confirmed: this branch carries tracked content the default branch doesn't have

    entries, ok = dirty_untracked_entries(path)
    if not ok:
        return None
    for _, rel in entries:
        try:
            with open(os.path.join(path, rel), "rb") as f:
                local_bytes = f.read()
        except OSError:
            return None
        rc, remote_bytes, _ = run_git_bytes(["show", f"{default_ref}:{rel}"], cwd=repo)
        if rc != 0:
            return None
        if remote_bytes != local_bytes:
            return False
    return True


def behind_ahead_facts(repo, default_ref):
    if not default_ref:
        return None, None
    rc, out, _ = run_git(["rev-list", "--left-right", "--count", f"{default_ref}...HEAD"], cwd=repo)
    if rc == 0:
        parts = out.split()
        if len(parts) == 2 and all(p.isdigit() for p in parts):
            return int(parts[0]), int(parts[1])
    return None, None


def submodule_fact(path):
    """True if `path` contains at least one INITIALIZED (checked-out) submodule, False if it has none or
    only uninitialized ones, None (UNKNOWN) only if BOTH the primary check and its degraded fallback below
    fail to produce an answer.

    Verified empirically: `git worktree remove` unconditionally refuses ("fatal: working trees containing
    submodules cannot be moved or removed") once ANY submodule is initialized, regardless of whether that
    submodule is itself clean — so merged+clean+old is NOT actually safe-to-reap when a submodule is
    checked out; every reap attempt would fail. An UNINITIALIZED submodule (present in .gitmodules/the
    index but never checked out — an empty directory) does NOT trigger this refusal.
    `git submodule status` prefixes an uninitialized submodule with '-'; any other prefix (' ' up to date,
    '+' out of sync with the index, 'U' conflicted) means it's checked out.

    `git submodule status` exits non-zero (128) the moment ANY gitlink in the tree lacks a `.gitmodules`
    mapping — repo-wide for that worktree, not just for the unmapped path (automated-researcher#533's
    real-world trigger: one historical gitlink with no `.gitmodules` entry made this fail identically for
    EVERY worktree whose checkout contained that path, which previously read as UNKNOWN and disqualified
    every one of them from tier 1 for a reason that had nothing to do with their own submodule state).
    On that failure, fall back to a per-path scan of the index's gitlink entries (mode 160000 in
    `git ls-files -s`) and check each one directly for a `.git` entry (git's own initialized-vs-not
    signal) — this degrades a broken `.gitmodules` mapping to a real answer instead of poisoning the whole
    fact, and still correctly reports True the moment any OTHER, properly-initialized submodule is found.
    """
    rc, out, _ = run_git(["submodule", "status"], cwd=path)
    if rc == 0:
        return any(line and not line.startswith("-") for line in out.splitlines())

    log(f"'git submodule status' failed (rc={rc}) for {path} — falling back to a per-path gitlink scan "
        "instead of marking the whole worktree's submodule fact UNKNOWN (likely an unmapped gitlink)")
    rc2, out2, _ = run_git(["ls-files", "-s"], cwd=path)
    if rc2 != 0:
        return None  # both checks failed -> genuinely UNKNOWN, fail closed same as before
    for line in out2.splitlines():
        if not line.startswith("160000") or "\t" not in line:
            continue
        rel = line.split("\t", 1)[1]
        if os.path.exists(os.path.join(path, rel, ".git")):
            return True
    return False


def owner_of(path, root, depth):
    if not root:
        return None
    # realpath (not just abspath — round-2 code-review Finding 1, on top of round-1 Finding 2): a
    # RELATIVE root would never prefix-match git's absolute worktree paths (disabling ownership and the
    # live-owner tier-1 veto for every worktree), and a SYMLINKED root would still fail a lexical
    # comparison against the resolved paths git reports — realpath resolves both symlinks and relativity.
    root = os.path.realpath(os.path.expanduser(root))
    p = os.path.realpath(path)
    try:
        common = os.path.commonpath([root, p])
    except ValueError:
        return None
    if common != root or p == root:
        return None
    rel = os.path.relpath(p, root)
    parts = rel.split(os.sep)
    return "/".join(parts[:depth]) if parts and parts[0] else None


def branch_name(entry):
    b = entry.get("branch")
    if not b:
        return None
    return b[len("refs/heads/"):] if b.startswith("refs/heads/") else b


def gitcmd(*args):
    """A displayable/copy-pasteable `git ...` command, properly quoted (code-review Finding 4 — an
    f-string interpolation of a path/branch containing a space or shell metacharacter would print a
    malformed or dangerous command; shlex.join over the real argv is safe to copy-paste or exec)."""
    return shlex.join(["git", *args])


def inspect_action(path):
    return {"kind": "inspect", "commands": [gitcmd("-C", path, "status"), gitcmd("-C", path, "log", "-1")]}


def remove_action(repo, path, branch, default_branch):
    cmds = [gitcmd("-C", repo, "worktree", "remove", path)]
    # NEVER suggest (or later execute) deleting the ref matching the configured default branch name
    # (round-3 code-review Finding 2): a linked worktree can legitimately be checked out ON the default
    # branch itself (git only forbids the SAME branch checked out twice, not a linked worktree on main
    # while the primary checkout sits on something else) — deleting that ref would break every other
    # worktree/operation that depends on the default branch existing, regardless of this one being "merged".
    if branch and branch != default_branch:
        cmds.append(gitcmd("-C", repo, "branch", "-d", branch))
    return {"kind": "remove", "commands": cmds}


def prune_action(repo):
    return {"kind": "prune", "commands": [gitcmd("-C", repo, "worktree", "prune")]}


def process_repo(repo, args, live, seam_failed, now_ts, results, reap_plan):
    repo = os.path.abspath(os.path.expanduser(repo))

    entries = parse_worktrees(repo)
    if entries is None:
        results["tier3"].append({
            "repo": repo, "path": repo, "branch": None, "owner": None, "tier": 3,
            "reason": "inspection needed: `git worktree list` failed for this repo",
            "action": inspect_action(repo),
        })
        return

    # Canonicalize every subsequent git invocation to the TRUE primary checkout, never the raw --repo
    # argument (round-2 code-review Finding 3): `git worktree list`'s first entry is ALWAYS the repo's own
    # primary working tree (parse_worktrees marks it is_main). If --repo were ever pointed at a LINKED
    # worktree instead, using the raw argument as the cwd for every `git -C` call risks that cwd being
    # invalidated mid-reap-loop if that same linked worktree were itself a reap target. The primary
    # checkout is never a reap target (main/shared worktrees are never tier 1), so anchoring here is
    # stable for the whole sweep.
    main_repo = entries[0]["path"]

    # Fetch BEFORE resolving the default ref (code-review Finding 6): on a repo that has never fetched,
    # `origin/<default-branch>` doesn't exist yet until the fetch creates it — resolving first would lock
    # in the local-branch fallback and silently defeat --fetch's entire point on a fresh checkout.
    fetch_ok = None
    if args.fetch:
        rc, _, _ = run_git(["fetch", "origin", "--quiet"], cwd=main_repo, timeout=90)
        fetch_ok = (rc == 0)
        if not fetch_ok:
            log(f"--fetch requested but failed for {main_repo} — origin drift for its main worktree is UNKNOWN this sweep")
    default_ref = resolve_default_ref(main_repo, args.default_branch)
    if default_ref is None:
        log(f"could not resolve default ref '{args.default_branch}' for {main_repo} "
            f"(neither origin/{args.default_branch} nor refs/heads/{args.default_branch} verified) "
            "— merged/drift facts UNKNOWN this sweep")

    for e in entries:
        if e.get("bare"):
            continue  # a bare mirror has no working tree to sweep
        process_entry(main_repo, e, default_ref, args, live, seam_failed, now_ts, fetch_ok, results, reap_plan)


def process_entry(repo, e, default_ref, args, live, seam_failed, now_ts, fetch_ok, results, reap_plan):
    path = e["path"]
    head = e.get("head")
    branch = branch_name(e)
    is_main = e["is_main"]
    owner = owner_of(path, args.worktree_root, args.owner_depth)
    liveness = owner_live_status(owner, live, seam_failed)  # "live" | "not_live" | "unknown"

    base = {"repo": repo, "path": path, "branch": branch, "owner": owner}

    if not is_main and e.get("prunable"):
        entry = dict(base, tier=1, reason="prunable (administrative record only, working directory missing)",
                     action=prune_action(repo))
        results["tier1"].append(entry)
        reap_plan.append(dict(entry, kind="prune"))
        return

    dirty, untracked, ignored = status_facts(path)

    if is_main:
        behind, ahead = (None, None)
        if not (args.fetch and not fetch_ok):
            # cwd=path (this entry's own working dir), not the raw --repo argument (code-review Finding
            # 7): if --repo were ever pointed at a linked worktree, `path` (proven by is_main to be the
            # TRUE primary checkout) can differ from `repo`, and rev-list's `...HEAD` means "whatever's
            # checked out at cwd" — using the wrong cwd would silently compute drift for the wrong tree.
            behind, ahead = behind_ahead_facts(path, default_ref)
        unknown = dirty is None or untracked is None or behind is None or ahead is None
        flagged = unknown or dirty or (untracked or 0) > 0 or (behind or 0) > 0 or (ahead or 0) > 0
        if not flagged:
            return
        bits = []
        if unknown:
            bits.append("some facts UNKNOWN (a check failed)")
        else:
            if dirty:
                bits.append("dirty")
            if untracked:
                bits.append(f"{untracked} untracked")
            if behind:
                bits.append(f"{behind} behind origin")
            if ahead:
                bits.append(f"{ahead} ahead of origin")
        note = "" if args.fetch else " (origin state as of last fetch — pass --fetch for a live check)"
        entry = dict(base, tier=3, reason=f"shared checkout drift: {', '.join(bits)}{note}",
                     action=inspect_action(path))
        results["tier3"].append(entry)
        return

    # linked worktree, not prunable
    merged = merged_fact(repo, head, default_ref)
    age_days = age_days_fact(path, now_ts)
    has_submodule = submodule_fact(path)

    # content-identity: the squash-merge-aware ALTERNATIVE to `merged` (automated-researcher#533) — only
    # worth computing when `merged` is a CONFIRMED False (a real ancestry check ran and failed); `merged is
    # None` is a different, unrelated failure (unresolvable ref/object) already routed to UNKNOWN below.
    content_identical = None
    if merged is False and default_ref is not None and head:
        content_identical = content_identical_fact(repo, path, head, default_ref)
    squash_safe = content_identical is True

    unknown = (dirty is None or untracked is None or ignored is None or merged is None or age_days is None
               or has_submodule is None or (merged is False and content_identical is None))

    if unknown:
        reason = "inspection needed: a status/log/merge-base/content-identity check failed for this worktree"
        if liveness == "live":
            results["tier2"].setdefault(owner, []).append(dict(base, tier=2, reason=reason, action=inspect_action(path)))
        else:
            if liveness == "unknown":
                reason += f" (owner '{owner}' liveness also unverifiable this sweep)"
            results["tier3"].append(dict(base, tier=3, reason=reason, action=inspect_action(path)))
        return

    is_old = age_days >= args.min_age_days
    merge_ok = bool(merged) or squash_safe
    # clean_ok folds in the content-identity alternative: when squash_safe holds, every dirty/untracked
    # file this worktree carries is confirmed byte-identical to the default branch already, so the
    # classic "not dirty and zero untracked" bar isn't the only way to be clean — nothing is lost by
    # reaping regardless (the worktree's branch ref survives `git branch -d`'s no-op the same as always).
    clean_ok = (not dirty and untracked == 0) or squash_safe
    # ignored == 0 is part of the tier-1 bar, NOT of stray_or_stale (code-review Finding 1): ignored
    # build-artifact clutter (node_modules, __pycache__, a venv) is common and harmless to leave alone,
    # so it doesn't need to nag a live tier2/3 report every week — but it DOES need to block automatic
    # deletion, since `git worktree remove` deletes ignored content right along with everything else.
    # merged+clean(tracked)+zero-untracked+old+has-ignored-content therefore falls through to SILENT
    # (nothing unsafe happens, nothing noisy is reported) rather than either tier.
    # not has_submodule is likewise part of the tier-1 bar (merge-gate final-review MED finding): unlike
    # ignored content, an otherwise-safe worktree carrying an INITIALIZED submodule can't be silently left
    # alone — `git worktree remove` unconditionally refuses it, so it must be flagged (not silently
    # skipped) for a human to remove manually or with --force.
    det_safe = merge_ok and clean_ok and ignored == 0 and is_old and not has_submodule
    submodule_blocks_reap = merge_ok and clean_ok and ignored == 0 and is_old and has_submodule
    stray_or_stale = ((dirty or untracked > 0) and not squash_safe) or (not merge_ok and is_old) or submodule_blocks_reap

    if not (det_safe or stray_or_stale):
        return  # in-progress (unmerged+fresh), just-merged-and-fresh, or merged+clean+old-but-ignored-content

    clean_old_phrase = (f"merged, clean, {age_days}d old" if merged else
                        f"clean (all residue already on {args.default_branch} — squash-merge equivalent), "
                        f"{age_days}d old")

    if det_safe and liveness == "not_live":
        entry = dict(base, tier=1, reason=f"{clean_old_phrase} — safe to reap",
                     action=remove_action(repo, path, branch, args.default_branch))
        results["tier1"].append(entry)
        reap_plan.append(dict(entry, kind="remove", owner=owner, merged=merged, dirty=dirty,
                               untracked=untracked, ignored=ignored, age_days=age_days, head=head))
        return

    if det_safe:
        if liveness == "live":
            reason = f"{clean_old_phrase}, but {owner} is live — confirm this is really unused before it's reaped"
        else:  # "unknown" — treated the same as live for safety (never reaped), reported distinctly
            reason = (f"{clean_old_phrase}, but owner '{owner}' liveness could not be verified "
                      "this sweep — treated conservatively, not reaped")
    else:
        bits = []
        if dirty and not squash_safe:
            bits.append("dirty")
        if untracked and not squash_safe:
            bits.append(f"{untracked} untracked")
        if not merge_ok and is_old:
            bits.append(f"unmerged, {age_days}d old, no one continuing it")
        if submodule_blocks_reap:
            bits.append(f"{clean_old_phrase}, but contains an initialized submodule "
                        "(`git worktree remove` refuses these — needs manual or forced removal)")
        reason = "; ".join(bits)
        if liveness == "unknown":
            reason += f" (owner '{owner}' liveness could not be verified this sweep)"

    if liveness == "live":
        results["tier2"].setdefault(owner, []).append(dict(base, tier=2, reason=reason, action=inspect_action(path)))
    else:
        results["tier3"].append(dict(base, tier=3, reason=reason, action=inspect_action(path)))


def do_reap(reap_plan, dry_run, default_branch):
    """Returns the count of ACTUAL failures (a prune/remove that genuinely didn't happen) — a defensive
    skip (state changed, owner now live) is the safety net working as intended, not a failure, and is not
    counted (code-review Finding 5: callers need to distinguish "nothing needed doing" from "a requested
    reap didn't happen")."""
    fails = 0

    # Prune items are handled per-REPO, not per-item: `git worktree prune` prunes every stale record for
    # that repo in one call, and (round-3 code-review Finding 4) a per-record failure inside that single
    # call can still leave the command's own exit code 0 — so verify each PLANNED prunable path is
    # actually gone afterward rather than trusting the exit code alone. A FAILED post-prune listing
    # (merge-gate Finding 4) is NOT the same as "nothing left" — `parse_worktrees` returning None must
    # count every planned item for that repo as unverified/failed, never silently as "successfully pruned".
    prune_items_by_repo = {}
    for item in reap_plan:
        if item["kind"] == "prune":
            prune_items_by_repo.setdefault(item["repo"], []).append(item)
    for repo, items in prune_items_by_repo.items():
        if dry_run:
            for it in items:
                log(f"DRY-RUN would prune: {it['path']}")
            continue
        rc, _, err = run_git(["worktree", "prune"], cwd=repo)
        if rc != 0:
            log(f"prune command FAILED for {repo}: {err.strip()}")
            fails += len(items)
            continue
        post_entries = parse_worktrees(repo)
        if post_entries is None:
            log(f"prune ran but could not re-list {repo} to verify — treating all {len(items)} planned prune(s) as unverified")
            fails += len(items)
            continue
        still_listed = {e["path"] for e in post_entries}
        for it in items:
            if it["path"] in still_listed:
                log(f"PRUNE FAILED (still listed after prune): {it['path']}")
                fails += 1
            else:
                log(f"pruned {it['path']}")

    for item in reap_plan:
        if item["kind"] != "remove":
            continue
        # re-verify EVERYTHING immediately before deleting — liveness first (an owner who's now live, or
        # whose liveness we can no longer confirm, vetoes the reap same as at classification time), then
        # the git-state facts (defense against the state changing mid-sweep; no lock is needed for a
        # single-process weekly sweep, but the recheck is cheap). Liveness is reloaded FRESH for EVERY
        # item, not once for the whole batch (merge-gate Finding 2): an owner could go live in the gap
        # between this item's removal and an earlier item's in the same run, and a once-per-batch poll
        # would never see it.
        repo, path, branch, owner = item["repo"], item["path"], item["branch"], item.get("owner")
        fresh_live, fresh_seam_failed = load_live_sessions()
        liveness_now = owner_live_status(owner, fresh_live, fresh_seam_failed)
        if liveness_now != "not_live":
            log(f"SKIPPED (owner '{owner}' liveness is now '{liveness_now}', not re-verified safe): {path}")
            continue
        dirty, untracked, ignored = status_facts(path)
        head_now = run_git(["rev-parse", "HEAD"], cwd=path)[1].strip()
        head_unchanged = bool(head_now) and head_now == item.get("head")
        # Re-resolve the default ref and re-check ancestry too (round-3 code-review Finding 3): mergedness
        # depends on the MUTABLE default ref, not on the worktree's HEAD alone — a HEAD-pin alone catches
        # "the worktree changed" but not "the default branch was reset/force-updated out from under it"
        # between classification and this reap. Re-verify both, independently.
        default_ref_now = resolve_default_ref(repo, default_branch)
        merged_now = merged_fact(repo, head_now, default_ref_now) if head_now else None
        # Re-check the squash-merge content-identity alternative too, same as classification (process_entry)
        # — a squash-merge branch's `merged_now` is a confirmed False forever, so gating solely on
        # `merged_now is True` would make every content-identity-qualified tier-1 item SKIP here
        # unconditionally, defeating the whole point of the alternative bar at the one moment it matters.
        content_identical_now = None
        if merged_now is False and default_ref_now is not None and head_now:
            content_identical_now = content_identical_fact(repo, path, head_now, default_ref_now)
        squash_safe_now = content_identical_now is True
        merge_ok_now = bool(merged_now) or squash_safe_now
        clean_ok_now = (dirty is False and untracked == 0) or squash_safe_now
        still_safe = clean_ok_now and ignored == 0 and head_unchanged and merge_ok_now
        if not still_safe:
            log(f"SKIPPED (state changed since classification, not re-verified safe): {path}")
            continue
        if dry_run:
            log(f"DRY-RUN would remove: path={path} branch={branch} head={item.get('head')}")
            continue
        rc, _, err = run_git(["worktree", "remove", path], cwd=repo)
        if rc != 0:
            log(f"REMOVE FAILED: path={path}: {err.strip()}")
            fails += 1
            continue
        log(f"REMOVED: path={path} branch={branch} head={item.get('head')}")
        # NEVER delete the ref matching the configured default branch name (round-3 code-review Finding
        # 2): a linked worktree can legitimately be checked out ON the default branch itself, and deleting
        # that ref would break every other worktree/operation depending on it existing.
        if branch and branch != default_branch:
            rc2, _, err2 = run_git(["branch", "-d", branch], cwd=repo)
            if rc2 != 0:
                log(f"branch delete failed (non-fatal): {branch}: {err2.strip()}")
        elif branch:
            log(f"NOT deleting branch ref '{branch}' — matches the configured default branch name")
    return fails


def render_group(lines, entries, collapse_at):
    """Renders one tier's (or one tier-2 owner's) entries, collapsing any reason string shared by more than
    `collapse_at` entries into a single summary line + a flat path list, instead of repeating the full
    reason and action commands once per entry. Order-preserving: reasons render in first-seen order, and
    entries within an uncollapsed reason render in their original order."""
    by_reason = {}
    order = []
    for it in entries:
        if it["reason"] not in by_reason:
            order.append(it["reason"])
        by_reason.setdefault(it["reason"], []).append(it)
    for reason in order:
        group = by_reason[reason]
        if len(group) > collapse_at:
            lines.append(f"- [{len(group)} worktrees, same root cause] {reason}")
            for it in group:
                lines.append(f"    {it['path']} [{it['branch'] or '(detached)'}]")
        else:
            for it in group:
                lines.append(f"- {it['path']} [{it['branch'] or '(detached)'}] — {it['reason']}")
                for c in it["action"]["commands"]:
                    lines.append(f"    $ {c}")


def render_text(results):
    lines = []
    t1, t2, t3 = results["tier1"], results["tier2"], results["tier3"]
    if not t1 and not t2 and not t3:
        print("[janitor] sweep clean — nothing to report", file=sys.stderr)
        return
    total = len(t1) + sum(len(v) for v in t2.values()) + len(t3)
    collapse_at = max(REPORT_COLLAPSE_MIN_COUNT, total * REPORT_COLLAPSE_FRACTION)
    if t1:
        lines.append(f"## Tier 1 — safe to reap ({len(t1)})")
        render_group(lines, t1, collapse_at)
    if t2:
        owner_total = sum(len(v) for v in t2.values())
        lines.append(f"\n## Tier 2 — owner investigates ({owner_total})")
        for owner in sorted(t2):
            lines.append(f"### owner: {owner}")
            render_group(lines, t2[owner], collapse_at)
    if t3:
        lines.append(f"\n## Tier 3 — researcher residual ({len(t3)})")
        render_group(lines, t3, collapse_at)
    print("\n".join(lines))


def build_parser():
    p = argparse.ArgumentParser(description="Deterministic worktree/repo janitor sweep (automated-researcher#364)")
    p.add_argument("--repo", action="append", default=[], help="a repo whose worktrees to sweep (repeatable, required)")
    p.add_argument("--worktree-root", default=None, help="root under which owner ids are derived (default: none -> no ownership)")
    p.add_argument("--owner-depth", type=int, default=DEFAULT_OWNER_DEPTH, help="path segments under root -> owner id (default 1)")
    p.add_argument("--min-age-days", type=int, default=DEFAULT_MIN_AGE_DAYS, help="tier-1 age threshold in days (default 7)")
    p.add_argument("--default-branch", default=DEFAULT_DEFAULT_BRANCH, help="default branch name (default main)")
    p.add_argument("--fetch", action="store_true", help="git fetch origin per repo before comparing (default off: uses last-fetched state)")
    p.add_argument("--json", action="store_true", help="machine-readable output instead of the human report")
    p.add_argument("--reap-tier1", action="store_true", help="perform tier-1 deletions after reporting")
    p.add_argument("--dry-run", action="store_true", help="with --reap-tier1: log removals without performing them")
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    if not args.repo:
        die("at least one --repo is required")
    # An empty/whitespace-only --repo would otherwise silently normalize to the CURRENT WORKING DIRECTORY
    # via os.path.abspath('') (merge-gate code-review Finding 3) — a blank/unset shell variable
    # interpolated into `--repo "$VAR"` must be a hard failure, never a silent "operate on cwd instead",
    # especially with --reap-tier1 in play.
    if any(not r.strip() for r in args.repo):
        die("--repo value(s) must not be empty/whitespace-only")
    if args.dry_run and not args.reap_tier1:
        die("--dry-run only makes sense together with --reap-tier1")
    if args.owner_depth < 1:
        die("--owner-depth must be >= 1")
    if args.min_age_days < 0:
        die("--min-age-days must be >= 0")
    # Normalize --default-branch to a short local-branch name (merge-gate code-review Finding 1): a caller
    # passing the fully-qualified `refs/heads/main` would otherwise compare unequal against the short
    # `branch_name()` values the classifier/reaper use, silently defeating the never-delete-the-default-
    # branch-ref guard (remove_action/do_reap compare by simple string equality).
    args.default_branch = args.default_branch.strip()
    if args.default_branch.startswith("refs/heads/"):
        args.default_branch = args.default_branch[len("refs/heads/"):]
    if not args.default_branch:
        die("--default-branch must not be empty")
    # Reject anything still containing '/' (merge-gate round-2 Finding 1): a remote shorthand
    # ("origin/main"), a fully-qualified remote ref ("refs/remotes/origin/main"), or a nested branch name
    # all resolve as valid git revisions for the merge-base comparison, but none of them is the LOCAL short
    # branch name `branch_name()` produces — comparing against one of these would silently defeat the
    # never-delete-the-default-branch guard (the string "main" would never equal "origin/main"). The
    # default branch is always a plain top-level name in practice; anything with a '/' is rejected outright
    # rather than guessed at.
    if "/" in args.default_branch:
        die("--default-branch must be a short local branch name (no '/') — "
            "not a remote shorthand, qualified ref, or nested branch name")

    live, seam_failed = load_live_sessions()
    now_ts = int(time.time())
    results = {"tier1": [], "tier2": {}, "tier3": []}
    reap_plan = []

    for repo in args.repo:
        process_repo(repo, args, live, seam_failed, now_ts, results, reap_plan)

    if args.json:
        print(json.dumps(results, indent=2, sort_keys=True))
    else:
        render_text(results)

    if args.reap_tier1:
        fails = do_reap(reap_plan, args.dry_run, args.default_branch)
        if fails:
            log(f"{fails} reap action(s) FAILED — exiting non-zero (see FAILED lines above)")
            sys.exit(1)


if __name__ == "__main__":
    main()
