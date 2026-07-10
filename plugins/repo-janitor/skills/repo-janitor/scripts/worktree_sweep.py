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


def load_live_sessions():
    cmd = os.environ.get("REPO_JANITOR_LIVE_SESSIONS_CMD", "").strip()
    if not cmd:
        return set()
    try:
        parts = shlex.split(cmd)
        p = subprocess.run(parts, capture_output=True, text=True, timeout=30)
        if p.returncode != 0:
            log(f"REPO_JANITOR_LIVE_SESSIONS_CMD failed (rc={p.returncode}) — treating as no live sessions")
            return set()
        return {line.strip() for line in p.stdout.splitlines() if line.strip()}
    except Exception as e:  # noqa: BLE001 - any seam failure is fail-safe empty, never fatal
        log(f"REPO_JANITOR_LIVE_SESSIONS_CMD errored ({e}) — treating as no live sessions")
        return set()


def resolve_default_ref(repo, default_branch):
    rc, _, _ = run_git(["rev-parse", "-q", "--verify", f"refs/remotes/origin/{default_branch}"], cwd=repo)
    if rc == 0:
        return f"origin/{default_branch}"
    return default_branch


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
    """(dirty, untracked_count) — both None (UNKNOWN) on any status failure."""
    rc, out, _ = run_git(["status", "--porcelain"], cwd=path)
    if rc != 0:
        return None, None
    lines = [l for l in out.splitlines() if l]
    untracked = sum(1 for l in lines if l.startswith("??"))
    dirty = any(not l.startswith("??") for l in lines)
    return dirty, untracked


def age_days_fact(path, now_ts):
    rc, out, _ = run_git(["log", "-1", "--format=%ct"], cwd=path)
    out = out.strip()
    if rc == 0 and out.isdigit():
        return (now_ts - int(out)) // 86400
    return None


def merged_fact(repo, head, default_ref):
    if not head:
        return None
    rc, _, _ = run_git(["merge-base", "--is-ancestor", head, default_ref], cwd=repo)
    if rc == 0:
        return True
    if rc == 1:
        return False
    return None  # any other exit (bad ref, unresolvable object, timeout) -> UNKNOWN, never a guess


def behind_ahead_facts(repo, default_ref):
    rc, out, _ = run_git(["rev-list", "--left-right", "--count", f"{default_ref}...HEAD"], cwd=repo)
    if rc == 0:
        parts = out.split()
        if len(parts) == 2 and all(p.isdigit() for p in parts):
            return int(parts[0]), int(parts[1])
    return None, None


def owner_of(path, root, depth):
    if not root:
        return None
    root = os.path.normpath(os.path.expanduser(root))
    p = os.path.normpath(path)
    if p != root and not p.startswith(root + os.sep):
        return None
    rel = os.path.relpath(p, root)
    if rel == os.curdir:
        return None
    parts = rel.split(os.sep)
    return "/".join(parts[:depth]) if parts and parts[0] else None


def branch_name(entry):
    b = entry.get("branch")
    if not b:
        return None
    return b[len("refs/heads/"):] if b.startswith("refs/heads/") else b


def inspect_action(path):
    return {"kind": "inspect", "commands": [f"git -C {path} status", f"git -C {path} log -1"]}


def remove_action(repo, path, branch):
    cmds = [f"git -C {repo} worktree remove {path}"]
    if branch:
        cmds.append(f"git -C {repo} branch -d {branch}")
    return {"kind": "remove", "commands": cmds}


def prune_action(repo):
    return {"kind": "prune", "commands": [f"git -C {repo} worktree prune"]}


def process_repo(repo, args, live, now_ts, results, reap_plan):
    repo = os.path.abspath(os.path.expanduser(repo))
    default_ref = resolve_default_ref(repo, args.default_branch)

    fetch_ok = None
    if args.fetch:
        rc, _, _ = run_git(["fetch", "origin", "--quiet"], cwd=repo, timeout=90)
        fetch_ok = (rc == 0)
        if not fetch_ok:
            log(f"--fetch requested but failed for {repo} — origin drift for its main worktree is UNKNOWN this sweep")

    entries = parse_worktrees(repo)
    if entries is None:
        results["tier3"].append({
            "repo": repo, "path": repo, "branch": None, "tier": 3,
            "reason": "inspection needed: `git worktree list` failed for this repo",
            "action": inspect_action(repo),
        })
        return

    for e in entries:
        if e.get("bare"):
            continue  # a bare mirror has no working tree to sweep
        process_entry(repo, e, default_ref, args, live, now_ts, fetch_ok, results, reap_plan)


def process_entry(repo, e, default_ref, args, live, now_ts, fetch_ok, results, reap_plan):
    path = e["path"]
    head = e.get("head")
    branch = branch_name(e)
    is_main = e["is_main"]
    owner = owner_of(path, args.worktree_root, args.owner_depth)
    owner_live = owner is not None and owner in live

    base = {"repo": repo, "path": path, "branch": branch, "owner": owner}

    if not is_main and e.get("prunable"):
        entry = dict(base, tier=1, reason="prunable (administrative record only, working directory missing)",
                     action=prune_action(repo))
        results["tier1"].append(entry)
        reap_plan.append(dict(entry, kind="prune"))
        return

    dirty, untracked = status_facts(path)

    if is_main:
        behind, ahead = (None, None)
        if not (args.fetch and not fetch_ok):
            behind, ahead = behind_ahead_facts(repo, default_ref)
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
    unknown = dirty is None or untracked is None or merged is None or age_days is None

    if unknown:
        reason = "inspection needed: a status/log/merge-base check failed for this worktree"
        if owner_live:
            results["tier2"].setdefault(owner, []).append(dict(base, tier=2, reason=reason, action=inspect_action(path)))
        else:
            results["tier3"].append(dict(base, tier=3, reason=reason, action=inspect_action(path)))
        return

    is_old = age_days >= args.min_age_days
    det_safe = merged and not dirty and untracked == 0 and is_old
    stray_or_stale = dirty or untracked > 0 or (not merged and is_old)

    if not (det_safe or stray_or_stale):
        return  # in-progress (unmerged+fresh) or just-merged-and-fresh — silent, re-sweeps next week

    if det_safe and not owner_live:
        entry = dict(base, tier=1, reason=f"merged, clean, {age_days}d old — safe to reap",
                     action=remove_action(repo, path, branch))
        results["tier1"].append(entry)
        reap_plan.append(dict(entry, kind="remove", merged=merged, dirty=dirty, untracked=untracked, age_days=age_days, head=head))
        return

    if det_safe and owner_live:
        reason = f"merged, clean, {age_days}d old, but {owner} is live — confirm this is really unused before it's reaped"
    else:
        bits = []
        if dirty:
            bits.append("dirty")
        if untracked:
            bits.append(f"{untracked} untracked")
        if not merged and is_old:
            bits.append(f"unmerged, {age_days}d old, no one continuing it")
        reason = "; ".join(bits)

    if owner_live:
        results["tier2"].setdefault(owner, []).append(dict(base, tier=2, reason=reason, action=inspect_action(path)))
    else:
        results["tier3"].append(dict(base, tier=3, reason=reason, action=inspect_action(path)))


def do_reap(reap_plan, dry_run, default_branch):
    pruned_repos = set()
    for item in reap_plan:
        if item["kind"] == "prune":
            if item["repo"] in pruned_repos:
                continue
            pruned_repos.add(item["repo"])
            if dry_run:
                log(f"DRY-RUN would prune: {item['repo']}")
                continue
            rc, _, err = run_git(["worktree", "prune"], cwd=item["repo"])
            log(f"pruned {item['repo']}" if rc == 0 else f"prune FAILED for {item['repo']}: {err.strip()}")
            continue

        # kind == "remove": re-verify immediately before deleting (defense against the state changing
        # mid-sweep — no lock is needed for a single-process weekly sweep, but the recheck is cheap).
        repo, path, branch = item["repo"], item["path"], item["branch"]
        dirty, untracked = status_facts(path)
        head_now = run_git(["rev-parse", "HEAD"], cwd=path)[1].strip()
        default_ref = resolve_default_ref(repo, default_branch)
        merged_now = merged_fact(repo, head_now, default_ref) if head_now else None
        still_safe = (dirty is False and untracked == 0 and merged_now is True)
        if not still_safe:
            log(f"SKIPPED (state changed since classification, not re-verified safe): {path}")
            continue
        if dry_run:
            log(f"DRY-RUN would remove: path={path} branch={branch} head={item.get('head')}")
            continue
        rc, _, err = run_git(["worktree", "remove", path], cwd=repo)
        if rc != 0:
            log(f"REMOVE FAILED: path={path}: {err.strip()}")
            continue
        log(f"REMOVED: path={path} branch={branch} head={item.get('head')}")
        if branch:
            rc2, _, err2 = run_git(["branch", "-d", branch], cwd=repo)
            if rc2 != 0:
                log(f"branch delete failed (non-fatal): {branch}: {err2.strip()}")


def render_text(results):
    lines = []
    t1, t2, t3 = results["tier1"], results["tier2"], results["tier3"]
    if not t1 and not t2 and not t3:
        print("[janitor] sweep clean — nothing to report", file=sys.stderr)
        return
    if t1:
        lines.append(f"## Tier 1 — safe to reap ({len(t1)})")
        for it in t1:
            lines.append(f"- {it['path']} [{it['branch'] or '(detached)'}] — {it['reason']}")
            for c in it["action"]["commands"]:
                lines.append(f"    $ {c}")
    if t2:
        total = sum(len(v) for v in t2.values())
        lines.append(f"\n## Tier 2 — owner investigates ({total})")
        for owner in sorted(t2):
            lines.append(f"### owner: {owner}")
            for it in t2[owner]:
                lines.append(f"- {it['path']} [{it['branch'] or '(detached)'}] — {it['reason']}")
                for c in it["action"]["commands"]:
                    lines.append(f"    $ {c}")
    if t3:
        lines.append(f"\n## Tier 3 — researcher residual ({len(t3)})")
        for it in t3:
            lines.append(f"- {it['path']} [{it['branch'] or '(detached)'}] — {it['reason']}")
            for c in it["action"]["commands"]:
                lines.append(f"    $ {c}")
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
    if args.dry_run and not args.reap_tier1:
        die("--dry-run only makes sense together with --reap-tier1")
    if args.owner_depth < 1:
        die("--owner-depth must be >= 1")
    if args.min_age_days < 0:
        die("--min-age-days must be >= 0")

    live = load_live_sessions()
    now_ts = int(time.time())
    results = {"tier1": [], "tier2": {}, "tier3": []}
    reap_plan = []

    for repo in args.repo:
        process_repo(repo, args, live, now_ts, results, reap_plan)

    if args.json:
        print(json.dumps(results, indent=2, sort_keys=True))
    else:
        render_text(results)

    if args.reap_tier1:
        do_reap(reap_plan, args.dry_run, args.default_branch)


if __name__ == "__main__":
    main()
