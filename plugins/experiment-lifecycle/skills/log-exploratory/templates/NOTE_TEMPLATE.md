# NOTE — <name>  (<one-line what this note is about>)

> **Exploratory provenance:** <one interactive run / N exploratory analyses, post-hoc logged>; no
> design-audit, no close-audit; numbers are exploratory by construction. If this needs to
> become load-bearing for a claim, design the audited version through `design-experiment`/`run-experiment`
> instead of citing this note as if it were one.

## Question

<What you were trying to find out, in one or two sentences.>

## Methods

<Exact models/configs used. Name the judge (if any) and its exact prompt/config. Sha-pin any pinned
instrument you used unchanged (a frozen judge prompt, a specific script, a specific checkpoint) — same
precision bar as an audited experiment, even though the scope and audit depth are lighter.>

## Results

<Tables (or a plot) — not a scalar buried in prose. A lightweight qualitative read is fine if it's clearly
marked as a read, not a verdict, and stays separable from the numbers themselves.>

## Caveats

<What would make this number wrong or non-comparable. What wasn't checked because this was the fast lane,
not the audited pipeline — say so plainly rather than implying more rigor than this record has.>

## Artifacts

<Where the raw data actually lives — an R2/artifact-store path, plus what's committed alongside this note
(figures, small derived CSVs) vs. what stays in the store (raw JSONL, full logs). A MANIFEST of store paths,
not a copied/hardlinked second tree: one artifact, one object in the store.>

**scratch:** <the exploratory work dir this note is ACCOUNTABLE for — `<EXPERIMENT_SCRATCH_ROOT>/<name>`,
which the landing reaps (archive → verify → delete) — or `none` if nothing was staged on the box. This is a
commit-time DECLARATION, not the reap's outcome: the reap runs *after* this file is merged, because the
merge is the clean-close evidence it gates on, so its `bytes=`/gap figure cannot exist yet when you write
this and belongs on the landing report instead (`log-experiment`'s `[scratch: …]` line — the note path's
close report, exactly where an audited close puts its own `SCRATCH-REAP-RECLAIMED:` line). What the
declaration buys is auditability with no guessing: the dir named here is the one the landing must have
reclaimed, so residue on the box is attributable to this note and a note that declares nothing is visibly
unfinished. Never blank, and never a number you didn't read.>
