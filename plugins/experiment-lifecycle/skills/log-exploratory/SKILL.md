---
name: log-exploratory
description: >-
  Run a quick, interactive, exploratory analysis and still get it a durable, citable registry record — the
  middle path between "just run it in chat" and the full design-experiment/run-experiment pipeline. A recipe,
  not new machinery: work in a dedicated dir, write `registry/<name>/NOTE.md` from the pinned skeleton
  (question, one-line exploratory-provenance note, exact methods/models/judge, results, honest caveats,
  artifact pointers), land it via `log-experiment` (classifies as a **note** — secret-scan gate, cross-family
  bot approve, merge), and optionally build a curated dashboard page. The landing IS the close: it archives,
  verifies and removes the work dir — the note declares which work dir it is accountable for, the landing
  report carries the reclaimed bytes — plus the artifact-staging
  rule that keeps remote artifacts (checkpoints, adapters) from hopping through the box at all. States the
  escalation boundary: a
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

Work in a dedicated directory **named exactly for the record you will land** — `<EXPERIMENT_SCRATCH_ROOT>/<name>`
(e.g. `~/work/<name>/`, your instance's scratch convention), where `<name>` is the `registry/<name>` you will
write `NOTE.md` into. The name is the *only* binding between the work dir and the record, and it is what
Step 3's close-time reap derives its delete target from; a differently-named dir is not reaped, and a dir
named only in `NOTE.md`'s prose is never reaped (a document-supplied delete target is exactly what the
reaper refuses). Don't work loose in the conversation. Prefer resumable scripts (re-runnable, checkpointed)
over one-shot inline commands so a slow step doesn't have to be redone from scratch. Write results to files
**as you go** — raw text (rollouts, tool output, large tables) stays out of the conversation and lands in
artifacts instead, the same discipline `run-experiment`'s "read full samples" rule assumes.

**Artifacts don't hop through the box** (automated-researcher#857). The fast lane is now the lab's volume
path, and the measured failure is not sloppiness — it's a staging habit:

- **An artifact produced elsewhere goes producer → store, directly.** A pod's or Tinker's output is uploaded
  from where it was produced; the work dir holds **pointers**, not a second copy. A "LoRA target census"
  across six explores pulled 41.5 GB of adapter tars onto the box that were *already* on R2, hardlinked them
  into an `archive/` tree, and uploaded them a second time (104 objects for 50 unique tars).
- **To read something *about* a remote artifact, read it from the stream.** A checkpoint census needs the tar
  member list, not the tar: `scripts/stream_tar_census.sh <url>` (or `tarfile` over an HTTP response, or
  `curl … | tar -t`) yields the member names without the archive ever touching this disk. Never
  `urlretrieve` an archive to read its headers.
- **Anything over ~1 GB written under the work dir is either on its way to the store or deleted by the same
  script that wrote it.** If neither is true, it is residue by construction.
- **Archive by manifest, not by copy.** When you record where a run's artifacts live, write a manifest of
  **store paths** — never a hardlinked/copied second tree, which costs a second upload and makes the store
  hold two objects for one artifact.

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
- **`scratch:`** — the work dir this note is accountable for (`<EXPERIMENT_SCRATCH_ROOT>/<name>`), or `none`.
  A **declaration** you can write now, not the reap's outcome, which does not exist until after this file is
  merged (Step 3 explains why, and where the outcome goes instead).

**What lands where:** figures and small derived CSVs commit **next to** `NOTE.md` in the registry dir; raw
JSONL (rollouts, full logs) goes to the artifact store under the record's name — the same R2 convention
`run-experiment`'s close step uses (`ARTIFACT_MANIFEST.md`-style pointer if there's enough heavy artifact to
warrant one; for a small note this is often just a link).

### 3. Land it — `log-experiment`. **The landing IS the close.**

Invoke the **`log-experiment` skill** on the dir (`registry/<name>` as its input) — it resolves its own
`scripts/log-experiment.sh` path per its own SKILL.md; never call `log-experiment.sh` directly as if it were
on PATH. A dir with neither `DESIGN.md` nor `RESULTS.md` classifies as a **note** — the deterministic secret
scan is the only gate, then cross-family bot approval and merge. No new landing machinery, no audit to run
first — this is exactly why the recipe is cheap.

**That merge is also this recipe's close.** An audited experiment has a close leg that archives and removes
its scratch; a note has no such leg, so `log-experiment` performs it at the merge itself: for `KIND=note` it
derives `<EXPERIMENT_SCRATCH_ROOT>/<name>` and, when that dir exists, hands it to `run-experiment`'s
`reap_scratch.sh` — which archives it to the artifact store, **verifies** the archive, deletes the local
copy, and prints one `SCRATCH-REAP-RECLAIMED:` line. Nothing is deleted that is not verifiably durable, and
the reaper re-checks that your `NOTE.md` really is merged at `origin/<base>` before it touches anything: an
in-flight explore's work dir is forensics, not residue. You do not invoke it — you **read its outcome**,
which `log-experiment` restates on its final `OK:` line as `[scratch: …]`.

**The note DECLARES its scratch; the landing REPORTS the reap.** These are two different records because
they are true at two different moments, and the note cannot carry the second one: the reap's clean-close
evidence *is* this merge, so by the time a `bytes=` figure exists the `NOTE.md` that would have to carry it
is already merged and immutable. Anything written on that line beforehand would be a placeholder or a
guess. So the split is the same one an audited close already uses — `run-experiment`'s reap also runs after
`log-experiment` has merged the record, and its `SCRATCH-REAP-RECLAIMED:` line goes **on the close report**,
not into the merged record. The landing report *is* the note path's close report. Concretely:

- **In `NOTE.md` (Step 2), before the landing:** `scratch: <EXPERIMENT_SCRATCH_ROOT>/<name>` — or `none`.
  Commit-time truth, and the thing that makes the reap auditable at all: it names the dir the landing must
  have reclaimed, so leftover bytes on the box are attributable to this note.
- **On the landing report, after the merge:** the `[scratch: …]` outcome. Route/keep it the way you would an
  audited close's close report; if the outcome is a gap or a failure it is also **your next action**, below.

| `[scratch: …]` | what happened | what you do |
|---|---|---|
| `SCRATCH-REAP-RECLAIMED: … bytes=N …` | archived, verified, deleted | nothing — the dir the note declared is gone; keep the line with the landing report |
| `none` | no work dir at `<root>/<name>` | nothing — this should be the note that declared `scratch: none`; if it declared a dir, the name doesn't match and the residue is still out there |
| `not-wired` / `SCRATCH-REAP-GAP: …` | a seam is unset, so nothing was archived **and nothing deleted** | the dir is exactly where it was: get the instance seam wired, then re-reap by hand |
| `reap-FAILED` / `reaper-not-found` | the record is merged and durable; the **work dir is still on disk** | re-run the reap by hand once the printed cause is fixed |

A note with no `scratch:` line is **visibly unfinished** — that is the whole point of putting it in the
skeleton, and unlike a bytes figure it is a line you can actually fill honestly before you land. Because the
record is already merged by the time the reap runs, a bad reap outcome never fails the landing; it is
reported, not swallowed.

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
  the only gate. **Close hygiene is not a gate** (automated-researcher#857): Step 3's scratch reap is
  deterministic mechanical hygiene, the same class as that secret scan — no judgment, no LLM, nothing to
  adversarially review. It also cannot block: it runs *after* the merge, so its outcome is reported on the
  landing report, never enforced against the landing (and never back-written into the merged note — see the
  declare/report split in Step 3). What it does have is a fail-closed *delete* guard — it archives and
  verifies before removing anything, and refuses outright if it can't.
- No changes to `log-experiment`'s classifier — a `NOTE.md`-bearing dir with no `DESIGN.md`/`RESULTS.md`
  already classifies as a note today.
- No automation of the dashboard leg — it stays a manual, optional step (item 4 above).
- No eviction backstop and no disk quotas. This recipe reaps **its own** scratch at its own close; a general
  content-verified sweep of residue nobody closed is a separate ticket, and quotas are instance-side.

## Composes

- **`log-experiment`** — lands the note as a gated PR (the note path: secret scan → cross-family bot approve
  → merge) **and, at that merge, reaps this recipe's scratch** (Step 3). Invoke it; don't hand-roll
  branch/PR/approve/merge, and don't hand-roll the reap either.
- **`run-experiment`** — owns `reap_scratch.sh`, the archive-verify-delete helper the landing calls; the
  note path is an entry point on it, not a second implementation (and not a weakening of its experiment-path
  guards).
- **`design-experiment`** / **`run-experiment`** — the audited pipeline this recipe is deliberately below the
  threshold of; escalate to them once a note's number needs to carry claim-level weight (Step 5).
- **`update-dashboard`** / **`update-site`** — the optional viewer leg (Step 4).

## Reference

- **`templates/NOTE_TEMPLATE.md`** — the pinned `NOTE.md` skeleton (including the `scratch:` declaration).
- **`scripts/stream_tar_census.sh`** — read a remote tar's member list from the stream, so a checkpoint
  census never stages the archive on this box (Step 1's artifact rule; `scripts/stream_tar_census_smoke.sh`
  is its offline behavior smoke).
- Worked references: `registry/csp1-icl-probe-1` (PR #346); `registry/csp1-hot32-surface-contrast-1` (PRs
  #359/#362, dashboard #360) — both in `antondelafuente/research-lab`.
