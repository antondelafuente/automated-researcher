<!-- SCHEMA_VERSION: 1 -->
# aar-profile — schema v1 (the instance execution-profile contract)

> Product-owned reference for the **instance execution profile** (`aar-profile.{toml,json}`): the single
> machine-discoverable config that holds an instance's GitHub-lifecycle facts (which repo experiment records
> land in, what branch they fork from, which identity opens/merges the PR, what the merge gate may require)
> plus typed pointers to the existing provisioning/artifact/ledger/cost recipes. The canonical design is
> proposal **#153**; this doc is the maintained reader surface its implementation reads. **Declaration only** —
> it states the schema, the version rule, and the discovery order; it implements no discovery, validation, or
> token minting (the init/validate script and the discovery+snapshot helper own those).
>
> **This file is shipped as two byte-identical per-skill copies** (one under `design-experiment/references/`,
> one under `run-experiment/references/`), because the two skills install independently; `.aar-ci/checks.sh`
> asserts they stay identical and that each carries exactly one integer `SCHEMA_VERSION` marker. Edit one,
> mirror the other.

## The product `schema_version` constant

The product understands **`schema_version` = 1** (the integer in the `SCHEMA_VERSION` HTML-comment marker on
line 1 — readers extract it with a one-line `grep`; they do not hardcode `1`). A profile declares its own
`schema_version` as the first field; readers compare it against this constant.

**Versioning rule (refuse-unknown-MAJOR, #153 decision 5):** `schema_version` is an integer MAJOR version.
A reader **refuses an unknown MAJOR** — it fails closed with a clear message rather than interpreting a field
layout it does not know (the same fail-closed disposition as a missing profile). Adding an OPTIONAL field is a
backward-compatible change a tolerant reader accepts without a bump; **removing or retyping a field is a MAJOR
bump.** An instance adopting a newer product reads the changelog for the bump.

## Discovery — the lookup order (#153 decision 1)

A reader resolves the live profile by this fixed order so a zero-context agent never guesses; it uses the
**first that exists**:

1. **`$AAR_PROFILE`** — explicit env override. The manual escape hatch and the test seam **only** (not the
   normal path).
2. **`${XDG_CONFIG_HOME:-~/.config}/experiment-lifecycle/aar-profile.{toml,json}`** — the owning-module config
   home (this instance: `~/.config/experiment-lifecycle/aar-profile.toml`).

**Format + precedence.** TOML is the recommended authoring format (unambiguous, comment-friendly, stdlib
`tomllib`); `.json` is also accepted (stdlib `json`, zero extra dependency). **YAML is not accepted** (it would
add a non-stdlib parser dependency). If both `.toml` and `.json` exist at the module config path, **`.toml`
wins** (deterministic precedence); validate warns on the shadowed file.

**Fail closed if none.** Resolution **never** falls back to a hardcoded repo/identity. If no profile exists,
the reader prints a single `BLOCKED: no instance profile found (looked: <paths>)` line and stops before any
GitHub mutation or compute spend.

## Who resolves live vs who reads the snapshot — the role split (NORMATIVE, #153 decision 1 / FINDING 2)

The discovery lookup above is **for the designer/init/validate side only**. The boundary is load-bearing:

- **`design-experiment` (the designer) resolves the live profile — once.** It runs the lookup, reads the
  fields it needs, and **snapshots the resolved values plus the file's content-hash (`profile_sha256`) into
  `START.md`** before the reviewed-brief commit (#153 decision 4). `aar-profile-init` / `aar-profile-validate`
  are the only other live readers (they write/check the file).
- **`run-experiment` (the zero-context executor) reads ONLY the frozen `START.md` snapshot.** It **never**
  re-reads the mutable live profile for any GitHub-lifecycle config — its world is the brief. The **one** narrow
  live step is minting a credential: it reads the env-var *name* the snapshot carries (`token_cmd_env`) and
  runs that command to mint a fresh token at use (a token must never be frozen into a record). All *config*
  comes from the snapshot; only the *credential* is resolved live, via the snapshotted seam name.

So "resolve the live config" and "never re-read live config" are not in tension — they are two different roles
(designer resolves; executor reads the snapshot). The snapshot grammar itself (the fenced-TOML
`## Instance profile (snapshot)` block in `START.md`) is owned by the discovery+snapshot helper and the skill
edits (#153 children 3/4), not this doc.

## The schema — fields, types, requiredness (v1)

A flat, versioned schema. The load-bearing block is `[github]` — without it the flow cannot open or merge the
PR. Everything else is a typed pointer to recipes that already exist. Authoring example:

```toml
schema_version = 1                       # integer; reader refuses an unknown MAJOR

[github]
research_repo   = "owner/research-lab"   # where experiment records land (DESIGN/RESULTS/gates)
base_branch     = "main"                 # the branch experiment branches fork from + merge into
branch_prefix   = "run/"                 # experiment branch namespace -> run/<exp> (matches #129)
issue_repo      = "owner/research-lab"   # OPTIONAL; where backlog issues live; defaults to research_repo
private         = true                   # asserts the repo's visibility; the gate verifies it

# FAMILY-KEYED author/reviewer SEAMS, by reference — NEVER inline secrets (#153 decision 7). The values name
# the ENV VAR that itself holds a token-minting command / an author string, never the key. Two families so the
# close review's opposite-family reviewer has a DISTINCT identity from the author.
[github.identity.claude]
token_cmd_env   = "AAR_RESEARCH_TOKEN_CMD_CLAUDE"   # env var holding a command that prints a fresh token
git_author_env  = "AAR_RESEARCH_GIT_AUTHOR_CLAUDE"  # env var holding "Name <email>" for commit attribution
[github.identity.codex]
token_cmd_env   = "AAR_RESEARCH_TOKEN_CMD_CODEX"
git_author_env  = "AAR_RESEARCH_GIT_AUTHOR_CODEX"

[github.protection]
# REMOTE branch-protection EXPECTATIONS only — declared so the close-gate reads them, never probes blind.
# May only TIGHTEN the product's invariants for an instance; can NEVER weaken one. (No cross-family knob — see
# the product-invariant note below.)
require_pr_review = true                  # branch protection requires an approving review before merge
enforce_admins    = true                  # protection includes administrators (no standing bypass)

# Recipe pointers: TYPED, fully-addressable objects — an anchor to the existing recipes, not a rewrite.
[recipes.provisioning]                    # a kind="repo" recipe:
kind     = "repo"                         # one of the supported kinds: "repo" | "uri"
repo     = "owner/research-lab"           # iff kind=repo — the OWNING repo (never assumed = research_repo)
path     = "recipes/provisioning.md"      # iff kind=repo — repo-relative path
git_ref  = "<git-sha>"                    # iff kind=repo — pins the exact commit
[recipes.artifact_store]                  # a kind="uri" recipe:
kind     = "uri"
uri      = "r2://<bucket>/recipes/artifact-store.md"  # scheme MUST be in the supported set (below)
sha256   = "<hex digest>"                 # iff kind=uri — pins the exact bytes
# [recipes.ledger] / .teardown / .cost_policy follow the same typed shape.
```

### Normative field table

`R` = required, `O` = optional. Reader behavior on a missing required field, an unknown MAJOR, an out-of-set
value, or a kind/field mismatch is **fail closed** (validate rejects; discovery blocks).

| Field | Type | Req | Default | Notes |
|---|---|:--:|---|---|
| `schema_version` | int | R | — | MAJOR version; reader refuses an unknown MAJOR (decision 5). |
| `[github].research_repo` | `owner/repo` string | R | — | Where experiment records land. |
| `[github].base_branch` | string | R | — | The branch experiment branches fork from + merge into. |
| `[github].branch_prefix` | string | R | — | Branch namespace → `run/<exp>`; **MUST equal #129's `run/` convention**. |
| `[github].issue_repo` | `owner/repo` string | O | `research_repo` | Where backlog issues live; absent ⇒ same repo (resolved `issue_repo // research_repo`). |
| `[github].private` | bool | R | — | **Assertion the gate verifies** (#146 enforces), not what makes the repo private. |
| `[github.identity.claude].token_cmd_env` | env-var name (string) | R | — | Name of the env var holding a token-minting **command**; never a secret. |
| `[github.identity.claude].git_author_env` | env-var name (string) | R | — | Name of the env var holding `"Name <email>"`; never a secret. |
| `[github.identity.codex].token_cmd_env` | env-var name (string) | R | — | Same, for the codex family (so the close review's reviewer is a DISTINCT opposite-family identity). |
| `[github.identity.codex].git_author_env` | env-var name (string) | R | — | Same, for the codex family. |
| `[github.protection].require_pr_review` | bool | O | `false` | Tightening-only expectation the close-gate pre-checks; may only require MORE, never weaken a product invariant. |
| `[github.protection].enforce_admins` | bool | O | `false` | Tightening-only expectation (no standing admin bypass). |
| `[recipes.<name>]` table | table | O | — | Each is a typed pointer; absent ⇒ that recipe is not anchored in the profile. `<name>` is the recipe key (e.g. `provisioning`, `artifact_store`, `ledger`, `teardown`, `cost_policy`). |
| `[recipes.<name>].kind` | enum | R *(within the table)* | — | **Closed set: `"repo"` \| `"uri"`.** Selects which other keys are required (below). |
| `[recipes.<name>].repo` | `owner/repo` string | R **iff** `kind="repo"` | — | The OWNING repo (never assumed = `research_repo`). |
| `[recipes.<name>].path` | string | R **iff** `kind="repo"` | — | Repo-relative path. |
| `[recipes.<name>].git_ref` | git-sha string | R **iff** `kind="repo"` | — | Pins the exact commit (the kind=repo pinning field). |
| `[recipes.<name>].uri` | string | R **iff** `kind="uri"` | — | Scheme MUST be in the **closed set `{r2://, s3://, https://}`**; any other scheme is rejected. |
| `[recipes.<name>].sha256` | hex-digest string | R **iff** `kind="uri"` | — | Pins the exact bytes (the kind=uri pinning field). |

Field semantics, normative (the parts not obvious from the table):

- **`research_repo`, `base_branch`, `branch_prefix`** — the three the PR-open step (#156) needs to fork
  `run/<exp>` and target the right base. `branch_prefix = "run/"` MUST agree with #129's `run/<exp>` branch +
  worktree convention; the two contracts meet at the `run/` prefix and the `base_branch` they fork from.
- **`private`** — an assertion #146's visibility gate verifies against the live repo (fail-closed if asserted
  private but the repo is public). This file states the expectation; #146 defines the enforcement.
- **`[github.identity.<family>]`** — **family-keyed** sub-tables (`claude`, `codex`), each naming the env vars
  that **themselves hold a token-minting command / an author string**, never the secret. Two families because
  the #130 close review is the merge-satisfying native APPROVE and **must be opposite-family** — the author
  commits/opens as its own family's identity, the close reviewer posts as the other family's, so the profile
  must declare **both**, distinct. The profile only *declares* the seams; the shared GitHub helper (#150)
  *validates* that a distinct opposite-family reviewer identity resolves before any protected PR flow runs.
  Mirrors `wf.sh`'s `WF_ENGINEER_TOKEN_CMD_CLAUDE/CODEX` seams; the research flow gets its **own** seam names
  so experiment-record identities stay distinct from the scaffold-engineer identities.
- **`[github.protection]`** — what the executor's close-gate (#157) should *expect* the remote to require, so
  it pre-checks readiness instead of discovering a failed merge after the run. A **declaration of
  expectation**, not a configuration of GitHub (the actual protection is set out-of-band — see the
  ship-change RUNBOOK). It may only *tighten*; a mismatch (the remote requires fewer reviews than declared) is
  the close-gate's fail-closed signal.

### Product invariant — cross-family review is NOT a profile field (#153 decision 3a)

Cross-family auditing (a change/run reviewed by the *opposite* model family) is a **validity invariant of the
product**, not an instance preference. The profile carries **no `require_cross_family` knob**: an instance must
never be able to declare its records "reviewed" with a same-family judgment. #154 enforces cross-family in the
audit-runner contract as a product constant; `[github.protection]` may only assert *additional, tightening*
remote requirements, never a setting that weakens or disables the cross-family guarantee.

### Identity by reference, never inline — the secret-handling contract (#153 decision 7)

`[github.identity.<family>]` holds, per family, **the NAMES of env vars**, and those env vars hold **commands
that mint tokens** — the profile file never contains a token, a key, or a key path. This keeps the file itself
**non-secret**: it can be committed to / browsed in the (private) research repo or kept under the module config
dir without leaking credentials. A reviewer reading the profile sees *which seam* each family's identity uses,
never the credential.

## Recipes stay narrative, reached by typed pointer (#153 decision 6)

The non-GitHub instance facts (provisioning, artifact store, ledger, teardown, cost) are **out of scope for
restructuring** — they remain the frozen recipes/prose they are today. The `[recipes.*]` block adds typed,
fully-addressable pointers so the same discovery rule that finds the GitHub facts also reaches the recipes, and
the executor needs no hidden instance knowledge to fetch one: the owning repo-or-URI and the kind-appropriate
digest are *in the pointer*. The pinning field is named by kind — `git_ref` for `repo`, `sha256` for `uri` — so
there is no ambiguous shared `ref`. Validating that each pointer resolves (the repo/uri exists at the pinned
digest, the scheme is supported) is part of `aar-profile-validate` (the init/validate child), not this doc.

## What this doc does NOT define (owned elsewhere)

- The **discovery + snapshot helper** behavior (resolve by the lookup, build the `START.md` snapshot block,
  fail-closed on missing/unknown-MAJOR, mint via the seam name) — #153 child 3.
- The **`aar-profile-init` / `aar-profile-validate`** scripts (the init owner that scaffolds + validates a
  profile against this schema) — #153 child 2.
- The **`START.md` snapshot grammar** (the fenced-TOML `## Instance profile (snapshot)` block) and the skill
  edits that replace the narrative seam with typed reads — #153 children 3/4.
- **Enforcement** of any asserted expectation: `private` → #146; identity seams → #150; protection
  expectations → #157/#156; cross-family → #154 (product invariant). This file *asserts*; the gates *enforce*.
