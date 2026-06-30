# 242 — log-experiment: the engineer bots do the author writes

## Problem

`log-experiment` does author push / PR-create / merge with the **ambient** credential (whoever runs it) and uses the engineer bot only for the *approval*. Anton prefers the **bots** do the writes: a consistent bot identity on the record, and — critically — it works for a fully autonomous agent that may have **no ambient write credential** at all (an agent shouldn't depend on a human's gh login to log its own experiment). The engineer bots already have `contents:write` on research-lab (verified by creating + deleting a throwaway ref with the bot token), so **no GitHub-App permission change is needed** — this is purely a code change.

## Approach

Mint the **author-family** engineer token alongside the opposite-family reviewer token, and use it for the **commit author, push, PR-create, and merge**. The **opposite-family** bot still posts the approving review, so cross-family independence is preserved and the author bot cannot approve its own PR. Fail closed if the author token can't be minted or can't reach the repo (same discipline as the reviewer token).

- **commit:** authored as the author-family bot (`LOG_EXPERIMENT_GIT_AUTHOR_<FAMILY>`).
- **push:** to a token-scoped `https://x-access-token:<author-token>@github.com/<repo>.git` remote (no ambient credential).
- **PR create + merge:** `GH_TOKEN=<author-token>`.
- **approve:** `GH_TOKEN=<reviewer-token>` (opposite family) — unchanged.

Config (instance, env): `LOG_EXPERIMENT_GIT_AUTHOR_CLAUDE` / `_CODEX` (the `Name <email>` for each bot's commits); the token itself comes from the existing `LOG_EXPERIMENT_TOKEN_CMD_<FAMILY>`.

## Alternatives considered

- **Keep ambient author writes** — rejected: Anton's preference, and it fails the autonomous-agent case (no human gh login).
- **Reviewer bot does the writes too** — rejected: the reviewer must stay the *opposite* family for independence; the author writes must be the *author* family.

## Blast radius

One script (`log-experiment.sh`) + its config docs (SKILL.md, this proposal). No other skill changes. Reversible (revert the PR → back to ambient writes). The bots already have write (verified), so no GitHub-App or branch-protection change. Risk: a missing author-token/identity config → fail closed before any mutation (no half-open PRs).

## Rollout + rollback

ship-change PR; then `log-experiment` writes go through the author bot identity. Set `LOG_EXPERIMENT_GIT_AUTHOR_CLAUDE/_CODEX` in the instance env. Rollback: revert the PR.
