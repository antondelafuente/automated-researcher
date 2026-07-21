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
- `FEEDBACK_WF_CMD`: optional command to invoke `wf.sh` when it isn't on `PATH` (e.g. an absolute path to
  the `aar-engineering` plugin's `skills/ship-change/scripts/wf.sh` in its own repo checkout). Set this when
  `aar-engineering` is installed on this box but not discoverable by bare name — see the resolution order in
  "Route It" step (1) below.

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
(`bug`, `enhancement`, `documentation`, or `onboarding`) and no disposition label — unlabeled is the resting
state every newly filed Issue starts in, awaiting a triager assessment and then a researcher decision. Never
self-assign `ready`, `blocked`, `parked`, or `other`: those are researcher/triage-applied statuses, not
filing-time choices. If you believe the filing is blocked on a prerequisite or better parked than actioned,
say so in the issue body (e.g. a `blocked-by: #N` line or a one-line note) and let the triage pass act on it.
Read `references/DISPOSITIONS.md` for the label contract.

Every Issue filed through this skill (never a hand-filed one — that's the researcher's own filing, not this
skill's) also carries exactly one **provenance label**, alongside the type label above.
This is structural attribution — the triager weighs an incident-driven agent report differently from a
researcher directive, and a label is machine-readable where prose is not:

- `agent-filed` — you're filing this from your own observation (an incident, a footgun, a close-retro
  finding) with no researcher ask behind it.
- `researcher-requested` — the researcher explicitly asked you to file this (e.g. a session told you "file a
  ticket for X"); cite the request (what was asked, and when/where) in the body.

Also add one **provenance line** to the body naming the filing session/executor and the authoring path used,
so the label carries the class and the body carries the specifics. The line's wording varies by provenance
class:

`agent-filed`:

```
Filed autonomously by a <substrate> <skill-name> executor (session <session-id>) via the file-feedback
skill, not hand-written by the researcher. Posted via `<authoring path used>`.
```

`researcher-requested`:

```
Filed by a <substrate> <skill-name> executor (session <session-id>) via the file-feedback skill on the
researcher's explicit request (<what was asked, and when/where>), not hand-written by the researcher.
Posted via `<authoring path used>`.
```

`<authoring path used>` is whichever of the two engineer-identity paths below actually ran — e.g.
`wf.sh issue claude create` or `scripts/engineer_gh_issue.sh claude create`.

Use an engineer-safe authoring path — always pass `-R "$FEEDBACK_PRODUCT_REPO"`, and never fall back to raw
`gh issue create` for product feedback. The ambient agent GitHub credential is read-only by construction (see
AGENTS.md); a bare `gh` write either fails closed or, on a non-conforming box, silently succeeds under the
repository owner's identity instead of the agent's — that is exactly what happened in #447, filed under the
owner's identity because a box without an `aar-engineering` checkout let a raw-`gh` fallback through. Try, in
order:

1. **`wf.sh issue`, when `aar-engineering` is installed and configured.** Resolve the `wf.sh` command in
   this order before concluding it isn't on this box — a bare-name lookup finding nothing is not the same as
   `wf.sh` not existing:

   1. `$FEEDBACK_WF_CMD`, when set (see Config above) — invoke it quoted (`"$FEEDBACK_WF_CMD"`) as the
      `wf.sh` command, since it's a single absolute path that may contain spaces; an unquoted substitution
      would word-split it.
   2. `wf.sh` on `PATH`.
   3. A sibling plugin-source checkout next to this repo: the `aar-engineering` plugin ships `wf.sh` but
      lives in a separate repo checkout (e.g. `~/agentic-engineering/plugins/aar-engineering/skills/ship-change/scripts/wf.sh`),
      never this one. `--plugin-dir` loading puts the plugin's skill *names* in context but not its source
      path, so this step is a real search (sibling directories of this repo checkout, common plugin-source
      roots), not a guess. If found this way, set `FEEDBACK_WF_CMD` via `feedback_loop_init.sh` so future
      filings skip the search.

   Only fall through to step (2) below once all three resolution steps come up empty.

   ```bash
   wf.sh issue <claude|codex> create -R "$FEEDBACK_PRODUCT_REPO" -t "<title>" -b "<body>" -l <type> -l <provenance>
   wf.sh issue <claude|codex> comment <issue-number> -R "$FEEDBACK_PRODUCT_REPO" -b "<body>"
   ```

   (`wf.sh` here means whichever of the three resolution steps above found it — substitute the
   sibling-checkout path for the bare name if that's what resolved, or `"$FEEDBACK_WF_CMD"` (quoted, per
   step (1) above) if that's what resolved.)

2. **`scripts/engineer_gh_issue.sh`, when `wf.sh` isn't installed but the box has the #149
   `WF_ENGINEER_TOKEN_CMD_<CLAUDE|CODEX>` seam configured.** This skill ships its own minimal, self-contained
   engineer-identity wrapper (automated-researcher#454) precisely so a box without an `aar-engineering`
   checkout still has an engineer-safe path instead of having to defer every filing:

   ```bash
   scripts/engineer_gh_issue.sh <claude|codex> create -R "$FEEDBACK_PRODUCT_REPO" -t "<title>" -b "<body>" -l <type> -l <provenance>
   scripts/engineer_gh_issue.sh <claude|codex> comment <issue-number> -R "$FEEDBACK_PRODUCT_REPO" -b "<body>"
   ```

3. **Defer, only when NEITHER of the above is available/configured.** Do not write with the ambient
   credential as a workaround. Instead, persist the fully-drafted Issue — title, body (including the
   provenance line above), and labels (type + provenance) — to a durable location you already have (the
   run's artifact store, or the close handoff notes), and surface it LOUDLY in your close summary: state
   plainly that filing was deferred and a properly-credentialed session needs to run one of the two paths
   above with the persisted draft. The draft is the deliverable; the write waits for the right identity.

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
  state,closed` / `gh pr list -R "$FEEDBACK_PRODUCT_REPO" --search "<N>" --state open`) — the tracker is a
  triage queue, not a notebook: the researcher (never the filing agent) applies `ready` after triage, and on
  a deployment with fast auto-implementation a `ready` issue can close within the hour. If it is closed or
  in flight, file a new small ticket linking the old one instead: a comment there is a dead letter the
  implementor never sees. Shaping comments on an open, still-unlabeled issue remain the intended flow.
