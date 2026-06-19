# Proposal: harden the wf.sh issue flag allowlist (#91)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

`wf.sh issue <fam> create|comment` (#89) allowlists the **subcommand** but forwards the rest of the args to
`gh issue` unchecked. Under the engineer token, that still permits destructive/interactive operations the
wrapper claims to block: `gh issue comment <N> --delete-last --yes` (deletes a comment), `--edit-last`
(edits one), and `create|comment --web` (browser/interactive auth). Flagged MED [security] on the final
`--code` review of PR #90 (landed non-blocking).

## Approach

**Contract:** the authoring path accepts only non-interactive title/body/label inputs. Enforce it with a
flag **allowlist**, not a denylist: permit `-R/--repo -t/--title -b/--body -F/--body-file -l/--label
-a/--assignee -m/--milestone -p/--project` and reject every other `-`-prefixed arg. A denylist is
whack-a-mole — it misses short forms (`-w`, `-e`), `=value` forms (`--web=true`), bundles (`-we`), and any
future interactive flag; an allowlist **fails closed on all of them at once**. `=value` is stripped before
matching; non-flag args (the issue number, flag values) pass through; a flag that's valid for `gh` but
wrong for the chosen subcommand just fails at `gh`, harmlessly. A *missing* `-b/-t` makes `gh` prompt, which
fails closed on this no-tty exec path — a usage error, not an action.

## Alternatives considered

- **Flag denylist** (first two attempts: reject `--web/--delete-last/--edit-last`, then add `-w/-e`).
  Rejected on review: leaky — review found `--web=true`/`-we`-bundle bypasses, and it can never cover future
  interactive flags. An allowlist fails closed on all of them; denying is the wrong default for a privileged
  wrapper.
- **Require `-b/--body` and forbid everything else.** Rejected: over-strict — breaks benign flags
  (`-a/--assignee`, `-m/--milestone`, `--body-file -`). The allowlist permits the safe authoring flags and
  rejects the rest, which is the right middle.
- **Leave it (token scope limits blast radius).** Rejected: the wrapper advertises create/comment authoring;
  letting an interactive/destructive flag through under the bot token contradicts that, and a typo shouldn't delete.

## Blast radius

- One hunk in `wf.sh`'s `issue` arm + the `aar-engineering` `plugin.json` version bump. Additive guard; no
  other code path. `gh-as-engineer` (which now delegates here) inherits the protection for free.

## Rollout + rollback

- Pure guard; rollback is deleting the denylist check. No state, no migration.
