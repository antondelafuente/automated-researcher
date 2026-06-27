# RUNBOOK — aar-engineering workflow operations

Operational record for the GitHub-backed scaffold-change lifecycle (`ship-change` / `wf.sh`): the **as-built
enforcement config** now in force, the **escape hatches** if the automation wedges (the load-bearing part),
and token rotation. Branch protection is a **repo-wide gate** — if the reviewer identity or a rule breaks it
can block EVERY merge — so the escape hatches matter as much as the config.

## What's enforced (as-built)

The repo is **public**, and branch protection on `main` is **active** with:

- **Require a pull request before merging.**
- **Require 1 approving review** — satisfied by a cross-family native engineer review (author identity ≠
  reviewer identity, so GitHub allows it). The driver posts `--code` as an Approve (clean) / Request-changes
  (findings); only `finish`'s final-SHA review approves.
- **Dismiss stale approvals when new commits are pushed** — an approval is bound to its reviewed SHA.
- **Require conversation resolution** — our reviews post as review *bodies* (not line threads), so nothing
  to resolve in practice; if it ever blocks a clean merge, drop just this rule (see escape hatches).
- **Block force pushes + block deletions** on `main`.
- **Include administrators (`enforce_admins`)** — **ON**. This is load-bearing: any ambient admin token used by
  the driver must still have an opposite-family approval to merge.

NOT enabled (deliberately): **required status checks**. The `.aar-ci` checks + behavior smoke run *driver-side*
in `finish` (before the approval), not as GitHub-reported statuses — so there's nothing for branch protection
to require yet. The classifier's `design-gate` is likewise **advisory** (recorded on the PR, not a required
check). Wiring either as a GitHub-required status is a tracked follow-up (needs a small GitHub Action).

## Engineer identities (as-built)

- **`codex-engineer`** — a GitHub App, installed on `automated-researcher`. It can author Codex work and review
  Claude-authored changes. This instance currently exposes its token through the legacy `WF_REVIEWER_TOKEN_CMD`
  seam, which `wf.sh` treats as a fallback alias for `WF_ENGINEER_TOKEN_CMD_CODEX`.
- **`claude-engineer`** — a GitHub App, installed on `automated-researcher` (its token seam `WF_ENGINEER_TOKEN_CMD_CLAUDE`
  + `WF_ENGINEER_GIT_AUTHOR_CLAUDE` are wired on this box). It authors Claude work and reviews Codex-authored
  changes — verified live: it posted the cross-family reviews on PR #57 and authored issue #62 (both read as
  `claude-code-engineer[bot]` / `app/claude-code-engineer`).
- **Permissions: `contents: write` + `pull_requests: write`.** ⚠️ **Gotcha (cost a round-trip):** an App's
  approval only **counts** toward "require approvals" if the App has **`contents: write`**. With
  `pull_requests: write` *alone* it can *post* a review, but it reads as `author_association: NONE` and the
  approval does **not** satisfy the gate (`reviewDecision: REVIEW_REQUIRED`). Grant `contents: write` and
  re-accept the installation's permission request.
- **`issues: read` — only for PRIVATE installs.** The close-gate (`finish` enforcing the two-phase close
  contract, #50/#85) reads each closing issue's disposition labels. On a **public** repo (like `automated-researcher`)
  this works under the existing `contents`+`pull_requests` perms — no change needed. A **private** install must
  add **`issues: read`** to both engineer Apps (+ re-accept), or the gate fails closed and blocks every merge.
- **`issues: write` — for `wf.sh issue` (agent-filed Issues, #89).** `wf.sh issue <fam> create|comment`
  authors Issues / issue-comments as the engineer App. Creating or commenting on an Issue needs the App to
  have **`issues: write`** (on private *and* public repos — unlike the read above). Without it the App can't
  open the Issue; `wf.sh` now fails closed by default instead of falling back to ambient/human auth. Grant
  `issues: write` to both engineer Apps (+ re-accept) when using `wf.sh issue`.
- **Instance wiring (not product):** each App's id + private key live on the instance under e.g.
  `~/.config/<family>-engineer/`. `WF_ENGINEER_TOKEN_CMD_CLAUDE` / `WF_ENGINEER_TOKEN_CMD_CODEX` mint fresh
  installation tokens per use (they expire ~1h); `WF_ENGINEER_GIT_AUTHOR_CLAUDE` /
  `WF_ENGINEER_GIT_AUTHOR_CODEX` provide `Name <email>` for strict commit attribution. `wf.sh` consumes only these
  seams — no App specifics in product code. Protected workflow mutations are strict by default: missing author
  or reviewer engineer identity now blocks without needing `WF_REQUIRE_ENGINEER_IDENTITY=1` or
  `WF_REQUIRE_NATIVE_REVIEW=1` (legacy/no-longer-needed). Use `wf.sh doctor <claude|codex> [repo-or-worktree]`
  to check ambient gh, author/reviewer token repo access, git-author wiring, and author-aware model reviewer readiness
  without printing token values.

## Model reviewer environment

`AUDIT_VERIFIER_CMD` is a model-family override, not a blanket workflow default. For Codex-authored changes it
must point at a Claude-family CLI, and `wf.sh doctor codex` / the review commands reject a Codex-family value
before starting the reviewer. For Claude-authored changes the default Codex verifier is the cross-family path;
`wf.sh` clears `BASH_ENV` for the audit subprocess and drops an inherited Claude-family `AUDIT_VERIFIER_CMD`,
logging a one-line note when it does so. This keeps instance-wide shell convenience from turning a
Claude-authored PR into a same-family Claude review.

## Ambient gh vs workflow identity

It is fine for agent shells to have ordinary `gh` access for reading Issues/PRs or for owner/admin
maintenance. That credential is not the workflow identity. `wf.sh` protected mutations that name an author
(`open`, reviews, `comment`, `issue`, `classify`, `finish`) use the family engineer App tokens by default and
fail closed if those seams are missing. An instance may source a small `gh.env`/`GH_TOKEN` for ambient CLI
convenience; it must still source the engineer-token env before ship-change workflow writes.

`WF_ALLOW_AMBIENT_IDENTITY=1` is the explicit escape hatch for a deliberate permissive workflow run on an
install without engineer Apps. When used, the driver emits a terminal warning and leaves a best-effort PR/Issue
trail when there is a natural target. Treat that warning like the close-gate override: acceptable for bootstrap
or rescue, not the normal path.

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
- **Revoke an engineer App.** Uninstalling / revoking an engineer App immediately stops it authoring/reviewing —
  the clean unwind for a compromised identity (combined with relaxing require-approvals so merges aren't trapped).

## Reviewer latency / debug policy

Claude-family reviews can be quiet while the model is working. On this fleet, treat 0-5 minutes as normal for
`wf.sh design-review`, `wf.sh code-review`, and the final review inside `wf.sh finish`: do not kill, retry, or
narrate concern during that window. Re-measure these thresholds for other installs; they are this fleet's
as-built operating policy, not a provider SLA.

At 5 minutes, inspect state once without interrupting the reviewer. For the default Claude verifier, check that
the verifier process is still alive; do not treat an empty log as a hang signal. For streaming verifier commands,
also check the run log, remembering that it is a shared driver/verifier log. At 10 minutes, treat the run as
suspicious unless there is concrete evidence of progress.

The underlying `verify-claims` engine writes through an internal temp file and atomically moves it to the final
findings path only after the verifier exits successfully. In `wf.sh`, that means the final review file
(`/tmp/wf_*.md`) can remain missing or empty until the full response completes; that alone is not evidence of a
hang.

## Token / identity rotation

- **`GH_TOKEN`** (author/driver auth). Rotate: mint a new fine-grained PAT (repo: contents + pull_requests),
  replace it wherever your environment provides `GH_TOKEN` *(this instance: `~/.env`, re-`source`)*. `wf.sh`
  sources no env file itself. This can be a small ambient-gh env for ordinary CLI use; it does not satisfy the
  engineer identity seams. NEVER print it; scrub from captured output (`sed "s/${GH_TOKEN}/***/g"`).
- **Engineer Apps** (author/reviewer identities). Rotate the App's private key in the App settings and replace
  the matching `~/.config/<family>-engineer/key.pem`; the minter picks it up. Revoking an App stops that
  identity immediately.

## One-command revert of a merged change

A shipped change is one squash commit on `main`. To undo:

```
git -C <repo> checkout main && git -C <repo> pull --ff-only
git -C <repo> revert <merge-commit-sha>        # creates a revert commit
# then ship the revert through the normal lifecycle (it's just another change).
```

If a plugin manifest changed, after a revert/merge refresh installed plugins:
`claude plugin marketplace update automated-researcher && claude plugin update <name>@automated-researcher`.

## Follow-ups (not yet built)

- **`.aar-ci` checks + `design-gate` as GitHub-required status checks** — a GitHub Action that runs the
  checks and reports a status, so branch protection can require them (today they're driver-side only).
