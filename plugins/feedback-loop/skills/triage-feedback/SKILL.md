---
name: triage-feedback
description: Run an explicit maintainer pass over automated-researcher feedback. Use when asked to triage product feedback, maintain Issue dispositions, group duplicate reports, route fixes through ship-change, or summarize deployment-only feedback from the consuming instance guidance. Never run automatically.
---

# triage-feedback - maintainer pass

**You are switching hats from product user to maintainer — the two hats are separated in time, never worn at
once** (see `file-feedback` for the user hat). Run this only when explicitly asked (researcher-triggered,
single-writer — no other maintainer pass runs concurrently); a maintainer pass can edit shared tracker state and
route fixes.

## Config

Run `scripts/feedback_loop_init.sh` once per user. It writes `~/.config/feedback-loop/env` with mode `0600`.

Read:

- `~/.config/feedback-loop/env`
- `references/DISPOSITIONS.md`
- `FEEDBACK_INSTANCE_GUIDANCE`, when configured

`FEEDBACK_PRODUCT_REPO` is required for product Issue triage. If it is missing, stop and ask for
`feedback_loop_init.sh` to be run, or draft the maintainer plan without changing tracker state.

Instance guidance should answer four local questions: where incident notes go, where idea/backlog notes go, how local
entries are archived or closed, and how to coordinate before touching live-owned local files or helpers. If the pointer
is absent or incomplete, say what local decision is missing instead of naming this deployment's paths.

## Product Issue Pass

List open Issues:

```bash
gh issue list -R "$FEEDBACK_PRODUCT_REPO" --state open --limit 100
```

Maintain the disposition invariant from `references/DISPOSITIONS.md`: every open Issue is either unlabeled/untriaged or
has exactly one disposition label. Backfill unlabeled Issues only when the disposition is clear; fix Issues with two or
more disposition labels to one.

Classify feedback:

- `ready`: actionable now, no unresolved design.
- unlabeled: default resting state — untriaged, or too vague to start; stays unlabeled until flipped.
- `blocked`: gated on a prerequisite; include `blocked-by: #N`.
- `parked`: real but not now.
- `other`: taxonomy gap.

**Make every tracker mutation through the engineer verbs, never a bare `gh`.** When `aar-engineering` /
`ship-change` is available, comments, label edits, closes, and disposition body lines all go through the
engineer-identity path so they author as the bot, not the human owner:

```bash
wf.sh issue <family> comment <N> -R "$FEEDBACK_PRODUCT_REPO" -b "<body>"
wf.sh issue <family> label   <N> -R "$FEEDBACK_PRODUCT_REPO" --add-label <disposition> [--remove-label <old>]
wf.sh issue <family> close   <N> -R "$FEEDBACK_PRODUCT_REPO" [-c "<comment>"] [-r "not planned"]
wf.sh issue <family> dispose <N> -R "$FEEDBACK_PRODUCT_REPO" --label blocked --body-line "blocked-by: #<M>"
```

Group duplicates by commenting on the canonical Issue and closing the duplicate as a native duplicate:
`wf.sh issue <family> close <N> -R … -r duplicate --duplicate-of <canonical>` (optionally with a `-c` comment).
`dispose` is the atomic `blocked` path — it sets the `blocked` label *and* the `blocked-by: #N` body line in one
engineer-authored call (re-running with the same `blocked-by:` key replaces that line, never duplicates). These
verbs accept only their fixed flags; there is no arbitrary `gh` passthrough.

**Degradation when `aar-engineering` is absent.** If the engineer verbs are not available, do **not** fall back to
a bare owner `gh` write. Instead **draft** the mutation (the exact comment / label / close / body-line change) for
the human/owner to apply — the same way fix routing degrades to a drafted plan. The owner-write path the #149 guard
closes is never re-opened.

## Routing Fixes

For product-scaffold fixes, use `ship-change`. If `aar-engineering` / `ship-change` is absent, maintain Issues and
summarize the plan, but do not invent a merge path. Draft the ready issue/PR plan and state that `aar-engineering` must
be installed or configured to ship the fix.

For deployment-only feedback, follow `FEEDBACK_INSTANCE_GUIDANCE`. The product skill does not prescribe local buckets,
archive markers, file names, or coordination tools.

Checklist promotion is split by genericity:

- recurring generic validity gates become product `experiment-lifecycle` checklist changes through `ship-change`;
- deployment-specific gates stay in the consuming instance's guidance.

## Output

Lead with a short prioritized triage:

- product fixes to ship now;
- items needing design or shaping;
- deployment-only items and where the instance guidance routes them;
- parked or stale items with reasons.

Then implement the approved straightforward product fixes through `ship-change`, or stop with the exact blocker when
the required product workflow is not installed/configured.
