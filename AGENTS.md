# automated-researcher — development conventions (agent-facing)

This repo is the PRODUCT: modular agent skills for automated research, developed here in their public shape even
while the repo is private. A consuming instance is the deployment that imports this repo through plugin installs,
source checkouts, symlinks, or thin local wrappers. The product never depends on a particular instance. Each
consuming instance owns its own transition map, local paths, credentials, run records, launch/reload machinery,
and deployment guidance.

## Two layers in this repo: the product and its SWE pipeline

This repo holds **two layers** — same repo, different concerns:

1. **The product** — the shipped research plugins (`gpu-job`, `verify-claims`, `experiment-lifecycle`): the
   automated-researcher scaffold that turns a coding agent into an autonomous researcher. Quality bar: *is the research valid.* Customer:
   the alignment researcher.
2. **The SWE pipeline** — the engineering layer that builds, reviews, tests, and ships the product
   (`aar-engineering`, `tests/`, CI). Quality bar: *does the product's machinery work and not regress.* Customer: us.

This is the ordinary product-`src` + `tests`/CI split every software repo has — NOT a separate repo (one product →
one repo; revisit multi-repo only when a piece ships independently). It is **agentic at both levels**: agents *do*
the research (product), and agents *build / test / ship* the thing that lets agents do the research (SWE pipeline).

**Who runs the SWE pipeline: the agents ARE the engineers.** Every Claude Code / Codex instance is an engineer on
the team (with its own GitHub identity). They author changes, **cross-family-review** each other's PRs (a foreign
family is the safeguard — "AARs are peers" realized in the build), **approve**, and **merge** — the routine
review → approve → merge loop is theirs to run. The human is the **staff-engineer / PM**: sets direction (the Issue
backlog), gates the **architectural design** (the high-taste "together" moment), oversees and can intervene on
anything — but is NOT a gate on routine code merges. This **mirrors the research pipeline exactly**: design *with the
human* (architectural), execution *by the agents* (here: code review → approve → merge). What makes agent self-merge
safe: the foreign-family review (catches blind spots), the deterministic checks + behavior smoke, the human's audit
of the durable trail (GitHub PRs / comments / history), and one-command revert.

**Don't conflate the two quality gates.** `verify-claims` is shared infrastructure used by both: its cross-family
review serves the **product** (`--design` / `--data` / close = experiment audits) AND the **SWE pipeline**
(`--scaffold` design review + `--code` PR review). Same capability, wired into both layers; neither substitutes for
the other.

**Two orthogonal cuts to keep straight:** *product vs instance* (this repo vs any consuming deployment that uses
it) and *product vs SWE pipeline* (within this repo: the shipped research plugins vs the `aar-engineering` layer
that builds them).

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
- **Bounded background waits — silence is not progress.** Any wait on background or external work (a
  `run_in_background` task, a detached driver, a poll loop, a review/verifier subprocess) MUST have three
  things, or it can hang forever with nothing erroring (orchestrator#2: a `ship-change` review blocked on
  stdin and never returned — completion-only notifications never fired, the watcher grepped only the success
  string, no deadline): (1) a **deadline** — a time bound the wait exits on, not only the success marker;
  (2) a **liveness / positive-progress check** — process alive AND output advancing ("no done-marker yet"
  can't distinguish working from wedged); and (3) a **failure/timeout path that wakes the agent or fails
  visibly** — the watcher emits on *stuck*, not only on *done*, and a tripped deadline is acted on, never
  silently re-waited. The worked, substrate-specific instance for autonomous detached experiment runs is
  `run-experiment`'s self-wake (done-marker + liveness + positive-progress + look-again deadline); the
  `ship-change` reviewer-latency thresholds and the `wf.sh` `WF_REVIEW_TIMEOUT` cap are this rule applied to
  the SWE-pipeline review wait. Each waiting surface restates the minimal rule at point of need (this is the
  editorial home), so it never depends on this file being installed.
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

<!-- DISPOSITIONS:START -->
## Issue tracker — dispositions

Every open Issue carries a **disposition** — how it should be handled — orthogonal to its type
(`bug`/`enhancement`/…) and to open/closed. This is the definition (the product-owned, versioned part). The
assign-at-filing and maintain *procedures* live in the appropriate operating surface: reusable product feedback
machinery belongs in product skills, while deployment-only file bookkeeping belongs in consuming-instance
guidance. AGENTS.md holds the issue contract, not local workflow paths.

- **`ready`** — actionable now, with **no unresolved design** (this refines #74's initial "low-blast"
  wording: a design-derived child can touch architectural surfaces and still be `ready` because its design is
  settled). Implement + merge on the cross-family review + checks. `ready` is the only disposition **eligible**
  for auto-handling — but eligibility is not blind auto-merge: the auto-handler still runs the full
  cross-family review + checks, and the precise boundary of which `ready` Issues it acts on autonomously
  (especially by blast radius) is #49's to define.
- **`needs-design`** — real, but needs a design pass first (the two-phase design flow: a design PR spawns
  `ready` children). Not implemented directly.
- **`needs-shaping`** — a direction, too vague to start; needs scoping into `ready`/`needs-design` first.
- **`blocked`** — decided but gated on a prerequisite; carries a `blocked-by: #N` body line. (When the
  blocker closes, triage clears the label so it's re-dispositioned, usually to `ready`.)
- **`parked`** — real but deliberately not-now; revisit later. (Distinct from `wontfix` = never.)
- **`other`** — doesn't fit the five; a recurring `other` is the signal to evolve the vocabulary.

**Invariant:** every open Issue is EITHER unlabeled (= untriaged, awaiting triage — distinct from
`needs-shaping`) OR carries **exactly one** disposition. Enforcement flags only an Issue with two-or-more.

**Design → implementation link:** a `needs-design` Issue is closed when its design lands (the design PR);
that design spawns `ready` children, each carrying a **`design: #<design-issue>`** body pointer. Code PRs
close `ready` Issues, never a `needs-design` Issue directly.
<!-- DISPOSITIONS:END -->
