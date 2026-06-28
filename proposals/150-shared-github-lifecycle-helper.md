# Proposal: shared GitHub-lifecycle helper — the seam both ship-change and the experiment flow consume (#150)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.
> Doc-only design PR (a `needs-design` child of #130). Spawns `ready`/`blocked` children for the actual extraction.

## Problem

The "experiments through GitHub" epic (#130) decided that a research experiment should run through GitHub the
same way a scaffold change already does: an experiment is a branch, a PR, and two cross-family reviews posted to
that PR. But the GitHub plumbing that makes that work — figuring out *which* engineer bot identity to act as,
opening a draft PR, posting a cross-family review as a native APPROVE or a comment, and merging only after a gate
— already exists, and exists in exactly one place: `wf.sh`, the ship-change driver. If the experiment flow grows
its own copy of that plumbing, the two copies will drift, and a drift in the identity-or-review machinery is the
kind of bug that silently breaks the cross-family guarantee everything else rests on. So #130 decision 5 said:
do not fork `wf.sh` — extract the low-level primitives into a small shared helper that both flows call.

This issue (#150) is the design pass for that extraction. It is deliberately *only* design, because two of the
choices are genuinely open and getting them wrong is expensive: **where the shared helper lives** (it must not
create a dependency from the research runtime onto the build-tooling plugin, and it must not hand merge authority
to the read-only audit plugin), and **which primitives are "merge-authority" code that must load from a trusted
source rather than from the branch being reviewed** (the same trust hole `wf.sh` already closes for its reviewer
via `locate_audit`, now widened because the helper itself can open and merge PRs). This doc fixes the helper's
public contract — its function surface, its trust split, its host, and its rollback — so the consuming children
(#156 `design-experiment` PR-open, #157 `run-experiment` close + merge) and the `wf.sh` refactor can be written
against a stable interface instead of inventing one each.

## Approach

Extract the GitHub-lifecycle primitives out of `wf.sh` into a single shared library, `gh-lifecycle.sh`, that
both `wf.sh` (ship-change) and the experiment flow source. The library is **mechanism only** — it knows how to
resolve an engineer identity, open a draft PR, post a review, and run the merge gate, but it knows *nothing*
about ship-change's disposition close-gate or the experiment flow's research audits. Each consumer keeps its own
gates layered on top and calls down into the shared mechanism for the GitHub parts. After extraction `wf.sh`
becomes a thin consumer of the same library the experiment flow uses, so there is exactly one implementation of
the identity + review-posting machinery and no second copy to drift.

The contract has four parts: **(1)** a stable function surface the library exports; **(2)** a trust split that
marks some of those functions *merge-authority* — they must load their code from a trusted base ref, never from
the branch under review — and ships a poisoned-helper smoke that proves the split holds; **(3)** a host for the
library that is neither the build plugin nor the read-only audit plugin; and **(4)** a rollback path that keeps
`wf.sh` working throughout and lets the extraction be reverted as one unit before any experiment PR depends on
it. The cross-family *enforcement* logic stays where it already lives — the helper carries the identity and
posting mechanics, but it does not become a second home for the "is this reviewer the opposite family" check
(that boundary is owned by #154 and is explicitly out of this helper's scope; see *Blast radius*).

### 1. The function surface — what the library exports (the public contract)

The primitives below are what #156 and #157 will call. Names are the contract; signatures are
shell-function-shaped (positional args, stdout result, non-zero = fail-closed) to match how `wf.sh` already
factors these. The grouping into **runtime** vs **merge-authority** is decision 2; it is shown here so the
surface and the trust split read together.

**Identity + auth (runtime).** Resolve and mint the engineer-bot identity for a given family, fail closed when
a named identity is required and missing — today `engineer_token`, `engineer_token_cmd`, `engineer_token_seam`,
`engineer_git_author`, `family_suffix`, `opposite_family`, `reviewer_token`, `author_token_optional`,
`gh_author`, `git_push_author`. These move verbatim. They are runtime: they decide *who acts*, but the act of
minting a token from a configured command is not itself merge-gate logic that a branch could subvert.

**PR open + body rendering (runtime).** Open a draft PR for a branch and render its human-facing body —
`render_pr_body`, `section_text`, `first_paragraph`, `markdown_details`, `markdown_code_details`. Runtime: a PR
body is descriptive, not gate-bearing.

**Review posting (runtime mechanics over a merge-authority verdict).** Post a review to a PR as the
opposite-family identity, choosing native-APPROVE vs REQUEST_CHANGES vs COMMENT and binding the review to the
exact head SHA — the posting half of today's `run_review` plus `review_summary_text`. The *posting* is runtime;
the *verdict it posts* and the *reviewer it runs* come from merge-authority code (next group). The split inside
`run_review` is the substance of decision 2 and is spelled out there.

**Merge gate (MERGE-AUTHORITY).** Locate the cross-family reviewer from a trusted base ref (`locate_audit`,
`audit_from_base_ref`), run it under a bounded wait (`run_verifier_bounded`), parse the authoritative
`SUMMARY:` verdict fail-closed (`require_valid_review`, `count_high/med/low`, `count_all`, `sum_line`), and the
final-SHA re-review + zero-HIGH merge decision. These are the functions a poisoned branch must not be able to
supply for itself; they are the merge-authority set (decision 2).

**Repo/branch helpers (runtime).** `gh_repo`, `wt_branch`, `base_ref`, `wt_pr`, `require_clean`,
`main_checkout`, `need_gh`, `need_ambient_gh`. Plumbing both consumers need.

What stays in `wf.sh` (NOT extracted): the disposition close-gate (`disposition_gate`, the `ready` /
`needs-design` issue contract), the finding-disposition state machine (`fd_*`, #137/#139), the classifier
invocation, and the `--design` doc-only diff guard. These are ship-change policy, not shared mechanism. The
experiment flow has its own analogues (the triage-artifact schema #151, the design-clearance schema #145) and
must not inherit ship-change's. **This is the load-bearing line of the whole extraction: the library is the
GitHub *mechanism*; each flow keeps its own *policy*.**

### 2. The trust split — merge-authority code loads from a trusted source, never the branch under review

`wf.sh` already closes one instance of this hole: a ship-change PR that edits the verify-claims reviewer cannot
run its own branch-modified reviewer as its merge gate, because `locate_audit` resolves the reviewer from the
*base ref* (trusted-but-current, #69), not from the worktree. Extracting the helper *widens* the exposure: the
helper now also carries PR-open and merge-posting authority, so a branch that edited `gh-lifecycle.sh` could, if
the driver sourced the branch copy, run its own modified open/merge logic as its own gate.

The split:

- **Merge-authority functions** (the merge-gate group above) must be resolved from the **trusted base ref /
  install**, exactly as `locate_audit` already resolves the reviewer — never from the worktree under review. The
  decision **inside `run_review`** is the precise seam: the *verdict computation* (locate reviewer, run it,
  parse `SUMMARY:`, the zero-HIGH gate) is merge-authority and loads from trusted source; the *posting*
  (formatting the comment, calling `gh api .../reviews` as the bot) is runtime and may run from the branch copy.
  Concretely, the consuming driver sources its merge-gate functions through the same base-ref materialization
  `audit_from_base_ref` already implements (cache under the git-common-dir keyed by the base commit), so the
  merged behavior is the reviewed behavior.
- **Runtime functions** (identity, PR-open, body rendering, posting mechanics, repo helpers) may run from the
  branch copy. They do not decide whether a PR merges; a branch editing its own PR-body renderer changes only
  cosmetics, and identity is gated by the configured token-minting command, not by branch code.
- **Poisoned-helper smoke.** Ship a smoke test matching `locate_audit_smoke.sh`: construct a branch that edits
  `gh-lifecycle.sh`'s merge-authority code to a known-bad behavior (e.g. force `count_high` to return 0), run
  the gate, and assert the gate used the trusted-base copy (the poison did NOT take effect). This is the
  mechanical proof the split holds, and it is a deliverable of the extraction child, run by `.aar-ci/checks.sh`.

The split is drawn at the function level rather than file level so the runtime/merge-authority boundary survives
future edits: a new function lands on one side of the line explicitly. The extraction child (decision: a
`ready` child, because *this doc settles which functions are merge-authority*) implements the base-ref
materialization for the merge-authority set and the smoke; the boundary itself is no longer open design.

### 3. Host — a neutral GitHub-lifecycle runtime helper, not the build plugin, not the audit plugin

#130 fixed the two negative constraints; this doc picks the host. The constraints:

- **Not `aar-engineering`.** That is the *build-the-product* plugin (installed only by scaffold developers via
  ship-change). The research runtime — `experiment-lifecycle` / `run-experiment` — must take **no** dependency
  on the build-tooling layer, or every research instance would have to install the build plugin to run an
  experiment. (`AGENTS.md` "Two layers": the SWE pipeline that *builds* the product vs. the research product it
  *ships*.)
- **Not `verify-claims`.** That plugin is the **read-only** adversarial-audit engine — it *produces* audit
  findings and is deliberately given no mutation authority. Handing it draft-PR creation, identity minting, and
  merge authority would make the read-only plugin own write/merge it has no business owning, and would couple
  the audit engine to GitHub plumbing it is correctly ignorant of today.

**Decision: a new dedicated plugin, `aar-github-lifecycle`, exporting one library `scripts/gh-lifecycle.sh`.**
A dedicated plugin (rather than folding the library into an existing runtime plugin like `experiment-lifecycle`)
is chosen because: **(a)** it has exactly one well-scoped job — the GitHub mechanism — and both consumers
(`aar-engineering`/ship-change *and* `experiment-lifecycle`) sit *above* it, so it must not live *inside* either
consumer or it recreates the dependency-direction problem from a different angle; **(b)** a standalone plugin
gives the merge-authority code a clean, independently-versioned home that the trusted-base materialization
(decision 2) can target by name; **(c)** it makes the rollback (decision 4) a single revertible unit. The
plugin ships only the library + its smoke + a thin `.aar-ci` hook; it has no skills of its own (it is consumed,
not invoked by an agent). The exact in-repo path (`plugins/aar-github-lifecycle/`) and how each consumer locates
it (sourced via a stable relative/install path, with the merge-authority subset re-resolved from base ref per
decision 2) are settled here as the contract; the extraction child implements them.

### 4. The contract for the #130 consumers

This is the interface #156 and #157 are `blocked-by`. They consume the helper as:

- **#156 (`design-experiment` PR-open + `--design` posting + fact-record linking):** uses identity-resolution +
  PR-open + review-posting (runtime) to open the experiment's draft PR and post the `audit_experiment --design`
  review as a COMMENT (the design review is *not* merge-satisfying per #130 decision 2 — it gates the run, not
  the merge). It does NOT call the merge gate.
- **#157 (`run-experiment` push + close-review + merge):** uses identity + posting (runtime) to push records and
  post the close `audit_experiment` review, and the **merge gate** (merge-authority) for the final-SHA
  re-review + zero-unresolved-HIGH decision — the experiment flow's own triage gate (#151) layered on top of
  the shared zero-HIGH mechanism, the same way ship-change layers its disposition gate.

Both call the *same* identity + posting code `wf.sh` uses, so the cross-family attribution and SHA-binding are
identical to ship-change's by construction. Neither consumer re-implements GitHub plumbing; each supplies its
own policy gate above the shared mechanism. The cross-family *family check* on the audit rungs those consumers
run is **not** the helper's job — it is #154's (audit-runner cross-family contract); the helper only carries the
identity/posting mechanics and the merge-authority trust split.

## Alternatives considered

- **Fork the GitHub glue into `experiment-lifecycle` (no shared helper).** Rejected by #130 decision 5 and
  re-confirmed here: two copies of the identity + review-posting machinery guarantee drift, and a drift there
  silently breaks the cross-family guarantee. The whole point of #150 is to avoid this.
- **Host the helper in `aar-engineering`.** Rejected: makes the research runtime depend on the build-tooling
  plugin (#130's explicit negative constraint). Every research instance would have to install the build plugin.
- **Host the helper in `verify-claims`.** Rejected: that plugin is read-only by design; giving it draft-PR /
  identity / merge authority is the wrong seam (#130 constraint).
- **Fold the library into `experiment-lifecycle` (a consumer) instead of a dedicated plugin.** Rejected: one of
  the two consumers (ship-change, in `aar-engineering`) would then depend on the *other* consumer's plugin —
  the same dependency-direction problem, just rotated. The shared mechanism belongs below both consumers.
- **Draw the trust split at the file level (whole helper is merge-authority, always base-ref).** Rejected:
  over-broad — it would force the cosmetic PR-body renderer and the identity minter through base-ref
  materialization for no security benefit, and a future runtime-only function would inherit a constraint it
  doesn't need. The function-level split (decision 2) keeps the merge-authority set minimal and explicit.
- **Big-bang refactor (move everything, delete the `wf.sh` copies in one PR with no shim).** Rejected: `wf.sh`
  is the machinery every future scaffold change depends on; a regression there blocks *all* shipping. The
  rollout (below) keeps `wf.sh` behavior-identical behind the extraction and makes the change one revertible
  unit (decision 4 / *Rollout*).

## Blast radius

- **New plugin** `aar-github-lifecycle` (`scripts/gh-lifecycle.sh` + poisoned-helper smoke + thin `.aar-ci`
  hook). No skills; consumed, not invoked.
- **`aar-engineering` / `wf.sh`** is refactored to source the shared library instead of carrying its own copies
  of the extracted primitives. This is the one cross-cutting edit #130 flagged. `wf.sh`'s public subcommand
  surface (`start`/`open`/`design-review`/`code-review`/`classify`/`finish`/`issue`/`comment`/`doctor`/`fdispo`)
  is **unchanged** — the refactor is internal. The disposition gate, `fd_*` state, classifier, and `--design`
  guard stay in `wf.sh` (decision 1).
- **`experiment-lifecycle`** (`design-experiment` / `run-experiment`) gains a *new* dependency on the shared
  helper — wired by the consumer children #156 / #157, not by this extraction. This doc only fixes the contract
  they consume.
- **Explicitly NOT in scope (owned elsewhere):** the cross-family *family-check* enforcement on the four
  audit rungs is **#154**'s (audit-runner cross-family contract) — the helper carries identity/posting mechanics
  and the merge-authority trust split, not the family check. The experiment triage-artifact schema is **#151**;
  the design-clearance schema is **#145**; the canonical record path is **#155**. The helper touches none of
  their contracts; it sits below them.
- **Product vs instance:** the helper and the `wf.sh` refactor are **product** (scaffold). The experiment PRs
  the consumers eventually produce land in the **instance research repo**, resolved via the instance-profile
  contract (#153) — the helper takes repo/identity as inputs, hardcodes nothing.

## Rollout + rollback

Doc-only design PR (this one): lands the contract on `main` via the `--scaffold` gate, then spawns the
extraction child(ren). Staging of the *implementation*:

1. **Land the new plugin + the `wf.sh` refactor in one PR, behavior-identical.** The extracted library is
   sourced by `wf.sh`; the merge-authority subset is materialized from the trusted base ref (decision 2); the
   poisoned-helper smoke and the existing `locate_audit_smoke` both pass; `wf.sh`'s subcommand surface and
   output are unchanged. This PR ships through ship-change's *own* `--code` gate — i.e. the machinery refactors
   itself under its current gate, the safest order (the new code is exercised by ship-change *before* any
   experiment PR depends on it). Note the bootstrap subtlety the trust split makes explicit: because this PR
   edits merge-authority code, its *own* merge gate runs the **base-ref** (pre-change) copy — the new
   behavior is only ever exercised by ship-change runs *after* it lands, which is the intended trust property,
   not a gap.
2. **Only after (1) is merged and a ship-change run has exercised the shared library** do the experiment
   consumers (#156 / #157) wire to it. The experiment-PR path is not made default in `run-experiment` until
   it has been piloted on a single real experiment (per #130's staged rollout).

**Rollback.** The extraction is one squash commit on `main` (the plugin add + the `wf.sh` refactor). Revert it
with the standard one-command revert (RUNBOOK "One-command revert"): `wf.sh` falls back to its own in-file
copies of the primitives (the revert restores them) and ship-change keeps working with zero data loss, because
the refactor is behavior-preserving and no experiment PR depends on the helper until step 2. Reverting *after*
step 2 additionally requires reverting the consumer wiring (#156/#157), so the consumers are filed `blocked-by`
this extraction precisely to keep the dependency order — and the rollback order — linear. The standalone-plugin
host (decision 3) is what makes the extraction a single revertible unit.
