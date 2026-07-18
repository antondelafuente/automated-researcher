---
name: log-exploratory
description: >-
  Run a quick, interactive, exploratory analysis and still get it a durable, citable registry record — the
  middle path between "just run it in chat" and the full design-experiment/run-experiment pipeline. A recipe,
  not new machinery: work in a dedicated dir, write `registry/<name>/NOTE.md` from the pinned skeleton
  (question, one-line exploratory-provenance note, exact methods/models/judge, results, honest caveats,
  artifact pointers), land it via `log-experiment` (classifies as a **note** — secret-scan gate, cross-family
  bot approve, merge), and optionally build a curated dashboard page. States the escalation boundary: a
  note's numbers are exploratory by construction, and the moment one becomes load-bearing for a claim, that
  is the trigger to design the audited version through `design-experiment`/`run-experiment` instead. Use when
  asked to "run this quick/exploratory and log it," "log this as a note," "quick experiment, no full
  pipeline," or post-hoc "we should log what we just did."
---

# log-exploratory — the quick-experiment-to-registry-note recipe

The researcher repeatedly wants a **middle path**: a quick interactive experiment that still gets a durable,
citable registry record, without paying for the full `design-experiment`/`run-experiment` pipeline (design
clearance, design-audit, close-audit, CHECKLIST). This skill owns that recipe so an agent that hasn't seen
the precedents doesn't re-derive (and probably weaken) it each time. It is a **recipe**, not new machinery —
every landing/gating mechanism it uses already exists in `log-experiment`.

**Two worked references this recipe is drawn from** (both in `antondelafuente/research-lab`):
- `registry/csp1-icl-probe-1` (PR #346) — an interactive ICL probe, logged as a note.
- `registry/csp1-hot32-surface-contrast-1` (PRs #359/#362, dashboard #360) — two exploratory analyses, logged
  as a note with figures + a curated dashboard page.

## When to use

- "Run this quick/exploratory and log it."
- "Log this as a note."
- "Quick experiment, no full pipeline."
- Post-hoc: "we should log what we just did" — you already ran something interactively and want a record now.

If instead the number needs to survive as evidence for a claim (comparability guarantees, an audited
verdict), don't reach for this — go to `design-experiment` (see the escalation boundary below).

## The recipe

### 1. Run discipline

Work in a dedicated directory (e.g. `~/work/<name>/`, or your instance's equivalent scratch convention) —
not loose in the conversation. Prefer resumable scripts (re-runnable, checkpointed) over one-shot inline
commands so a slow step doesn't have to be redone from scratch. Write results to files **as you go** — raw
text (rollouts, tool output, large tables) stays out of the conversation and lands in artifacts instead, the
same discipline `run-experiment`'s "read full samples" rule assumes.

### 2. The record — `registry/<name>/NOTE.md`

Write `registry/<name>/NOTE.md` from the pinned skeleton in `templates/NOTE_TEMPLATE.md`:

- **Question** — what you were trying to find out.
- **Exploratory-provenance note** — one line, up front, stating this is a quick/exploratory pass, not an
  audited experiment (see the escalation boundary below — this is the honesty mechanism that keeps the fast
  lane from silently substituting for the audited one).
- **Methods** — the exact models/configs/judge used. **Sha-pin any pinned instrument** (a judge prompt, a
  frozen script, a specific checkpoint) the same way an audited experiment would — informality about scope
  and audit depth doesn't excuse imprecision about what was actually run.
- **Results** — tables (or a plot), not a scalar buried in prose. May include a lightweight qualitative read,
  same posture as `design-experiment`'s RESULTS discipline — describe the data, don't smuggle in a
  pre-registered verdict.
- **Honest caveats** — what would make this number wrong or non-comparable; what wasn't checked because this
  was the fast lane, not the audited one.
- **Artifact pointers** — where the raw data actually lives.

**What lands where:** figures and small derived CSVs commit **next to** `NOTE.md` in the registry dir; raw
JSONL (rollouts, full logs) goes to the artifact store under the record's name — the same R2 convention
`run-experiment`'s close step uses (`ARTIFACT_MANIFEST.md`-style pointer if there's enough heavy artifact to
warrant one; for a small note this is often just a link).

### 3. Land it — `log-experiment`

Invoke the **`log-experiment` skill** on the dir (`registry/<name>` as its input) — it resolves its own
`scripts/log-experiment.sh` path per its own SKILL.md; never call `log-experiment.sh` directly as if it were
on PATH. A dir with neither `DESIGN.md` nor `RESULTS.md` classifies as a **note** — the deterministic secret
scan is the only gate, then cross-family bot approval and merge. No new landing machinery, no audit to run
first — this is exactly why the recipe is cheap.

### 4. Optional viewer leg — a curated dashboard page

If the note is worth a browsable page (it has figures or a story worth showing), build one via the
instance's `[recipes.viewer]` — route it per the existing `update-dashboard`/`update-site` split (dashboard =
per-record operational page; site = cross-record editorial story). Notes are gallery-visible (research-lab
#360): a note's **first** page build is legitimate to do directly (unlike `update-dashboard`'s normal
edit-only precondition, which assumes a page already exists from a prior `run-experiment` close — a note has
no such prior close, so building its first page here is not a violation of that precondition, it's the
correct place for it). This leg stays manual — it is never automated by this skill.

### 5. The escalation boundary (load-bearing)

A note's numbers are **exploratory by construction** — a single pass, no design-audit, no close-audit. State
this in the note itself (the exploratory-provenance line above), so nobody downstream mistakes it for an
audited result. **The moment a note's number needs to become load-bearing for a claim** — cited as evidence,
compared against another arm to support a conclusion, or built on by future work — that is the trigger to
design the audited version through `design-experiment`/`run-experiment`, not to keep treating the note as if
it were one. This skill's fast lane never silently substitutes for the audited pipeline.

## Out of scope

- No new gates, no audit machinery for notes — the secret scan `log-experiment` already runs for any note is
  the only gate.
- No changes to `log-experiment`'s classifier — a `NOTE.md`-bearing dir with no `DESIGN.md`/`RESULTS.md`
  already classifies as a note today.
- No automation of the dashboard leg — it stays a manual, optional step (item 4 above).

## Composes

- **`log-experiment`** — lands the note as a gated PR (the note path: secret scan → cross-family bot approve
  → merge). Invoke it; don't hand-roll branch/PR/approve/merge.
- **`design-experiment`** / **`run-experiment`** — the audited pipeline this recipe is deliberately below the
  threshold of; escalate to them once a note's number needs to carry claim-level weight (Step 5).
- **`update-dashboard`** / **`update-site`** — the optional viewer leg (Step 4).

## Reference

- **`templates/NOTE_TEMPLATE.md`** — the pinned `NOTE.md` skeleton.
- Worked references: `registry/csp1-icl-probe-1` (PR #346); `registry/csp1-hot32-surface-contrast-1` (PRs
  #359/#362, dashboard #360) — both in `antondelafuente/research-lab`.
