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
(figures, small derived CSVs) vs. what stays in the store (raw JSONL, full logs).>
