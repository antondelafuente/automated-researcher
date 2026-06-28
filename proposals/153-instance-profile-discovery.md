# Proposal: Instance-profile discovery / init interface (#153)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.
> Part of the #130 "experiments through GitHub" cluster. Doc-only design PR (two-phase, Step 2); spawns
> `ready` implementation children. **No implementation here.**

## Problem

When a zero-context executor starts an experiment, it needs to know concrete instance facts that the product
skills deliberately do *not* hardcode: which GitHub repo the experiment record lands in, what branch it
forks from, which identity opens and merges the PR, and what the merge gate may require. Today those facts
live only as **narrative prose** inside the `run-experiment` skill — every "per your execution profile"
sentence points at an instance recipe the agent is expected to *know*, not at a file it can *read*. That was
acceptable while the gates produced local files in a shared tree. The #130 flow changes the contract: it
makes every experiment a branch + PR in an instance-configured repo, so an executor must now *resolve* a
repo slug, a base branch, a branch prefix, and a GitHub identity **before it can open the PR at all** — and
a narrative seam gives it nothing machine-readable to resolve. An agent that guesses these wrong opens the
PR in the wrong place, forks from the wrong base, or commits under the wrong identity, and the failure is
silent until a human notices the record landed somewhere unexpected.

This issue defines that missing interface: a **single machine-discoverable execution-profile config file**,
its **schema**, its **discovery rule** (where the executor looks and in what order), its **init owner** (who
writes it and validates it), and the **brief-snapshot rule** (how `START.md` freezes the resolved values so
the run is reproducible even if instance config later drifts). It is the contract the rest of the #130
cluster consumes; it ships no behavior of its own.

## Approach

Replace the narrative "execution profile" seam with one **declarative config file** at a discoverable path,
holding the instance's GitHub-lifecycle facts in a small, versioned schema. A zero-context agent (designer
or executor) discovers it by a fixed lookup rule, reads the fields it needs, and — at clearance time —
**snapshots the resolved values plus the config's content-hash into `START.md`**, so the run is reproducible
from the record alone even if the instance edits its config the next day. The product skills change from
"you know your profile" to "read `aar-profile`, field X"; the instance owns the file's *content*, the product
owns the *schema and the discovery/snapshot contract*.

Scope discipline: this file is the home for the **GitHub-lifecycle** facts the #130 flow needs to resolve
before it can act (repo, branch, identity, protection expectations) plus a typed pointer to the existing
provisioning/artifact/ledger/cost recipes. It is **not** a rewrite of every instance recipe into structured
config — the frozen GPU recipes, eval definitions, and bootstrap scripts stay where they are; the profile
just gives them a typed, discoverable anchor (`recipes:` block, decision 6) so the same lookup rule reaches
them. Schemas for the *artifacts the flow produces* (the triage record #151, the design-clearance record
#145, terminal states #152, redaction rules #146) are **owned by their own sibling issues**; this file only
declares *where* the flow operates and *who* it operates as.

The load-bearing decisions:

### 1. One declarative config file, in the owning module's config dir, discovered by a fixed rule

A single file — the **instance profile** — owned by the experiment-lifecycle module and living under that
module's config directory, per the AGENTS.md instance-value rule ("instance values … belong in each user's
`~/.config/<module>/` written by the module's init"). The discovery lookup order, so a zero-context agent
never guesses:

1. `$AAR_PROFILE` (explicit env override — the manual escape hatch and the test seam, **only**);
2. `${XDG_CONFIG_HOME:-~/.config}/experiment-lifecycle/aar-profile.{toml,json}` — the owning-module config
   home (this instance: `~/.config/experiment-lifecycle/aar-profile.toml`).

The executor resolves the **first** that exists, records *which* path resolved (into the snapshot, decision
4), and **fails closed** if none does — never falls back to a hardcoded repo/identity. "Fails closed" here
means: print a single `BLOCKED: no instance profile found (looked: <paths>)` line and stop before any GitHub
mutation or compute spend — the same fail-closed disposition `wf.sh start` already takes on a stale base. This
replaces the earlier `~/aar-profile.*` home-root location, which would have minted a *new* global config
convention in conflict with the module-config rule.

**Init owner (the validate seam).** The profile is written and validated by the experiment-lifecycle
module's **init/validate script** (`aar-profile-init` / `aar-profile-validate`, a `ready` child below), not
hand-authored ad hoc. `init` scaffolds the file at the module config path from the schema with the
instance's values; `validate` checks it against the schema (required fields present, types correct,
`schema_version` known, identity env vars *resolve to a runnable command*, `branch_prefix` matches #129's
`run/` convention) and is what the skills call before relying on the file. This is the "init owner" the issue
named: the module owns its config file's creation and validation, the same pattern `~/.config/<module>/`
already implies for the engineer Apps' keys.

**Helper packaging contract.** `experiment-lifecycle` exposes **two independently-installed skills**
(`design-experiment`, `run-experiment`), and the README/CI rule is that skills are symlinked per-skill
(`skills/<skill>`, not `skills/<module>`), so a module-level helper has no single install-resolvable home —
exactly the situation `feedback-loop` already faced. This design **follows the feedback-loop precedent**: the
init/validate + discovery/snapshot helper is **packaged in both skill dirs** (each skill references it
relative to itself, so either skill resolves it when installed alone), with the **deterministic drift check
in `.aar-ci/checks.sh`** (the same check that already guards feedback-loop's duplicated init helper) asserting
the two copies are byte-identical. The alternative — a separate shared runtime skill/plugin — is heavier than
this single shared file warrants and is what #150's shared-helper child exists to evaluate for the *GitHub
mutation* primitives; the *profile discovery* helper is small and read-only, so the per-skill-copy + drift-
check packaging is the right weight. (Specifying this is per design-review FINDING 1: the packaging contract
is fixed here, before implementation, not left to the child.)

**Format: TOML, plus stdlib JSON.** TOML is the recommended authoring format — unambiguous (no YAML
indentation/`norway` foot-guns), comment-friendly, stdlib-parseable (Python `tomllib`). The discovery rule
also accepts `.json` (stdlib `json`, zero extra dependency) for an instance that prefers it; **YAML is not
accepted** (it would add a parser dependency the design explicitly argues against). If both a `.toml` and a
`.json` exist at the module config path, **`.toml` wins** (deterministic precedence); `validate` warns on the
shadowed file.

### 2. The schema — exactly the fields the #130 flow must resolve

A flat, versioned schema. The **load-bearing** block is `github:` — without it the flow cannot open or merge
the PR. Everything else is a typed pointer to recipes that already exist.

```toml
schema_version = 1                       # integer; the executor refuses an unknown MAJOR (decision 5)

[github]
research_repo   = "owner/research-lab"   # REQUIRED. where experiment records land (DESIGN/RESULTS/gates)
base_branch     = "main"                 # REQUIRED. the branch experiment branches fork from + merge into
branch_prefix   = "run/"                 # REQUIRED. experiment branch namespace -> run/<exp> (matches #129)
issue_repo      = "owner/research-lab"   # OPTIONAL. where backlog issues live; defaults to research_repo
private         = true                   # REQUIRED (bool). asserts the repo's visibility; see decision 3

[github.identity]
# Token/author SEAMS, by reference — NEVER inline secrets (decision 7). Values name how to MINT, not the key.
token_cmd_env   = "AAR_RESEARCH_TOKEN_CMD"   # env var holding a command that prints a fresh token to stdout
git_author_env  = "AAR_RESEARCH_GIT_AUTHOR"  # env var holding "Name <email>" for commit attribution

[github.protection]
# REMOTE branch-protection EXPECTATIONS only — declared so the close-gate (#157) reads them, never probes
# blind. These may TIGHTEN the product's invariants for an instance; they can NEVER weaken a product invariant
# (cross-family review is a product constant, NOT a field here — see decision 3a / FINDING 3).
require_pr_review        = true          # branch protection requires an approving review before merge
enforce_admins           = true          # protection includes administrators (no standing bypass)

[recipes]
# TYPED POINTERS to the existing narrative recipes (decision 6). Not a rewrite — an anchor.
provisioning    = "recipes/provisioning.md"   # path (repo-relative) or URI the executor reads/links
artifact_store  = "recipes/artifact-store.md" # where artifacts persist (the R2/store policy)
ledger          = "recipes/ledger.md"         # the run ledger contract
teardown        = "recipes/teardown.md"       # teardown-key + delete-don't-stop policy
cost_policy     = "recipes/cost-policy.md"     # GPU-cheap / API-gated budget policy
```

Field semantics, normative:

- **`research_repo`, `base_branch`, `branch_prefix`** — the three the PR-open step (#156) needs to fork
  `run/<exp>` and target the right base. `branch_prefix` is `run/` to match #129's `run/<exp>` branch and
  worktree convention; the two MUST agree (cross-referenced below).
- **`issue_repo`** — present only when the experiment backlog lives in a different repo from the records;
  absent ⇒ same repo. Resolved by `issue_repo // research_repo`.
- **`private`** — an **assertion the gate verifies**, not the thing that makes the repo private. #146 (the
  sensitivity/visibility contract) owns *when* a repo must be private and what redaction applies; this field
  is the typed declaration #146's gate reads. If `private = true` but the live repo is public, the gate
  **fails closed** (decision 3) — this file states the expectation; #146 defines the enforcement.
- **`[github.identity]`** — names the **env vars that themselves hold a token-minting command / an author
  string**, never the secret. This mirrors `wf.sh`'s `WF_ENGINEER_TOKEN_CMD_*` / `WF_ENGINEER_GIT_AUTHOR_*`
  seams (RUNBOOK "Engineer identities"); the research flow gets its *own* seam names so the experiment-record
  identity is distinct from the scaffold-engineer identity and an instance can scope them differently.
- **`[github.protection]`** — what the executor's close-gate (#157) should *expect* the remote to require,
  so it can pre-check readiness instead of discovering a failed merge after the run. It is a **declaration of
  expectation**, not a configuration of GitHub; the actual protection is set out-of-band (RUNBOOK). It may
  only *tighten* (an instance can require more); it can never carry a knob that *weakens* a product invariant.
  Cross-family review is **not** a field here (decision 3a). A mismatch (the remote requires fewer reviews
  than declared) is the close-gate's fail-closed signal.

### 3. The profile *asserts*; the gates *enforce* — no enforcement logic lives here

This file is **discovery + declaration only**. It does not open PRs, mint tokens, post reviews, or block
merges. Each declared expectation has an enforcing owner elsewhere in the cluster, and this doc names the
seam without implementing it:

- `private` is enforced by **#146** (visibility contract): the gate compares the asserted `private` against
  the live repo and fail-closes on a public repo asserted private.
- `[github.identity]` seams are consumed by the **shared GitHub helper (#150)**, which mints the token and
  attributes the commit — exactly as `wf.sh` consumes its engineer seams today.
- `[github.protection]` expectations are read by the **close gate (#157)** and the **design-gate handoff
  (#156)** to pre-check readiness.
- The **cross-family** requirement on the model-judged rungs is enforced by **#154** (the audit-runner
  cross-family contract) as a **product invariant** — see decision 3a; it is deliberately **not** a profile
  field, so no instance config can switch it off.

### 3a. Cross-family review is a product invariant, never an instance field

Cross-family auditing (a change/run reviewed by the *opposite* model family) is a **validity invariant of the
product**, not an instance preference — #130 §5 and #134 make it fail-closed for exactly this reason. So the
profile carries **no `require_cross_family` knob**: an instance must never be able to declare its records
"reviewed" with a same-family judgment. #154 enforces cross-family in the audit-runner contract as a product
constant; `[github.protection]` may only assert *additional, tightening* remote requirements (more reviews,
admin enforcement), never a setting that could weaken or disable the cross-family guarantee. (An earlier
draft modeled `require_cross_family` as an instance-owned profile input — corrected per design-review FINDING
3: a product invariant does not live in instance config.)

This keeps the profile a *thin, inert contract* — the failure mode of a config file that also enforces is
that enforcement drifts from declaration; here the declaration is the single source of truth and every
enforcer reads it.

### 4. Brief-snapshot rule — `START.md` freezes the resolved values + a content-hash

The #130 promise is reproducibility from the record. Instance config can change between when an experiment is
designed and when (or if) it is re-examined, so the brief must **freeze** the values it resolved, not
re-resolve them live. At clearance time, `design-experiment` writes a snapshot block into `START.md`:

```
## Instance profile (snapshot — resolved at clearance, DO NOT re-resolve)
profile_path:    ~/.config/experiment-lifecycle/aar-profile.toml
profile_sha256:  <hash of the file's bytes at resolution>
schema_version:  1
# --- github (decision 2) ---
research_repo:   owner/research-lab
base_branch:     main
branch_prefix:   run/
issue_repo:      owner/research-lab
private:         true
# --- identity: the SEAM NAMES, not secrets (decision 7) ---
token_cmd_env:   AAR_RESEARCH_TOKEN_CMD
git_author_env:  AAR_RESEARCH_GIT_AUTHOR
# --- protection expectations the close-gate pre-checks (decision 2/3a) ---
require_pr_review: true
enforce_admins:    true
# --- recipe pointers: repo-relative path + the ref/hash that pins the version ---
recipe_provisioning:   recipes/provisioning.md@<git-sha>
recipe_artifact_store: recipes/artifact-store.md@<git-sha>
recipe_ledger:         recipes/ledger.md@<git-sha>
recipe_teardown:       recipes/teardown.md@<git-sha>
recipe_cost_policy:    recipes/cost-policy.md@<git-sha>
```

Normative rules:

- **The snapshot carries every NON-SECRET execution field the executor uses later** — not just the scalar
  repo facts. That includes the identity **env-var names** (`token_cmd_env` / `git_author_env` — names, never
  the token), the protection expectations the close-gate pre-checks, and the recipe pointers each pinned to a
  `path@<git-sha>` ref so the executor reads the exact recipe version the design cleared. (This corrects the
  earlier draft, which snapshotted only repo/base/prefix/issue/private yet forbade re-reading the live
  profile — design-review FINDING 1: the executor could not resolve identity/protection/recipes it was told
  it would need. Now everything non-secret is in the brief.)
- **The one narrow live step is secret resolution.** The executor reads the env var *named* in the snapshot
  (`token_cmd_env`) and runs that command to **mint a fresh token at use** — the only thing resolved live,
  because a token must never be frozen into a record (it expires, and it would be a leaked credential in the
  trail). Everything else comes from the snapshot. So: all *config* from the frozen snapshot; only the
  *credential* minted live, via the snapshotted seam name.
- The executor **never re-reads the live profile** for any GitHub-lifecycle config. The live profile is read
  **once**, at clearance, by the designer; the executor's world is the brief (matches the existing "your
  brief is your world" / START-template snapshot discipline).
- `profile_sha256` is the file's content-hash at resolution — the drift detector: anything later needing to
  know whether the run used the current config compares the hash. (Whether a *re-clearance* is forced on
  profile drift is **#145's** decision — the design-clearance schema owns re-clearance triggers; this issue
  only guarantees the snapshot carries the hash that makes that decidable.)

This extends the START template's existing "execution-profile snapshot/link" placeholder from prose into a
typed block; the seam is unchanged in spirit (decision aligns with #130 §3 "the brief snapshots the resolved
values").

### 5. Versioning — `schema_version`, refuse-unknown-MAJOR

`schema_version` is an integer; the product declares the schema version it understands. The executor
**refuses an unknown MAJOR version** (fails closed with a clear message) rather than reading a future field
layout it cannot interpret — the same fail-closed disposition as a missing file. Adding optional fields is a
**minor, backward-compatible** change (no version bump needed if a reader tolerates unknown keys); removing
or retyping a field is a MAJOR bump. The product ships a one-line "schema v1 fields" reference in the skill;
an instance that adopts a newer product reads the changelog for the bump. (Whether minor changes also carry a
sub-version is a small implementation call left to the schema-doc child — the load-bearing rule is
refuse-unknown-MAJOR.)

### 6. Recipes stay narrative, reached by typed pointer — not rewritten

The non-GitHub instance facts (provisioning, artifact store, ledger, teardown, cost) are **out of scope for
restructuring**. They remain the frozen recipes/prose they are today; the profile adds a `[recipes]` block of
**typed pointers** so the same discovery rule that finds the GitHub facts also reaches the recipes. This is
the minimal change that satisfies #130 (it needs the *GitHub* facts machine-discoverable) without forcing a
speculative rewrite of recipes that are working as prose. A future issue may promote individual recipes into
structured config; this design neither requires nor blocks that.

### 7. Identity by reference, never inline — the secret-handling contract

`[github.identity]` holds **the names of env vars**, and those env vars hold **commands that mint tokens** —
the profile file never contains a token, a key, or a key path. This means the profile file itself is
**non-secret** and can be committed to / browsed in the (private) research repo or kept in the home root
without leaking credentials. It is the exact pattern `wf.sh` already uses (`WF_ENGINEER_TOKEN_CMD_*` is a
*command*, minting a fresh ~1h token per use). A reviewer reading the profile sees *which seam* the run used,
never the credential.

## Interface contract (what the rest of #130 consumes)

This is the consumable surface; the cited children depend on exactly these:

| Consumer | Reads from this interface |
|---|---|
| **#156** design-experiment PR-open | `research_repo`, `base_branch`, `branch_prefix`, `[github.identity]` (to open + commit), `issue_repo` (the issue the PR closes) |
| **#157** run-experiment push/close/merge | `research_repo`, `base_branch`, `[github.identity]`, `[github.protection]` (merge-gate expectations) |
| **#150** shared GitHub helper | `[github.identity]` seam names (mint token, attribute commit) — the helper consumes the seams, this file declares them |
| **#146** sensitivity/visibility | `private` (the assertion its gate verifies) |
| **#154** cross-family contract | *nothing from this file* — cross-family is a product invariant #154 owns; the profile carries no `require_cross_family` knob (decision 3a) |
| **#155** canonical-path record layout | `research_repo` + `branch_prefix` (where `experiments/<exp>/` lives, on which branch) |
| **#145** design-clearance schema | `profile_sha256` from the snapshot (the drift input to its re-clearance trigger) |

Cross-reference with **#129** (per-experiment worktrees, Step 1): `branch_prefix = "run/"` MUST equal #129's
`run/<exp>` branch convention. #129 defines the worktree/branch *mechanics*; this file declares the *repo +
prefix* the executor resolves to fork that branch. The two contracts meet at the `run/` prefix and the
`base_branch` they fork from — if #129 lands a different prefix, this default follows it (the prefix is one
fact, declared once, here).

## Alternatives considered

- **Keep the narrative seam (status quo).** Rejected — that *is* the problem: a prose recipe gives a
  zero-context executor nothing to resolve before it must open a PR in a specific repo under a specific
  identity. #130 cannot proceed on prose.
- **Per-skill config (each skill reads its own file).** Rejected — `design-experiment` and `run-experiment`
  must resolve the *same* repo/base/identity or the PR opens in one place and merges in another. One file,
  one resolution, snapshotted once.
- **Inline the full provisioning/eval recipes into structured config now.** Rejected as scope creep — #130
  needs the *GitHub* facts machine-discoverable; the recipes work as prose. Typed pointers (decision 6) give
  discoverability without a speculative rewrite. A later issue can promote recipes if a need appears.
- **Inline tokens / key paths in the profile.** Rejected (decision 7) — makes the file secret, defeats
  browsing it in the record, and diverges from the `wf.sh` mint-by-command pattern. Seam-by-reference keeps
  the file non-secret.
- **Accept TOML + YAML + JSON.** Rejected (FINDING 4) — YAML adds a non-stdlib parser dependency the design
  argues against. TOML (recommended) + stdlib JSON only, with deterministic `.toml`-wins precedence
  (decision 1).
- **Home-root `~/aar-profile.*` location.** Rejected (FINDING 2) — mints a new global config convention in
  conflict with AGENTS.md's `~/.config/<module>/` rule. The profile lives under the owning module's config
  dir, written by the module's init (decision 1).
- **`require_cross_family` as an instance profile field.** Rejected (FINDING 3 / decision 3a) — cross-family
  review is a product validity invariant; instance config must never be able to disable it. #154 owns it as a
  product constant.
- **Resolve live in the executor (no snapshot).** Rejected — breaks #130's reproducibility promise: a config
  edit between design and a later re-examination would silently change what the record claims the run used.
  Snapshot + hash makes drift detectable (decision 4).
- **Reuse `wf.sh`'s engineer seams directly for experiment records.** Rejected — the scaffold-engineer
  identity (`claude-engineer`/`codex-engineer` on `automated-researcher`) is the *build* identity; experiment
  records land in the *instance research repo* under a research identity an instance scopes independently.
  Distinct seam names (decision 2) keep the two from being conflated, while reusing the exact mint-by-command
  pattern.

## Blast radius

- **Product skills** (`automated-researcher` / `experiment-lifecycle`): `design-experiment` and
  `run-experiment` change from "per your execution profile" prose to "resolve `aar-profile`, read field X,
  snapshot it." The START template's existing snapshot placeholder becomes the typed block (decision 4).
  These edits are the **implementation children** spawned from this design, not part of this doc.
- **New product artifact:** the schema definition + discovery/snapshot contract reference (a small doc the
  skills cite). Versioned with `schema_version`.
- **Instance artifact (not product):** each consuming instance writes its own `aar-profile.{toml,json}` at
  the owning-module config path via the module's init. This instance writes
  `~/.config/experiment-lifecycle/aar-profile.toml` with its `research-lab` slug, `run/` prefix, and
  research-identity seam names — instance content, never shipped in the product.
- **Cluster coupling:** this is a **prerequisite** that *unblocks* #156 and #157 (both list #153 in their
  `blocked-by`). It is **adjacent** to #146 (provides `private`), #154 (consumes **no** profile field —
  cross-family is a product invariant, decision 3a), #150 (declares the identity seams it consumes), #155
  (provides repo+prefix), and #145 (provides the snapshot hash). It **contradicts no sibling**: it declares,
  others enforce.
- **No runtime behavior ships in this PR** — doc-only design. The only thing that "breaks" if mis-specified
  is the children built on it, which is why it is reviewed first.

## Rollout + rollback

Doc-only design PR; lands the schema + discovery/snapshot contract on `main` via the `--scaffold` gate. Then
the spawned `ready` children implement it: (1) the schema-definition doc + product `schema_version` constant;
(2) the `aar-profile-init` / `aar-profile-validate` module init/validate scripts (the init owner, decision 1);
(3) the discovery + snapshot helper the skills call (resolve by the lookup rule, build the START.md snapshot
block, fail-closed on missing/unknown-MAJOR); (4) the `design-experiment`/`run-experiment` skill edits that
replace the narrative seam with the typed reads + the snapshot write. The discovery helper (3) is `blocked-by`
the schema doc (1); the skill edits (4) are `blocked-by` (2) and (3). The instance's own profile under
`~/.config/experiment-lifecycle/` is written by `aar-profile-init` once (2) lands — instance content, not a
product child. Staged: the init/validate + discovery helper ship and are unit-smoked (validate a fixture
profile, fail-closed on a missing one, refuse an unknown MAJOR, mint via the seam name) **before** any skill
consumes them, so the contract is validated in isolation first.

Rollback is a normal revert of the spawned skill edits — with the narrative "per your execution profile"
prose still present alongside the typed reads during the staged rollout, reverting the typed reads falls back
to the status-quo seam with no data loss (the experiment lifecycle's existing local-file path is unchanged).
The profile file itself is inert config; deleting it only re-triggers the fail-closed "no profile found" path,
never a wrong-place mutation.
