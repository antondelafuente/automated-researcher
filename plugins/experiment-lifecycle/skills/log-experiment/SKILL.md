---
name: log-experiment
description: >-
  Log a finished experiment, a design-stage pre-registration, or a plain note to the research repo as a GATED
  pull request and merge it — the research counterpart to ship-change. Classifies by the registry convention
  (DESIGN.md+RESULTS.md = experiment; DESIGN.md alone = design-stage, the design PR; otherwise note) and gates
  by context: an experiment verifies its close-audit is present + triaged; a design-stage verifies its
  design-audit is present + secret scan; a note runs a deterministic secret scan. A cross-family engineer bot
  (the family opposite the author) approves to satisfy branch protection. Run this instead of hand-doing branch/PR/approve/merge.
  Self-contained (does not source wf.sh); config via RESEARCH_REPO + the instance engineer seam.
---
# log-experiment — log an experiment or note to GitHub as a gated PR

The **research** counterpart to `ship-change`: where `ship-change` ships a code change to the product,
this logs a **research record** (a finished experiment, or a plain note) to the research repo as a
**gated pull request**, and merges it. It exists so that "log this experiment to GitHub" is a written,
runnable workflow — not tribal knowledge an operator carries in their head.

It belongs to the **research product** (`automated-researcher`), owns its own GitHub-lifecycle glue, and
does **not** source `wf.sh`. (Why here: logging/auditing experiments is a research-product feature — see
`~/AGENTS.md` "The vision".)

## When to use

- A `run-experiment` execution finished and its registry dir (`DESIGN.md`/`RESULTS.md`/`AUDIT.md`/…) should
  land in the research repo.
- A `design-experiment` design was cleared and its pre-registration (`DESIGN.md` + `DESIGN_AUDIT*.md`, no
  `RESULTS.md` yet) should land as the design PR — the pre-launch leg of the two-PR flow.
- A note/record (meeting notes, a gotcha, serving infra, a knowledge ingest) should land.
- Anywhere you would otherwise hand-run "branch → PR → mint bot token → approve-as-bot → merge."

## How

```bash
scripts/log-experiment.sh <registry-dir> [--dry-run]
```

That one command does everything: classify → gate → branch (in a dedicated worktree) → PR → cross-family
bot approval → squash-merge → sync local `main`. `--dry-run` classifies and gates, then stops before any push.

The driver **classifies by the registry convention** (no label needed):

| the dir has… | classified as | gate |
|---|---|---|
| `DESIGN.md` **and** `RESULTS.md` | **experiment** | verify the close-audit is present + triaged |
| `DESIGN.md`, **no** `RESULTS.md` | **design-stage** | verify the design-audit is present (`DESIGN_AUDIT*.md`) + deterministic secret scan |
| anything else | **note** | deterministic secret scan |

The two legs of the **two-PR experiment flow** map onto the two design-bearing kinds: log a dir at design
time → **design-stage** (the design PR, design-audit gate); run the experiment, then log the same dir again →
**experiment** (the results PR, close-audit gate; its diff is the new `RESULTS.md`/`AUDIT.md`, the design
files already merged).

A `KIND` file in the dir (containing `experiment`, `design-stage`, or `note`) is honored as an explicit override.

## The gates (fail-closed — an unparseable verdict BLOCKS, never passes)

- **Experiment.** The close-audit already ran during `run-experiment`; this **verifies it was triaged**, it
  does not re-run or re-derive the science. BLOCK unless **both** `AUDIT.md` and `AUDIT_RESPONSE.md` are
  present (the audit ran and every finding was responded to). It deliberately does *not* prose-grep for
  unresolved HIGHs — that's unreliable; a machine-readable close-triage status the gate could *prove* is a
  documented future hardening. An eval-only / anchor-failed run with no close-audit is allowed **only** if
  `RESULTS.md` records a closed decision *at line start* (e.g. `Decision: ANCHOR_FAILED`, no-go); otherwise it
  BLOCKS and you surface it to the researcher.
- **Design-stage.** The **pre-launch leg** of the two-PR flow (`DESIGN.md` present, no `RESULTS.md` yet). The
  design-audit ran during `design-experiment`; this **verifies it ran** — BLOCK unless at least one
  `DESIGN_AUDIT*.md` is present (the numbered `DESIGN_AUDIT.md`, `DESIGN_AUDIT2.md`, … chain is the validity
  record). Like the experiment gate it verifies the audit is *present*, not that every finding was resolved (a
  machine-readable triage status is the same documented future hardening; the researcher invoking this at
  design time **is** the clearance act). It **also runs the deterministic secret scan** — a `DESIGN.md`-only
  dir was secret-scanned as a `note` before this kind existed, so design-stage must not drop that scan. A
  missing design-audit, or a secret hit, BLOCKS.
- **Note.** A note has nothing to adversarially audit, so there is **no LLM review** — only a deterministic
  scan for secret-value patterns (`ghp_…`, `github_pat_…`, `sk-…`, `AKIA…`, PEM private keys). A hit BLOCKS.

A BLOCK prints the reason; fix the record (add the missing audit, remove the secret) and re-run, or surface
to the researcher if it needs a human call.

## Identity / auth

Both the writes and the review go through **engineer bots**: the **author-family** bot does the commit /
push / PR-create / merge, and the **opposite-family** bot posts the approving review — so the author bot
can't approve its own PR (cross-family independence), using the same engineer identities `ship-change` uses.
Because the writes use the author bot's own token, **an autonomous agent can log its work with no ambient
`gh` credential at all**. Both tokens are minted just-in-time, validated against the repo, fail-closed (no
token / no access → BLOCK before any mutation), and never printed.

## Config (instance, env-overridable — never hardcode an instance; fails closed if unset)

- `RESEARCH_REPO` — the research repo (`owner/repo`). **Required — no default**; the input dir's `origin` must match it.
- `LOG_EXPERIMENT_AUTHOR_FAMILY` — `claude`|`codex`. Defaults to `$AAR_SUBSTRATE`; **fails closed if neither is set** (a wrong default must not make the review same-family). The reviewer is the **opposite** family.
- `LOG_EXPERIMENT_TOKEN_CMD_CLAUDE` / `LOG_EXPERIMENT_TOKEN_CMD_CODEX` — each a command taking `<owner/repo>` that mints that family's engineer-bot token. **Both** are used: the author family's (writes) and the opposite family's (approval). **Fail closed if either is unset.**
- `LOG_EXPERIMENT_GIT_AUTHOR_CLAUDE` / `LOG_EXPERIMENT_GIT_AUTHOR_CODEX` — the `Name <email>` each bot commits as. **Fail closed if the author family's is unset.**

## Composes

- **`run-experiment`** — produces the registry record this logs (and runs the close-audit the experiment
  gate verifies).
- **gh** — PR create / review / merge.
- The research repo's per-dir `.gitignore` keeps large artifacts on R2; `git add` honors it, so only the
  lightweight record lands.

## Worked reference

The by-hand sequence this automates was run on 2026-06-29: records (PRs #21/#22, secret-scan path) and
experiments (PRs #16/#18/#19/#20, verify-audit path) in `antondelafuente/research-lab`.
