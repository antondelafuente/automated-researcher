# Proposal: run-experiment close self-audit must require a terminal folded ledger status (#338)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

A completed experiment can appear `running` in downstream consumers (dashboards) after close, if an
executor backfills a missing launch event with a `running`/`launched` ledger write during the close
self-audit. This happened in `carrier-divergence-2` (2026-07-04): the run reached `done` at
`20:05:13Z` with `RESULTS.md` written, then at `20:14:33Z` the executor noticed the launch event was
missing and retroactively added a `running` event. Because the ledger fold is last-non-null-field-wins,
the folded state flipped back to `running` even though artifacts, teardown, `log-experiment`, and
run-supervision close were all already complete. The dashboard correctly read the folded state and
showed a finished run as still running.

The root cause is in `run-experiment`'s own close guidance: Step 5's self-audit currently checks only
that the ledger has *both* a launch and a done event *somewhere in its history* — it never checks that
the *folded/latest* status is still terminal. That phrasing is what nudges an executor toward "the
launch event is missing, so let me add one" instead of "the run is already terminal, so I must not
write a non-terminal status now."

## Approach

Tighten the Step 5 self-audit line in `plugins/experiment-lifecycle/skills/run-experiment/SKILL.md` (the
line that currently reads "ledger has BOTH launch + done events") so it instead requires the ledger's
**folded/latest status to be terminal** (`done` / `failed` / `killed`, and any deployment-specific
terminal status such as `torn_down` the profile defines) — not merely that a launch event exists
somewhere in history. Pair that with an explicit prohibition: an executor must never backfill a
`running` / `launched` / `deploying` event after a terminal event has already landed, because a
last-non-null-field-wins fold means that write silently reopens the run for every consumer. If launch
metadata turns out to be missing during the close audit, the guidance now tells the executor to attach
it as a non-status note, or re-emit it on a fresh event that itself carries a terminal status — never as
a non-terminal status event.

This is a single guidance edit, scoped to the text an executor reads during Step 5 close. It is the
first bullet of the issue's three-part proposed fix (run-experiment close guidance), and it is the part
that lives in this repo (`automated-researcher`, the product/scaffold repo).

The other two parts of the issue's proposed fix are explicitly out of scope for this repo:

- **Hardening `ledger.py`** (rejecting a non-terminal status write after a terminal folded state) is
  instance-owned code — `ledger.py` lives in the consuming instance's ledger recipe (e.g.
  `research-lab/registry/ledger.py`), not in `automated-researcher`. This repo only carries a typed
  pointer to that recipe (`references/SCHEMA.md`, `[recipes.ledger]`); it ships no ledger
  implementation to patch. That mechanical guard is a follow-up for the owning instance repo.
- **The optional dashboard-side warn note** is explicitly marked optional in the issue and is also
  consuming-instance / dashboard-side work, not scaffold work.

Fixing the guidance an executor reads, in the product repo that owns it, closes the actual gap this
issue traces the incident to: nothing in `run-experiment`'s own text currently forbids the write that
caused the incident. The mechanical ledger-side guard is complementary defense-in-depth, but it lives in
a different repo and is out of this PR's scope per the dispatch brief's scope discipline.

## Alternatives considered

- **Also patch `ledger.py` in this PR.** Rejected: no such file exists in `automated-researcher` — the
  ledger implementation is instance-owned code in a separate repo (`project_product_boundary`: the two
  products don't runtime-depend on each other). Doing so here would mean inventing or vendoring a file
  that doesn't belong to this repo's surface, which is exactly the kind of adjacent-repo scope creep the
  dispatch brief says to avoid.
- **Add the optional dashboard-warn guidance text here anyway.** Rejected for the same reason — the
  dashboard is consuming-instance surface, not `automated-researcher` scaffold content, and the issue
  marks it optional.
- **Leave the self-audit bullet worded around "both events exist" and just add a separate new bullet
  forbidding backfill.** Rejected: keeping the weaker "both events exist" phrasing side-by-side with a
  new prohibition invites the same failure mode a plain reader hit here — it reads as satisfied by
  adding the missing event. Replacing the check itself (terminal folded status, not raw event
  presence) removes the ambiguity at its source instead of patching around it.

## Blast radius

Touches only `plugins/experiment-lifecycle/skills/run-experiment/SKILL.md` — the Step 5 close
self-audit bullet. Doc-only change (guidance text), no scripts, no schema, no runtime behavior change.
Read by every future `run-experiment` executor at close time; no effect on in-flight runs or historical
ledger data.

## Rollout + rollback

No rollout mechanism needed — this is a documentation/guidance edit picked up the next time an executor
reads the skill. Rollback is a plain revert of the one PR if the wording needs another pass.
