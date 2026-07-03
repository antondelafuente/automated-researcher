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
safeguard — "AARs are peers" realized in the build), **approve**, and **merge**. The human is the
**staff-engineer / PM**: sets direction (the Issue backlog) and shapes it (`needs-shaping → ready`), oversees
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
  pipeline's one engineer-token path (`WF_ENGINEER_TOKEN_CMD_*`). An instance may keep a thin
  `gh-as-engineer` alias that delegates to it, but there's a single token implementation. The rule covers
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

Standing dispositions for how an AAR agent interacts with the researcher while doing actual research
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
- **Conclusions vs postdictions.** A pre-registered conclusion is kept separate from an explanation fitted to
  the results after the fact (a postdiction); a load-bearing postdiction gets tested on fresh data before it's
  trusted. (Mechanics: `design-experiment`'s data-vs-verdict split, `run-experiment`'s close step, and
  `verify-claims`' close-audit dimension — already implemented end to end; this is the definition, not a new
  copy.)
- **Validity/comparability is the main failure mode.** The silent failure is a clean pipeline producing a
  confidently-wrong number: compared numbers must be on the same scale, measuring the same thing. This is the
  standing disposition behind the audit gates. (Mechanics: `verify-claims`' design/data/close audits.)
- **Every AAR is either a user or the maintainer, never both at once — separated in time.** During research
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
- **`needs-shaping`** — a direction, too vague to start; needs scoping into `ready` first, through a
  conversation with the researcher (which may produce a few `ready` tickets).
- **`blocked`** — decided but gated on a prerequisite; carries a `blocked-by: #N` body line. (When the
  blocker closes, triage clears the label so it's re-dispositioned, usually to `ready`.)
- **`parked`** — real but deliberately not-now; revisit later. (Distinct from `wontfix` = never.)
- **`other`** — doesn't fit the others; a recurring `other` is the signal to evolve the vocabulary.

**`needs-shaping → ready` is the researcher's transition, in every lane.** An agent records the flip only on
the back of an actual researcher conversation, and the flip must **cite it** — a comment on the issue
summarizing/linking the shaping discussion. An agent asked to *implement* an issue never flips its disposition
label as a step of implementing it — that would let it triage its own way in. This is a norm every lane
follows; a lane's mechanical *enforcement* of it (e.g. a pre-flight before work starts, vs. a gate only at
close) is that lane's own concern to build out.

**Invariant:** every open Issue is EITHER unlabeled (= untriaged, awaiting triage — distinct from
`needs-shaping`) OR carries **exactly one** disposition. Enforcement flags only an Issue with two-or-more.
<!-- DISPOSITIONS:END -->
