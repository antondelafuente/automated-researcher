# Proposal: GitHub-native SWE pipeline (BYOK) — implement-on-ready + review-on-PR (#378)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.
> This transcribes automated-researcher#378 (spec v2, post ask-codex; cross-family-reviewed pre-dispatch,
> record on agentic-engineering#43) into the ADR shape. The issue body is binding; this doc does not
> redesign it, only fills in the concrete pins/identities/schemas the spec asked the implementor to resolve.

## Problem

Today, shipping a scaffold change to this repo runs through `ship-change`'s tmux-dispatcher machinery: a
human/dispatcher session launches a one-shot implementor in a tmux pane, watches it on a ~5-minute cadence,
nudges it if wedged, and reaps it after merge. That's real supervision cost per change
(automated-researcher#364 is the worked example) and it makes the "premium session must not implement"
rule a matter of prose + memory rather than infrastructure.

GitHub Actions can make the SWE pipeline event-driven instead: a `ready` label is already the researcher's
signal that an Issue is actionable (see AGENTS.md "Issue tracker — dispositions"). This proposal wires that
label to launch an execution-tier implementor directly in Actions, and wires PR events to run the
cross-family review natively, so `ready` → merged PR happens with no session dispatching it.

## Approach

Two pinned GitHub Actions workflows, BYOK (bring-your-own-key) vendor actions running as the existing
engineer-bot identities:

- **`implement-on-ready`**: `issues: labeled` (label == `ready`) + `workflow_dispatch` → runs
  `anthropics/claude-code-action` (execution-tier Sonnet) against the issue, prompted to implement in a
  branch and open a PR that closes the issue.
- **`review-on-pr`**: `pull_request` (opened/synchronize/ready_for_review), gated to PRs authored by the
  claude engineer bot → runs `openai/codex-action` for the cross-family review, then a trusted step submits
  a native APPROVE (clean) or REQUEST_CHANGES (findings) as the codex engineer bot.
- Existing branch protection (required opposite-family approval) + auto-merge close the loop unchanged.

### Trust & secret-isolation model (binding, from the issue)

- Private repo; write access = the researcher (`antondelafuente`) + the two engineer GitHub Apps. Exact
  bot identities, confirmed from this repo's PR history (PR #367): author/git identity
  **`claude-code-engineer[bot]`**, review/approval identity **`codex-engineer[bot]`**.
- **Authorization predicate for a privileged run:** `issues: labeled` with `label.name == 'ready'` AND
  `github.event.sender.login` allowlisted AND the issue author allowlisted. Allowlist (hard-coded in the
  workflow) = `antondelafuente`, `claude-code-engineer[bot]`, `codex-engineer[bot]`.
  `workflow_dispatch` (issue-number input, actor must be allowlisted) is the only other entry path.
- **Credential split:** the agent job holds `ANTHROPIC_API_KEY` + a short-lived App installation token
  minted in-run via `actions/create-github-app-token` (from `CLAUDE_APP_ID` + `CLAUDE_APP_PRIVATE_KEY`).
  Control-plane operations (auto-merge enable) run as the same App token but are the action's own final
  steps — no separate `GITHUB_TOKEN` is used for anything the App token should own.
- **Accepted residual risk (goes into AGENTS.md verbatim):** the implementor agent executes repo-controlled
  code (tests, hooks) while holding its API key and short-lived token. Acceptable on a private single-author
  repo; revisit before adding outside collaborators.
- **Pins.** Every third-party action pinned by full commit SHA, resolved today (2026-07-11) from each
  action's GitHub tags API:
  - `actions/checkout` → `v6` (used to check out the base ref before both agent actions)
  - `actions/create-github-app-token` → `v3.2.0` = `bcd2ba49218906704ab6c1aa796996da409d3eb1`
  - `anthropics/claude-code-action` → `v1.0.170` = `536f2c32a39763739000b0e1ac69ca2647d97ce9`
    (well above the v1.0.94 issue-injection security fix cited in agentic-engineering#43)
  - `openai/codex-action` → `v1.11` = `52fe01ec70a42f454c9d2ebd47598f9fd6893d56`
  - SHAs + the version they correspond to are recorded in the PR description (Deliverable per the issue).
- **Never `pull_request_target` with a code checkout.** `review-on-pr` runs on plain `pull_request` for
  same-repo branches only; fork PRs (`github.event.pull_request.head.repo.full_name != github.repository`)
  are skipped explicitly before any secret-bearing step runs.

### Deliverable 1 — `.github/workflows/implement-on-ready.yml`

- `on: issues: { types: [labeled] }` + `workflow_dispatch: { inputs: { issue_number } }`.
- Job `if:`: (labeled path) `github.event.label.name == 'ready'` AND sender allowlisted; (dispatch path)
  actor allowlisted. First step re-fetches the issue and re-verifies its author is allowlisted — fails
  loudly (job failure, visible in the Actions run) otherwise, before any token is minted.
- `concurrency: group: implement-issue-${{ inputs.issue_number || github.event.issue.number }}` — per-issue
  dedup only. **No global cap in v1** — GitHub `concurrency` is not a worker pool; the spend guard is the
  researcher's deliberate one-at-a-time `ready` flip. This limitation is documented in AGENTS.md, not
  worked around (per the issue's explicit instruction).
- Steps: mint the claude App token (`actions/create-github-app-token@<sha>`, `CLAUDE_APP_ID` +
  `CLAUDE_APP_PRIVATE_KEY`, scoped to this repo) → checkout base ref → run
  `anthropics/claude-code-action@<sha>` with:
  - `anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}`
  - `github_token: <minted claude App token>` (so every git/gh operation — branch, commits, `gh pr
    create` — runs as `claude-code-engineer[bot]`, not the ambient `GITHUB_TOKEN`)
  - `prompt:` committed at `.github/prompts/implement.md`, filled with the issue number/repo (agent mode —
    providing `prompt` puts the action in automation mode, no `@claude` mention needed)
  - `claude_args: --model claude-sonnet-5` + tool access broad enough to implement (Bash/Edit/Write/Read/
    Grep/Glob) — matches the accepted-risk statement above.
  - `base_branch: main`, `branch_prefix: agent/` so the working branch is `agent/issue-378`-shaped
    (`agent/issue-<n>`).
- Post-step (control-plane, same App token, `if: always()` guarded on the PR having been created): enable
  auto-merge (`gh pr merge --auto --squash`) on the created PR; on failure (auto-merge disabled repo-wide,
  missing permission) comment instead of failing the job.
- Escalation: the prompt instructs the implementor that if it's blocked, or if implementing would
  contradict what the issue specifies, it labels the PR (or issue, if no PR yet) `needs-dispatcher` +
  comments what's needed, then stops. This ticket only defines the label convention (per the issue's
  explicit out-of-scope note — the notifier is instance wiring).
- Re-entry: documented in AGENTS.md — re-dispatch = remove and re-add `ready`, or `workflow_dispatch`.
  Post-review fixes ride the existing claude-code-action PR-comment mention flow (a *separate*, pre-existing
  action capability — allowlisted comment authors only), not a new workflow.

### Deliverable 2 — `.github/workflows/review-on-pr.yml`

- `on: pull_request: { types: [opened, synchronize, ready_for_review] }`.
- Job `if:`: skip when `github.event.pull_request.head.repo.full_name != github.repository` (fork PRs) OR
  `github.event.pull_request.user.login != 'claude-code-engineer[bot]'` (agent-PR predicate — exact App
  actor login, not a title/label/branch-prefix match; human PRs keep the existing manual review path).
- `concurrency: group: review-pr-${{ github.event.pull_request.number }}, cancel-in-progress: true` — a
  `synchronize` cancels stale review work.
- Steps: capture `head_sha: ${{ github.event.pull_request.head.sha }}` → checkout that ref (read-only,
  `permission-profile: ":read-only"`, no write scope on this step) → run `openai/codex-action@<sha>` with
  `openai-api-key: ${{ secrets.OPENAI_API_KEY }}`, a `prompt` embedding the diff range + this repo's
  AGENTS.md review guidance (P0/P1, below), and an `output-schema` forcing structured JSON:
  ```json
  {"type":"object","required":["verdict","findings"],"properties":{
    "verdict":{"enum":["approve","changes_requested"]},
    "findings":{"type":"array","items":{"type":"object","required":["severity","summary"],
      "properties":{"severity":{"enum":["P0","P1"]},"summary":{"type":"string"},
      "evidence":{"type":"string"}}}}}}
  ```
  `verdict` is `approve` iff there are zero `P0` findings (mechanical rule the trusted step enforces itself
  — it does not trust the model's self-reported `verdict` field alone).
- A **trusted step** (no repo code, only `actions/github-script` + the mechanical rule above) parses
  `codex-action`'s `final-message`/structured output: if zero P0 findings, mint the codex App token,
  **re-verify the PR's current head SHA still equals the captured `head_sha`** (guards a `synchronize` race
  between review start and approval), then submit a native `APPROVE` review bound to that SHA via the REST
  API (not `gh pr review` with the ambient token). If P0 findings exist (or the head moved), submit
  `REQUEST_CHANGES` with the findings listed, as the codex bot.
- Approval and authorship are distinct App identities (`codex-engineer[bot]` approving
  `claude-code-engineer[bot]`'s PR) — branch protection's required-opposite-family-approval holds, and
  self-approval is structurally impossible (the two Apps have separate keys/tokens).

### Deliverable 3 — docs

- **`AGENTS.md`** gains a section: the flow (`ready` → agent PR → codex review → auto-merge), the
  authorization predicate, the accepted-risk statement, the concurrency-is-not-a-queue limitation, re-entry
  semantics, `needs-dispatcher` escalation, and the **Codex review guidance (P0/P1 convention)**:
  - **P0 (blocking):** correctness bugs that break the change's stated purpose, security issues (secret
    exposure, injection, privilege escalation, trust-boundary violations), or a violation of this repo's
    `AGENTS.md` rules. Blocks `APPROVE`.
  - **P1 (non-blocking):** style, minor edge cases, suggestions, simplification opportunities — recorded on
    the review for the author/researcher to read, never blocks merge.
  This mirrors the existing `--code` review's HIGH/MED/LOW convention (`ship-change` SKILL.md) at native
  GitHub-review granularity: P0 ≈ HIGH, P1 ≈ MED/LOW collapsed to one non-blocking tier (the native review
  UI has no room for three tiers without inventing more machinery than a two-workflow v1 needs).
- **`.github/prompts/implement.md`**: the implementor prompt (versioned, reviewable in-repo) — instructs
  treating the issue body + all comments as the complete spec, working on `agent/issue-<n>`, running
  `.aar-ci/checks.sh` before opening the PR, opening a PR titled from the issue with `Closes #<n>`, and the
  escalation rule (labels `needs-dispatcher` + comments, then stops, on any contradiction/block).

### Deliverable 4 — secrets checklist (goes in the PR description; researcher adds values)

`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `CLAUDE_APP_ID`, `CLAUDE_APP_PRIVATE_KEY`, `CODEX_APP_ID`,
`CODEX_APP_PRIVATE_KEY` — values come from the box's existing engineer-App seam
(`~/.config/claude-code-engineer/`, `~/.config/codex-engineer/`: `app_id` + `key.pem` map directly to
`*_APP_ID` + `*_APP_PRIVATE_KEY`). Named in the workflows exactly as listed.

### Bootstrap test (goes in the PR description)

After merge + secrets are added: remove and re-add `ready` on issue #371 (label events don't fire
retroactively — this is why `workflow_dispatch` exists as a fallback). Done = #371's PR merges with zero
session involvement. This is post-merge researcher work, not part of this PR's smoke check (Actions
event-driven workflows can't be exercised by a local `.aar-ci/checks.sh` run).

### What ships in this PR vs. what's post-merge

This PR ships syntactically-valid, SHA-pinned YAML + prompt + docs. It cannot locally exercise the
label-event → Action → PR → review → auto-merge chain (that requires live GitHub Actions runs against real
App installations and API keys, which don't exist in a worktree checkout). The smoke check for *this* PR is
YAML validity (`actionlint` if available, else `python3 -c "import yaml; yaml.safe_load(...)"` per file) +
`.aar-ci/checks.sh` (unchanged, per the issue's explicit out-of-scope note). The live bootstrap test above
is the real end-to-end validation, and it is deliberately deferred to post-merge researcher action per the
issue.

## Alternatives considered

- **GitHub Agent HQ** instead of BYOK vendor actions — rejected 2026-07-10 with the researcher (recorded on
  agentic-engineering#43): Agent HQ would bend the opposite-family-approval machinery around agent identities
  we don't control, and lags on model availability. BYOK actions run as the *existing* engineer bots, so
  every identity/protection invariant carries over unchanged, and billing goes through reimbursable API
  keys we already hold.
- **Global concurrency pool/queue** for `implement-on-ready` — explicitly out of scope (issue body). The
  spend guard in v1 is the researcher's deliberate one-at-a-time `ready` flip; a queue is more machinery
  than a v1 needs and can be added later if flip cadence increases.
- **Comment-triggered re-entry** (a bespoke `/retry` comment command) — rejected in favor of the existing
  claude-code-action mention flow (already allowlist-gated) plus remove/re-add `ready` — no new trigger
  surface to secure.

## Blast radius

- **New files only** (this repo, product-adjacent but SWE-pipeline-owned): `.github/workflows/
  implement-on-ready.yml`, `.github/workflows/review-on-pr.yml`, `.github/prompts/implement.md`, an
  `AGENTS.md` addition. No existing file's behavior changes — `.aar-ci/checks.sh` is untouched per the
  issue.
- **Instance-owned, not touched by this PR:** the six GitHub Actions secrets (researcher adds values
  post-merge), the `needs-dispatcher` notifier, retiring `ship-change`'s tmux-dispatcher machinery, closing
  agentic-engineering#40/#41/#42, and the agentic-engineering copy of these workflows — all explicitly
  out of scope per the issue and left for follow-up work.
- **Does not touch** `experiment-lifecycle` or any research-execution path — this is SWE-pipeline-only,
  scoped to the two coding repos (this proposal ships automated-researcher; agentic-engineering is a
  separate follow-up per the issue).

## Rollout + rollback

- **Rollout:** merge this PR (workflows are inert with no secrets configured — `issues:labeled` fires but
  the job fails at token-mint with a clear "secret not found" error, not a silent wrong action). Researcher
  adds the six secrets. Bootstrap test: remove/re-add `ready` on #371.
  Until secrets are added, `ready` events on other issues will fail loudly in the Actions tab rather than
  degrading silently — no researcher action is required to keep the repo safe in the interim.
- **Rollback:** delete or disable the two workflow files (or set a workflow-level `if: false`) — no state
  to unwind, no data migration. Existing `ship-change` tmux-dispatcher path continues to work unmodified as
  a fallback (nothing about it was removed by this change) until an explicit later ticket retires it.
