# automated-researcher — development conventions (agent-facing)

This repo is the PRODUCT: modular agent skills for automated research, developed here in their public shape even
while the repo is private. A consuming instance is the deployment that imports this repo through plugin installs,
source checkouts, symlinks, or thin local wrappers. The product never depends on a particular instance. Each
consuming instance owns its own transition map, local paths, credentials, run records, launch/reload machinery,
and deployment guidance.

## This repo is the product; the SWE pipeline that builds it lives in agentic-engineering

This repo is **the product** — the shipped research plugins (`gpu-job`, `verify-claims`, `experiment-lifecycle`,
`feedback-loop`): the automated-researcher scaffold that turns a coding agent into an autonomous researcher.
Quality bar: *is the research valid.* Customer: the alignment researcher.

The **SWE pipeline that builds, reviews, tests, and ships this product** — the `ship-change` lifecycle (the
`aar-engineering` plugin) — lives in the separate **`agentic-engineering`** repo: the engineering team's
tooling. A scaffold change to THIS repo is shipped via agentic-engineering's `ship-change` (Issue → worktree
branch → design doc → draft PR → cross-family review → tracked `.aar-ci` checks + behavior smoke →
merge-when-clean). *Why a separate repo:* the team's tooling is generic — it could build any product, not just
this one — so it is not part of the shipped research product (the instance constitution's vision owns this
boundary). It remains **agentic at both levels**: agents *do* the research (this product), and agents
*build / test / ship* it (the agentic-engineering pipeline).

**The agents ARE the engineers.** Every Claude Code / Codex instance is an engineer on the team (with its own
GitHub identity): they author changes, **cross-family-review** each other's PRs (a foreign family is the
safeguard — "agents are peers" realized in the build), **approve**, and **merge**. The human is the
**staff-engineer / PM**: sets direction (the Issue backlog) and shapes it (`unlabeled → ready`), oversees
and can intervene — but is **not a per-PR gate**. This **mirrors the research pipeline** at the direction level:
design *with the human* on what to build, execution *by the agents*. (The full engineer model + the
merge-safety properties live with the pipeline in agentic-engineering.)

**`verify-claims` in THIS repo is the product's experiment-audit engine** — `--design` / `--data` / close +
`verify_claim` (the facts→logic→data→evidence ladder for experiments). The **SWE-review** halves (`--scaffold`
design review + `--code` PR review) live with the engineering tooling in **agentic-engineering**: when its
`ship-change` reviews a change to this repo, it resolves the SWE reviewer from **agentic-engineering's own**
`verify-claims` (base-ref materialized, never the branch under review), judging against THIS repo's `AGENTS.md`.
So the product carries only what experiments need, and the engineering team owns its own reviewer — one
canonical home per side.

## GitHub-native SWE pipeline (BYOK) — event-driven `ready` → merged PR

For this repo specifically, the `ship-change` lifecycle above can run **without a session dispatching
it**: a `ready` label launches an execution-tier Claude implementor via GitHub Actions, and PR events run
the cross-family Codex review natively. This is proven here first; a copy for `agentic-engineering` is
explicit follow-up work, not part of this capability (see automated-researcher#378 /
agentic-engineering#43).

- **Flow:** researcher (or an engineer bot) labels an Issue `ready` → `implement-on-ready.yml` runs the
  pinned Claude Code CLI (execution-tier `claude-sonnet-5`) against the issue, working on `agent/issue-<n>`,
  and opens a PR with `Closes #<n>` → `review-on-pr.yml` runs `openai/codex-action` against the diff and
  submits a native APPROVE/REQUEST_CHANGES review as the codex engineer bot → on `changes_requested`, an
  allowlisted mention comment on the PR fires `address-review.yml`, which re-dispatches the pinned CLI onto
  the SAME PR branch to address the findings and pushes, which fires `synchronize` and re-runs
  `review-on-pr.yml` automatically → existing branch protection (required opposite-family approval) + the
  implement workflow's auto-merge step close the loop once a round comes back clean. `checks.yml` runs
  `.aar-ci/checks.sh` as a required status check on every PR, agent or human authored — this is the same
  deterministic gate `ship-change`'s `wf.sh finish` runs by hand, now wired as a trusted GitHub check instead
  of relying on the implementor's own honor.
- **Authorization predicate:** a privileged implement run requires `issues: labeled` with
  `label.name == 'ready'` AND the labeling actor allowlisted AND (re-verified fresh, before any token is
  minted) the issue's current author AND label state — allowlist = the researcher (`antondelafuente`) +
  the two engineer bots (`claude-code-engineer[bot]`, `codex-engineer[bot]`), hard-coded in the workflow.
  `workflow_dispatch` (issue-number input, actor allowlisted, same fresh re-verification) is the only other
  entry path — needed because label events don't fire retroactively. A privileged **address-review** run
  requires `issue_comment: created` on a PR (not a plain Issue) mentioning the claude engineer bot, the
  comment author allowlisted (same allowlist), AND (re-verified fresh, before any token is minted, via
  `gh pr view`) the PR is same-repo (no forks) and its author is exactly the claude engineer bot — the same
  spoof-resistant author predicate `review-on-pr.yml` uses. `issue_comment` workflows always run the
  workflow file from the default branch regardless of the PR's own content, which is what makes checking
  out the PR's head branch for the agent's working tree safe here (unlike `pull_request_target`).
- **Concurrency is per-issue dedup, not a worker pool.** `implement-on-ready.yml`'s
  `concurrency: group: implement-issue-<n>` only prevents a duplicate run on the *same* issue. There is
  **no global cap** in v1 — GitHub Actions `concurrency` groups don't provide one. The spend guard is the
  researcher's deliberate one-at-a-time `ready` flip; don't build a queue to work around this without a
  deliberate follow-up decision to do so.
- **Codex review guidance (P0/P1 convention)** — the criteria `review-on-pr.yml` gives the Codex reviewer,
  pulled from this section at the PR's **base** ref (never the PR's own head, so a PR cannot weaken its own
  review criteria by editing this section in the same diff it's being reviewed for):
  <!-- CODEX-REVIEW-GUIDANCE:BEGIN -->
  - **P0 (blocking):** a correctness bug that breaks the change's stated purpose; a security issue (secret
    exposure, injection, privilege escalation, a trust-boundary violation); or a violation of one of this
    file's `Rules`. Blocks `APPROVE` — the PR gets `REQUEST_CHANGES` instead.
  - **P1 (non-blocking):** style, minor edge cases, suggestions, simplification opportunities. Recorded in
    the review body for a later human pass; never blocks merge on its own.
  <!-- CODEX-REVIEW-GUIDANCE:END -->
- **The scale principle** (researcher-stated policy, quoted verbatim — not agent paraphrase): "~10
  concurrent agents, a handful of researchers; robustness is priced at that scale; rarity alone never
  kills a fix, cost does; trust gates stay fail-closed." This is the calibration for both sides of a
  review: how defensive an author makes code, and which edge cases a reviewer spends a round on.
- **The dispute norm** (from PR #425's converged round-4/5): when a review finding is disproportionate at
  the scale above, the implementor should DISPUTE it with rationale — a cost/scale argument, or an
  existing safeguard that already covers it — rather than iterating indefinitely to satisfy it. A dispute
  must only cite escape hatches or safeguards that actually exist: the #425 lesson is that the reviewer
  fact-checked the dispute's claimed `--skip-ignored` escape and it didn't exist, so an invented safeguard
  undermines the dispute worse than not disputing at all.
- **Accepted residual risk:** the implementor agent executes repo-controlled code (tests, hooks) while
  holding its API key and a short-lived write-scoped GitHub token. `checks.yml`'s required-status job
  carries the same residual risk on the same basis: it passes the `ANTHROPIC_API_KEY` repo secret to
  `.aar-ci/checks.sh` (read-only `GITHUB_TOKEN`, no write permissions) so `fake_home_smoke.sh` can run
  `claude plugin` headlessly on a GitHub runner (#396). **This repo is PUBLIC** (re-verified live
  2026-07-18, #492) — the acceptance no longer rests on "private, single-author"; it rests on three
  currently-true mechanisms instead: (a) GitHub withholds repo secrets from fork-PR `pull_request` runs
  (`checks.yml` triggers on `pull_request`, never `pull_request_target`), so a fork PR cannot read
  `ANTHROPIC_API_KEY` — its `checks` status fails/skips instead, so an outside PR can't go green without
  maintainer involvement; (b) `implement-on-ready.yml` — the job that holds the write-scoped token — only
  dispatches on `issues: labeled`, and its authorize step re-fetches the issue's live author + labels
  (fresh, before any token is minted) against a hard-coded allowlist, so an outsider cannot trigger it by
  labeling or by `workflow_dispatch`; (c) the implementor only ever executes code from branches a
  collaborator or the two engineer bots pushed, never fork-controlled content. Fork-PR workflow-approval
  is confirmed set to `all_external_contributors` (re-verified live 2026-07-18, #492) — stricter than the
  `first_time_contributors` default, requiring maintainer approval before ANY outside-collaborator fork-PR
  workflow run, not just a contributor's first. Outside *contributions* (fork PRs opened by non-collaborators)
  are consequently not yet a supported path on this basis alone: before accepting them, re-audit which
  secrets a green fork-PR run could reach and revisit this note.
- **Re-entry / retry:** re-dispatch an issue by removing and re-adding `ready`, or via
  `workflow_dispatch`. Post-review fixes ride `address-review.yml`'s mention flow instead: an allowlisted
  `@claude-code-engineer` comment on the PR re-dispatches the pinned CLI onto the same PR branch
  (`.github/prompts/address-review.md`), gated to the researcher + the two engineer bots, same as
  implement-on-ready's allowlist. It never invokes the review itself — pushing a fix fires `synchronize`,
  which `review-on-pr.yml`'s own `cancel-in-progress` already handles.
- **Escalation (`needs-senior-engineer`):** if the implementor is blocked, or a review finding conflicts with
  what the issue specifies, it labels the PR (or the issue, if no PR yet) `needs-senior-engineer` and comments
  what's needed, then stops that thread of work. This defines only the label convention — the notifier
  that surfaces `needs-senior-engineer` to a session or the researcher is instance wiring, not part of this
  product capability. A `ready` label's flip by an allowlisted human/bot is itself the "explicit dispatch"
  the `ready` disposition (below) requires — there is no separate per-run naming step once the label lands.
  `address-review.yml` runs use the same escalation convention on the PR it's already working.
- **Senior-engineer leg (in-flight PR adjudication, automated-researcher#438; parent design #414's
  "Shepherd"):** `senior-engineer.yml` is summoned by the `needs-senior-engineer` label landing on a PR — by
  the reconciler's round-budget trip, by an implementor asking for help, or by a human — plus
  `workflow_dispatch` (PR number) as the manual lever, same actor allowlist as the other actuators. It runs a
  Fable-family agent (`claude-fable-5` — judgment-dense per model policy; these events are rare so per-event
  premium cost is acceptable) under a dedicated `senior-engineer-agent[bot]` App identity with `Contents: read`,
  `Pull requests: read-write`, `Issues: read-write` — it can comment and label but cannot push code, by
  construction. Its mandate, drawn straight from the 2026-07-11 supervised night's transcripts: (1) verify
  every finding/dispute/conflict-cause EMPIRICALLY (read the code, run a one-command test) before
  adjudicating, never by weighing prose alone; (2) hand the implementor **exact target semantics**, not
  finding-pointers — precise guidance converged in one push, vague pointing produced PR #428's round-5
  regression; (3) a dispute must cite only escape hatches/safeguards that actually exist (PR #425's lesson);
  (4) escalate anything needing instance state (pods, fleet, box) or researcher taste it can't verify — that
  is correct behavior, not a limitation. On success it posts a guidance comment through the existing
  allowlisted `@claude-code-engineer` mention path (re-dispatching the implementor via `address-review.yml`,
  whose allowlist includes `senior-engineer-agent[bot]` for exactly this) and clears `needs-senior-engineer`; when
  it escalates instead, it applies `needs-human` with a structured comment (the decision needed, the
  options, its own lean, and what happens by default if unanswered) and stops. **Loop guard:** it never
  dispatches more than once per label application, and if `needs-senior-engineer` REAPPEARS on the same PR
  N=2 times (a 3rd+ total application — counted from the issue's own `labeled` event timeline), it escalates
  straight to `needs-human` instead of running another round, since a converging guidance loop wouldn't need
  to be re-labeled. Fails gracefully (a clear skip log line, no error) while the dedicated App and its two
  secrets don't exist yet.
- **Review re-fire actuator:** `review-on-pr.yml` also accepts `workflow_dispatch` (input: `pr_number`),
  running the same authorize→review→verdict path against the PR's CURRENT head — same actor allowlist as
  implement-on-ready's dispatch path (re-verified fresh via `gh pr view`: same-repo, bot-authored, open).
  Useless against a still-conflicted PR (no merge ref to review); used by the reconciler below for the
  mergeable-but-unreviewed case, and as a hand tool.
- **Reconciler (scheduled, level-triggered):** GitHub fires no `pull_request` run at all while a PR is
  unmergeable at event time — the run targets `refs/pull/N/merge`, which can't be built while the PR
  conflicts with base. This is deterministic platform behavior, not dropped events, and was the dominant
  silence mode observed in wave operation (automated-researcher#431): a sibling merge lands on main, a
  still-open same-area PR goes conflicted, and every subsequent `opened`/`synchronize` event on it produces
  nothing until a human/dispatcher notices. `reconcile-prs.yml` runs on a ~10-minute schedule and walks
  open bot-authored PRs to repair this itself: `mergeable == CONFLICTING` → post the allowlisted
  `@claude-code-engineer` resolution-dispatch mention (round-budgeted; escalates to `needs-senior-engineer`
  instead of nudging forever once the head stops moving — automated-researcher#438, see the senior-engineer
  leg below); `mergeable == MERGEABLE` with no completed codex review at the current head → re-fire
  `review-on-pr.yml` via the actuator above (the residual true-event-loss case, if one exists). It also skips
  any PR already carrying `needs-senior-engineer` or `needs-human` — those mean another leg of the pipeline
  (or a person) is already handling it.
- **Label lifecycle:** a ticket rests unlabeled until a triager pass assesses it (#437's original batch
  design, evolved by #497 into a per-ticket event-driven leg plus a backstop sweep leg: proposes a flip,
  posted as an on-ticket assessment comment, for the researcher to confirm; v2: acts autonomously within the
  autonomous-flip class below) → a `ready` flip carries a citation of the shaping conversation (the
  assessment comment, when the triager already produced one) plus, when the triager edited the body, a
  one-line delta summary of what changed → once implementation opens a PR, `needs-senior-engineer`
  summons the senior engineer (#438) for in-flight adjudication → `needs-human` parks an escalation the
  senior engineer (or any lane) can't resolve itself, for interactive researcher review. `needs-human` is
  pull-based — no reminders: an unanswered ASK degrades to SKIP, and SKIP is a legitimate outcome, not a stall.
- **Shaping rights:** the triager (v1 proposes, v2 acts — see above) edits ticket bodies freely; the body is
  the contract a zero-context implementor reads, and comment-as-spec (design drifting into a comment thread
  instead of the body) is the proven failure mode this convention exists to close off. Guardrails: never
  edit the evidence — incident citations and provenance stay verbatim, or move to a clearly marked "Original
  report" block, never paraphrased away; every body edit gets a one-line delta summary in the flip/triage
  comment; the triager is the SINGLE automated body writer (GitHub Issue body edits are last-write-wins, so
  a second automated writer would silently clobber the first).
- **Wave batching rule** (root-caused by automated-researcher#431): file-disjoint tickets may batch into one
  parallel wave; same-file tickets serialize instead. Reason: a conflicted PR produces no workflow runs at
  all (see Reconciler above) — so when same-file siblings batch and one merges, every other open sibling on
  that file goes conflicted and silent until the reconciler or a human notices.
- **Autonomous-flip class** (v2 forward-reference — the triager doesn't act autonomously until v2, #437,
  lands): an `unlabeled → ready` flip is autonomous when the change is both-models-DO (both review
  families would independently choose to build it), doc/guidance-level (no product-shape decision), and
  inside the flip budget; a workflow/trust-gate/heuristic ticket may still autonomously flip but is
  senior-engineer-flagged for a closer look in review; a flip where the two models disagree, or that changes
  product shape, goes to the researcher instead.
- **Dispatcher playbook** — the operations a human/dispatcher uses to drive this pipeline day to day (each
  mechanic is defined above; this is the consolidated at-a-glance list):
  - Dispatch/re-dispatch an Issue: add `ready` (or remove it and re-add after ~5s so the label event
    re-fires), or `workflow_dispatch` with the issue number.
  - Trigger an addressing round on a PR carrying review findings: comment `@claude-code-engineer` plus
    guidance on the PR (allowlisted authors only — see "Re-entry / retry" above).
  - **PR gone silent (no checks/review run at all):** check `mergeable` first (`gh pr view <n> --json
    mergeable`) — don't reach for `gh pr update-branch` on reflex, since that only helps a base-branch fix
    that already landed. `CONFLICTING` → trigger a resolution round the same way the reconciler does
    (comment `@claude-code-engineer` asking it to merge origin/main, resolve, and push — see the bullet
    above); `MERGEABLE` with no review at the current head → `gh workflow run review-on-pr.yml -f
    pr_number=<n>` (the actuator). The scheduled reconciler normally beats a human to both within ~10
    minutes; this is the manual equivalent for when you don't want to wait.
  - Unblock a `needs-senior-engineer` Issue or PR: answer the blocking question in a comment, remove
    `needs-senior-engineer`, then re-flip `ready` (issue) or re-trigger addressing (PR) per the two bullets above.
  - Trigger a manual in-flight adjudication on a PR: `gh workflow run senior-engineer.yml -f pr_number=<n>`
    (works with or without `needs-senior-engineer` present — the manual lever doesn't require the label).
  - Unblock a `needs-human` PR: answer the structured question the senior engineer posted, remove
    `needs-human`, and re-apply `needs-senior-engineer` if you want another automated adjudication pass, or
    comment `@claude-code-engineer` directly if you already know the exact fix.
- **Gate configuration** (state it here so it doesn't drift or get "fixed" back by someone who doesn't know
  it's deliberate — all three verified live 2026-07-11): `checks` (from `checks.yml`) is a required status
  check on `main`; `allow_auto_merge` is enabled repo-wide (what lets `implement-on-ready.yml`'s auto-merge
  step succeed); branch protection requires one approving review, satisfied by the codex engineer bot's
  native `APPROVE` from `review-on-pr.yml` — a human review is never the gate in this flow.
- **Reviewer pin rationale:** the Codex reviewer in `review-on-pr.yml` is pinned to `model: gpt-5.6-sol`,
  `effort: medium` — a deliberate choice, not a default left untouched. Bump the model or effort only in
  `review-on-pr.yml` itself, as its own conscious change (automated-researcher#394), never as a side effect
  of an unrelated edit.
- **Secrets this flow needs** (instance-provisioned, never checked in): `ANTHROPIC_API_KEY`,
  `OPENAI_API_KEY`, `CLAUDE_APP_ID`, `CLAUDE_APP_PRIVATE_KEY`, `CODEX_APP_ID`, `CODEX_APP_PRIVATE_KEY`.
  Until all six are set, `ready` events fail loudly in the Actions tab (a missing-secret error at
  token-mint) rather than silently doing something else. The senior-engineer leg additionally needs
  `SENIOR_ENGINEER_APP_ID` + `SENIOR_ENGINEER_APP_PRIVATE_KEY`, but by design fails gracefully (a clear skip
  log line) rather than loudly while those two are unset, since it's an optional-until-provisioned addition
  to an already-working pipeline, not a bring-up dependency the way the original six are.

**Two orthogonal cuts to keep straight:** *product vs instance* (this repo vs any consuming deployment that uses
it) and *product vs SWE pipeline* (the shipped research plugins HERE vs the `aar-engineering` / `ship-change`
tooling in `agentic-engineering` that builds them).

## Rules

- **Releasability test for inclusion:** would an outside researcher use this unchanged?
  Generic code lives here; instance values (keys, buckets, hostnames, program recipes)
  NEVER appear here — they belong in each user's `~/.config/<module>/` written by the
  module's init. The pre-commit hook (`git config core.hooksPath .githooks`, run once per
  clone) blocks known instance patterns; it is a backstop, not the discipline.
- **Spec layout:** each module = `plugins/<name>/` with `.claude-plugin/plugin.json` +
  `skills/<name>/SKILL.md` + `skills/<name>/scripts/` (scripts INSIDE the skill dir — the
  Agent Skills layout; it makes relative references work for plugin installs AND symlink
  installs identically).
- **Agent-filed Issues use the engineer identity, not the human's.** When an agent opens a GitHub Issue
  (or comments on one), author it as the `*-engineer[bot]` identity, never the ambient/human `gh` auth
  (raw `gh issue create` falls back to the human owner). The canonical interface is **`wf.sh issue
  <claude|codex> create|comment …`** — the Issue-side counterpart to `wf.sh comment`, reusing the SWE
  pipeline's one engineer-token path (`WF_ENGINEER_TOKEN_CMD_*`). On a box with no `aar-engineering`
  checkout (no `wf.sh` on `PATH`), the product-shipped fallback is
  `plugins/feedback-loop/skills/file-feedback/scripts/engineer_gh_issue.sh` (#454) — same
  `WF_ENGINEER_TOKEN_CMD_*` seam, same fixed create/comment verb surface, nothing more. The single token
  *implementation* is the instance-owned `WF_ENGINEER_TOKEN_CMD_*` minter both wrappers consume; an
  instance may still keep a thin `gh-as-engineer` alias, but it delegates to one of these two, never
  minting on its own. The rule covers
  *every* Issue an agent opens (ad-hoc backlog, decompositions, follow-ups). Backfilling existing
  human-authored Issues is not possible (GitHub can't reauthor) and not attempted.
- **The ambient agent GitHub credential MUST be read-only — by construction, not by convention.** This is
  the capability half of the rule above: the credential an agent shell reaches by default (exported
  `GH_TOKEN`/`GITHUB_TOKEN`, the stored `gh auth` login, and the Git push credential) must be **minted
  read-only by a controlled minter**, so its read-only scope is authoritative *by construction*, never
  merely promised. ALL writes go through the engineer token path (`WF_ENGINEER_TOKEN_CMD_*`); a bare `gh`
  write fails closed. The product seam an instance implements is **`WF_READONLY_TOKEN_CMD`** (prints the
  ambient read-only token) paired with **`WF_READONLY_TOKEN_INFO_CMD`** (emits the token's
  machine-verifiable granted permissions), mirroring how the rule above names `WF_ENGINEER_TOKEN_CMD_*`.
  `wf.sh doctor … --readonly` is the detector: it confirms the ambient credential is authoritatively
  read-only across the API + git-push surfaces and **FAILS CLOSED on any token whose read-only-ness it
  cannot authoritatively confirm** (an opaque/unattested token is a failure, not a pass — provenance, not
  a probe, is the certifier). Owner/admin writes are NOT ambient: they require the explicit two-step
  elevated-owner-token + `WF_GH_ALLOW_OWNER_WRITE=1` maintenance path (the ship-change RUNBOOK escape
  hatch), so elevation is a visible, deliberate act, never the silent default. (Design: the #149 design
  doc; this is its canonical contract home — the ship-change SKILL/RUNBOOK restate it at point of need.)
- **Every script header cites the real incidents it encodes.** No best-practice guesses.
- **Version bump on every behavior change** (plugin.json), one CHANGELOG-style line in the
  commit message; tag releases when someone depends on stability.
- **Same-day pointer rule:** when code migrates here from an instance repo, the instance
  copy becomes a symlink/pointer the same day. One canonical home per fact.
- **Test through the user path**, not by inspection: fresh session → plugin install →
  invoke → file friction. Friction reports are the product's most valuable input.
- Multi-agent dev: path-scoped commits; coordinate via the instance's channels before
  editing a module a peer has in flight. When a peer-coordination channel asks you to
  self-identify, resolve your OWN identity by lookup, never by an assumed naming scheme
  like `claude-N`: use the channel's own self-identity lookup if it provides one, else the
  substrate's session-name primitive (`tmux display-message -p '#S'` for tmux); if the
  substrate exposes no session-name lookup, identify with an observable stable runtime
  handle and say so — never substitute an example name. Session names aren't guaranteed (a
  session may be named for its experiment), and a guessed name silently defeats the point
  of self-identifying.

## Researcher-interaction defaults

Standing dispositions for how a research agent interacts with the researcher while doing actual research
(`design-experiment` / `run-experiment` / `file-feedback`) — distinct from the "Rules" above, which govern
developing this repo. Migrated from the instance constitution (#327): any deployment's agents need these, and
a Codex-substrate agent never sees one Claude instance's memories. Each line is the canonical definition; the
worked mechanics stay in the skill that owns them — this section does not duplicate those, and does not add any
default a plugin-only install of that skill lacks: every actionable line below is already fully stated in its
owning skill's own doc. This section is a repo-checkout index, not the only place a fresh install can find them.

- **Labor is free.** Estimates quote three currencies only — dollars, external wall-clock (GPU/training/human
  turnaround), and researcher-attention-minutes; your own implementation effort is never a reason to defer,
  phase, or withhold a proposal. Independent work launches as one parallel wave, not one-at-a-time. (Mechanics:
  `design-experiment`'s enumerate-don't-justify schedule framing, #322.)
- **Evidence at measured scope.** An experiment's result is a statement about the contrast
  it actually varied and measured — state it at that level. A treatment that bundles several
  factors (e.g. a data source = writing style × prompt selection × dose) supports a
  bundle-level statement; which component carries the effect is an open decomposition for a
  later experiment, not a caveat on the record. Call something a confound only if it
  threatens the comparison actually reported. An explanation fitted to the results after the
  fact is a postdiction: label it as such, and test it on fresh data before it carries
  load-bearing weight. (Mechanics: `design-experiment`'s data-vs-verdict split and
  variable-pinning, `run-experiment`'s close step, `verify-claims`' close-audit dimension.)
- **Validity/comparability is the main failure mode.** The silent failure is a clean pipeline producing a
  confidently-wrong number: compared numbers must be on the same scale, measuring the same thing. This is the
  standing disposition behind the audit gates. (Mechanics: `verify-claims`' design/data/close audits.)
- **Every agent is either a user or the maintainer, never both at once — separated in time.** During research
  work you are a user: run the canonical pipelines, file feedback while it's fresh, don't refactor the product
  mid-run. During a triggered pass you are the maintainer: single-writer, never concurrent with another
  maintainer pass. (Mechanics: `file-feedback` / `triage-feedback`.)

<!-- DISPOSITIONS:START -->
## Issue tracker — dispositions

Every open Issue carries a **disposition** — how it should be handled — orthogonal to its type
(`bug`/`enhancement`/…) and to open/closed. This is the definition (the product-owned, versioned part). The
assign-at-filing and maintain *procedures* live in the appropriate operating surface: reusable product feedback
machinery belongs in product skills, while deployment-only file bookkeeping belongs in consuming-instance
guidance. AGENTS.md holds the issue contract, not local workflow paths.

- **`ready`** — actionable now; any design is settled and lives in the implementing PR itself (design-in-PR).
  Implement + merge on the cross-family review + checks. `ready` is the only disposition **eligible**
  for auto-handling — but eligibility is not blind auto-merge: the auto-handler still runs the full
  cross-family review + checks. No Issue is auto-implemented without an explicit dispatch (a human or a
  dispatcher session naming it); the precise boundary of which `ready` Issues get acted on with less
  oversight (especially by blast radius) is undecided, and will be revisited if/when a standing
  auto-handler is actually proposed.
- **`blocked`** — decided but gated on a prerequisite; carries a `blocked-by: #N` body line. (When the
  blocker closes, triage clears the label so it's re-dispositioned, usually to `ready`.)
- **`parked`** — real but deliberately not-now; revisit later. (Distinct from `wontfix` = never.)
- **`other`** — doesn't fit the others; a recurring `other` is the signal to evolve the vocabulary.

**Unlabeled is the resting state.** Every newly filed Issue stays unlabeled — awaiting a triager assessment
(posted as an on-ticket comment, automated-researcher#497) and, on the back of it, a researcher decision —
until it is flipped to one of the labels above. `needs-design` is retired (#497): that resting state is now
simply the absence of a disposition label, not a separate label of its own. (The former `needs-shaping` label
was already folded into it the same way, 2026-07-11.)

**`unlabeled → ready` is the researcher's transition, in every lane.** An agent records the flip only on
the back of an actual researcher conversation, and the flip must **cite it** — a comment on the issue
summarizing/linking the shaping discussion (the triager's assessment comment, when one already exists, is
exactly this citation). An agent asked to *implement* an issue never flips its disposition
label as a step of implementing it — that would let it triage its own way in. This is a norm every lane
follows; a lane's mechanical *enforcement* of it (e.g. a pre-flight before work starts, vs. a gate only at
close) is that lane's own concern to build out. An Issue an agent files (including via `file-feedback`, see
#405) carries exactly a type label plus, when an agent is the filer, exactly one
provenance label (`agent-filed` or `researcher-requested` — see `file-feedback`'s filing instructions for
the class contract) — nothing else besides those: never self-apply `ready`, and never
self-apply `blocked`, `parked`, or `other` either. Those three remain valid dispositions but are
researcher/triage-applied only, same reasoning as never self-applying `ready` — self-parking is a triage
decision. An agent that believes a filing is blocked or parkable says so in the issue body, for the triage
pass to act on.

**Invariant:** every open Issue is EITHER unlabeled (= awaiting a disposition decision) OR carries
**exactly one** disposition. Enforcement flags only an Issue with two-or-more.
<!-- DISPOSITIONS:END -->
