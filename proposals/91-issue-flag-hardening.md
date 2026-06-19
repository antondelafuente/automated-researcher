# Proposal: harden the wf.sh issue flag allowlist (#91)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

`wf.sh issue <fam> create|comment` (#89) allowlists the **subcommand** but forwards the rest of the args to
`gh issue` unchecked. Under the engineer token, that still permits destructive/interactive operations the
wrapper claims to block: `gh issue comment <N> --delete-last --yes` (deletes a comment), `--edit-last`
(edits one), and `create|comment --web` (browser/interactive auth). Flagged MED [security] on the final
`--code` review of PR #90 (landed non-blocking).

## Approach

Add a **flag denylist** to the `issue` arm, applied to the full arg vector after the subcommand allowlist:
reject `--delete-last`, `--edit-last`, and `--web` anywhere in the args, failing closed with a clear
message. These are the interactive/destructive flags `gh issue create|comment` expose; the authoring path
only needs non-interactive body/title/label flags, so denying these costs nothing legitimate. Keeping it a
targeted denylist (not a full positive parse of every allowed flag) matches the actual risk without making
the wrapper brittle to benign `gh` flag additions.

## Alternatives considered

- **Strict positive parse** — require `-b/--body`/`--body-file` and forbid everything else. Rejected:
  brittle (breaks on every benign `gh` flag, e.g. `-a/--assignee`, `-m/--milestone`, `--body-file -`) for
  no extra safety over denying the known-dangerous flags.
- **Leave it (token scope limits blast radius).** Rejected: the wrapper advertises create/comment-only;
  letting `--delete-last` through under the bot token contradicts that, and a typo shouldn't delete.

## Blast radius

- One hunk in `wf.sh`'s `issue` arm + the `aar-engineering` `plugin.json` version bump. Additive guard; no
  other code path. `gh-as-engineer` (which now delegates here) inherits the protection for free.

## Rollout + rollback

- Pure guard; rollback is deleting the denylist check. No state, no migration.
