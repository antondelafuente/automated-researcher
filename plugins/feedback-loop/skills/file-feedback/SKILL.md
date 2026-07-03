---
name: file-feedback
description: File feedback about the automated-researcher scaffold while the friction is fresh. Use when an agent hits an operational footgun, notices tooling or docs friction, wants to file a product bug or idea, or reaches an experiment close retro. Product/user-facing feedback goes to the configured product Issue tracker; deployment-only notes are drafted and routed through the consuming instance's guidance.
---

# file-feedback - report scaffold friction

**You are the user, not the maintainer, right now — the two hats are separated in time, never worn at once**
(the maintainer pass is `triage-feedback`, triggered and single-writer). During an experiment or any other
product use, that means: run the canonical pipelines, file feedback here while the friction is fresh, and don't
take on the maintainer's broad work mid-run (redesigning, restructuring, non-trivial fixes) — a live run's job
is to finish, not to fix the scaffold it's running on. That does not narrow the **Fix-Now Path** below: a
mechanical, safe fix is still fixed immediately, mid-run or not. This skill captures friction so maintainers
can turn repeated pain into product fixes.

## Config

Run `scripts/feedback_loop_init.sh` once per user. It writes `~/.config/feedback-loop/env` with mode `0600`.

The config keys are:

- `FEEDBACK_PRODUCT_REPO`: required `OWNER/REPO` for product Issues.
- `FEEDBACK_INSTANCE_GUIDANCE`: optional path or URI for deployment-only feedback instructions.

Before filing, read the config if it exists:

```bash
set -a
. "$HOME/.config/feedback-loop/env"
set +a
```

If the config or `FEEDBACK_PRODUCT_REPO` is missing, do not guess a tracker. Draft the exact Issue or comment text and
tell the researcher to run `feedback_loop_init.sh` before direct filing.

## Route It

First decide whether an external adopter of `automated-researcher` would hit the same problem.

Product/user-facing feedback includes bugs, missing helpers, confusing docs, onboarding friction, and workflow defects
in the reusable scaffold. Search existing Issues first:

```bash
gh issue list -R "$FEEDBACK_PRODUCT_REPO" --state open --limit 100 --search "<terms>"
```

If an Issue exists, add a recurrence comment instead of duplicating it (check it's still live first — see
Etiquette). If not, file a new Issue with a type label
(`bug`, `enhancement`, `documentation`, or `onboarding`) and exactly one disposition label when the disposition is
clear (`ready`, `needs-shaping`, `blocked`, `parked`, or `other`). If you cannot judge disposition yet,
leave the disposition off rather than guessing. Read `references/DISPOSITIONS.md` for the label contract.

Use the engineer-safe authoring path when `aar-engineering` is available and the host is configured for it:

```bash
wf.sh issue <claude|codex> create -R "$FEEDBACK_PRODUCT_REPO" -t "<title>" -b "<body>" -l <type> -l <disposition>
wf.sh issue <claude|codex> comment <issue-number> -R "$FEEDBACK_PRODUCT_REPO" -b "<body>"
```

Always pass `-R "$FEEDBACK_PRODUCT_REPO"`. Never substitute raw `gh issue create` for product feedback: it may post as
the repository owner instead of the agent engineer identity. If `wf.sh issue` is unavailable or unconfigured, draft the
exact title, body, labels, and recurrence comment for a human or configured maintainer to submit.

Deployment-only feedback is local to the consuming instance: a lab path, account quirk, local runner, deployment
changelog, private pipeline, or coordination convention that an outside adopter would not share. Do not write to
hardcoded local files. Draft the note and route it through `FEEDBACK_INSTANCE_GUIDANCE` when configured; if the key is
unset, say the instance guidance is missing and include the draft in your response or handoff.

Use these generic draft shapes:

Incident:

```markdown
### <short title> (<date>)

symptom:
cause:
fix/workaround:
cost:
```

Idea:

```markdown
### <short title> (<date>)

what:
why:
take:
next step:
```

## Fix-Now Path

If the fix is mechanical and safe, fix the canonical home immediately.

Product scaffold fixes go through the `ship-change` workflow. Instance-only files follow the consuming instance's
guidance. Do not change methods, frozen experiment parameters, cost materially, or the autonomy boundary without the
researcher's clearance.

## Etiquette

- Search/read first so recurrence is recorded on the existing item when possible.
- One root cause per entry.
- Keep product facts in product Issues and deployment facts in the consuming instance.
- Prefer code or a checklist gate over prose when a recurring footgun can be prevented mechanically.
- Before posting an addendum or scope-change comment on an existing issue, check its state and whether an
  implementing PR/branch is already in flight (`gh issue view <N> -R "$FEEDBACK_PRODUCT_REPO" --json
  state,closed` / `gh pr list -R "$FEEDBACK_PRODUCT_REPO" --search "<N>" --state open`) — on a deployment with
  fast auto-implementation the tracker is a queue, not a notebook, and a `ready` issue can close within the
  hour. If it is closed or in flight, file a new small ticket linking the old one instead: a comment there is
  a dead letter the implementor never sees. Shaping comments on an open `needs-shaping` issue remain the
  intended flow.
