# RUNBOOK — aar-engineering workflow operations

Operational record for the GitHub-backed scaffold-change lifecycle (`ship-change` / `wf.sh`): the **as-built
enforcement config** now in force, the **escape hatches** if the automation wedges (the load-bearing part),
and token rotation. Branch protection is a **repo-wide gate** — if the reviewer identity or a rule breaks it
can block EVERY merge — so the escape hatches matter as much as the config.

## What's enforced (as-built)

The repo is **public**, and branch protection on `main` is **active** with:

- **Require a pull request before merging.**
- **Require 1 approving review** — satisfied by the cross-family **`codex-engineer[bot]`** native review
  (author ≠ reviewer identity, so GitHub allows it). The driver posts `--code` as an Approve (clean) /
  Request-changes (findings); only `finish`'s final-SHA review approves.
- **Dismiss stale approvals when new commits are pushed** — an approval is bound to its reviewed SHA.
- **Require conversation resolution** — our reviews post as review *bodies* (not line threads), so nothing
  to resolve in practice; if it ever blocks a clean merge, drop just this rule (see escape hatches).
- **Block force pushes + block deletions** on `main`.
- **Include administrators (`enforce_admins`)** — **ON**. This is load-bearing: the agent *authors* under the
  PM's `GH_TOKEN`, which is a repo admin; without this the admin token would bypass the whole gate. With it
  on, even the admin must have the bot's approval to merge.

NOT enabled (deliberately): **required status checks**. The `.aar-ci` checks + behavior smoke run *driver-side*
in `finish` (before the approval), not as GitHub-reported statuses — so there's nothing for branch protection
to require yet. The classifier's `design-gate` is likewise **advisory** (recorded on the PR, not a required
check). Wiring either as a GitHub-required status is a tracked follow-up (needs a small GitHub Action).

## The reviewer identity (as-built)

- **`codex-engineer`** — a GitHub App, installed on `aar-skills`. It reviews **Claude-authored** changes
  (the only wired direction; `author=codex` is blocked upstream until a `claude-engineer` reviewer + the
  reverse review path are built).
- **Permissions: `contents: write` + `pull_requests: write`.** ⚠️ **Gotcha (cost a round-trip):** an App's
  approval only **counts** toward "require approvals" if the App has **`contents: write`**. With
  `pull_requests: write` *alone* it can *post* a review, but it reads as `author_association: NONE` and the
  approval does **not** satisfy the gate (`reviewDecision: REVIEW_REQUIRED`). Grant `contents: write` and
  re-accept the installation's permission request.
- **Instance wiring (not product):** the App's id + private key live on the instance under
  `~/.config/codex-engineer/`; `WF_REVIEWER_TOKEN_CMD` (in the instance env) mints a fresh installation token
  per use (they expire ~1h). `wf.sh` consumes only that seam — no App specifics in product code.

## Escape hatches (when the automation wedges)

Because `enforce_admins` is ON, there is **no standing admin merge-bypass** — that's intentional (the agent
shouldn't be able to bypass its own gate). Instead the owner edits the rule:

- **Disable a rule fast.** Repo → Settings → Branches → the `main` rule → uncheck the offending requirement
  (e.g. require-approvals, or conversation-resolution) → Save. Or via API:
  `gh api -X PUT repos/<owner>/<repo>/branches/main/protection --input <relaxed.json>`. Merges flow again;
  re-tighten once fixed. (Editing protection settings is available to the repo owner/admin even with
  `enforce_admins` ON — that only gates push/merge to the branch, not the settings API.)
- **Remove branch protection entirely (nuclear).** `gh api -X DELETE repos/<owner>/<repo>/branches/main/protection`.
  The repo reverts to driver-side-gate-only behavior. Fully reversible — re-PUT the rule to restore.
- **Revoke the reviewer App.** Uninstalling / revoking `codex-engineer` immediately stops it approving — the
  clean unwind for a compromised reviewer identity (combined with relaxing require-approvals so merges aren't
  trapped).

## Token / identity rotation

- **`GH_TOKEN`** (author/driver auth; this instance: `~/.env`). Rotate: mint a new fine-grained PAT (repo:
  contents + pull_requests), replace in `~/.env`, re-`source`. `wf.sh` sources no env file itself. NEVER print
  it; scrub from captured output (`sed "s/${GH_TOKEN}/***/g"`).
- **`codex-engineer` App** (reviewer identity). Rotate the App's private key in the App settings and replace
  `~/.config/codex-engineer/key.pem`; the minter picks it up. Revoking the App stops approvals immediately.

## One-command revert of a merged change

A shipped change is one squash commit on `main`. To undo:

```
git -C <repo> checkout main && git -C <repo> pull --ff-only
git -C <repo> revert <merge-commit-sha>        # creates a revert commit
# then ship the revert through the normal lifecycle (it's just another change).
```

If a plugin manifest changed, after a revert/merge refresh installed plugins:
`claude plugin marketplace update aar-skills && claude plugin update <name>@aar-skills`.

## Follow-ups (not yet built)

- **`claude-engineer` App + reverse review path** — to let Codex *author* changes that Claude reviews.
- **`.aar-ci` checks + `design-gate` as GitHub-required status checks** — a GitHub Action that runs the
  checks and reports a status, so branch protection can require them (today they're driver-side only).
