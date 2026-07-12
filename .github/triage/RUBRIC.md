# Triage rubric (v2)

Read from this repo's base ref by `triage-assess.yml` (automated-researcher#437 — the "Triager, v1" stage of
the design synthesized on #414). Applied identically by both blind assessors (Fable, Sol) and by the sighted
adjudication pass. Researcher-locked as-is on 2026-07-12 — edit only on the back of an actual researcher
conversation, same norm as a `needs-design -> ready` disposition flip (AGENTS.md).

## The three questions

1. **What does the failure cost, at ~10-agent concurrent scale?** The scale principle (AGENTS.md,
   researcher-stated, quoted verbatim): "~10 concurrent agents, a handful of researchers; robustness is
   priced at that scale; rarity alone never kills a fix, cost does; trust gates stay fail-closed." Validity
   failures (a confidently-wrong research result) outrank money, which outranks researcher-attention-minutes.
2. **Does it serve the product for any researcher, not just the current project?** An instance-specific
   workaround, or a fix scoped to one in-flight experiment with no generalizable product change, does not
   clear this bar on its own.
3. **What does the fix cost — latency, dollars, complexity?** Weigh against (1) and (2): a cheap fix for a
   real, generally-applicable failure is DO even when rare; an expensive fix for a narrow, one-off cost is
   SKIP or ASK.

## Verdicts

- **DO** — clears all three questions; safe to shape into a `ready` ticket.
- **SKIP** — fails the cost/benefit weighing (rare + expensive, superseded by other work, or doesn't serve
  the general product).
- **ASK** — a genuine product-shape or policy decision that only the human can make; not a shaping gap the
  ticket itself can resolve by rewriting scope.

## Known split pattern (2026-07-11 dry run, 69% raw blind-agreement across 52 tickets)

One rubric clause resolved roughly a third of the observed disagreements: **a diagnosed fix with a proven
workaround is mechanical even when spend-adjacent; escalate only if the fix itself sets policy.** Apply this
before defaulting a cost-adjacent ticket to ASK — the split was systematic (one model over-escalating
spend-adjacent tickets as policy), not noise.

## Wave batching (file-disjoint rule, from #431's root cause)

For DO verdicts, the sighted adjudication additionally proposes a wave grouping: diff the candidate tickets'
expected file footprints (the ticket usually names the skill/script it touches) and serialize any tickets
that would land on the same file; file-disjoint tickets may batch into the same wave. A conflicted PR
produces *no* workflow run at all (GitHub can't build the merge ref while a PR conflicts with base), so
flipping same-file siblings concurrently doesn't just cost a conflict-resolution round — it silences the
pipeline for every sibling still open when one merges. This is the primary prevention rule, not a
nice-to-have.
