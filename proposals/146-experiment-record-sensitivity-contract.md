# Proposal: experiment-record sensitivity / visibility contract (#146)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before any code lands.
> Doc-only design PR in the two-phase split (a `needs-design` child of the #130 umbrella). It defines a
> data contract — fields, locations, produce/consume rules, and fail-closed validation — and spawns the
> `ready` implementation issue(s); it ships **no code**.

## Problem

The #130 umbrella ("experiments through GitHub") makes GitHub the default record and review surface for an
experiment: the design, the four gate outputs and their triage, the results, and the design/close reviews are
all committed to a branch or posted to a PR. Today those same gate outputs are **local files in a shared
working tree** — never published — so nobody had to decide what was safe to show. A browsable GitHub trail
changes that. Experiment content can be sensitive: unreleased datasets, private or pre-release model behavior,
and block-prone rollout / jailbreak / judge-prompt text that an experiment deliberately elicits. With no
explicit contract, the experiment-PR path could leak that content into a trail that is browsable — and, on a
public research repo, world-readable.

This child exists to write that contract. It answers three concrete questions the umbrella left open: (1)
**when must the experiment repo be private**, and how does the instance declare and the gate enforce it; (2)
for **each record type** (DESIGN / START / CHECKLIST / RESULTS, the four gate outputs, triage responses) —
which content may appear **inline** on GitHub, which must be a **pointer** to the artifact store, and which
must be **redacted**; (3) what a **PR review comment** may quote from a record, since the reviewer reads the
artifact store directly and the posted comment must not echo a sensitive payload back onto the trail. The
contract is a **schema plus produce/consume rules plus fail-closed validation** — the machine-checkable thing
the blocked implementation pieces (#155 record layout, #156 design-experiment posting, #157 run-experiment
push/close) consume. Per the umbrella, none of those may be authorized until this lands.

## Approach

The contract is a **default-deny classification of record content**, declared once per instance and enforced
mechanically at every point that writes to the GitHub trail (a commit to the branch, a PR body, or a posted
review comment). The principle is the umbrella's own, made checkable: **raw artifacts never touch the trail —
the trail carries pointers, summaries, and a bounded amount of explicitly-cleared inline content.** When the
classifier cannot prove a piece of content is safe, it fails closed (blocks the write, or for the redaction
layer, refuses to emit), never "publish and hope."

Plain-English shape: every record type gets a **sensitivity tier**. A tier says where that record's *body* may
live (inline-on-GitHub vs. pointer-only) and which of its fields are **payload fields** that must be redacted
or pointer-ized before the write. A small, instance-declared **policy** layered on top can tighten any tier
(e.g. "treat RESULTS prose as pointer-only too") and declares whether the repo must be private. A
**validator** runs at each write boundary and is the fail-closed gate. The implementation children wire the
validator into the produce path (design-experiment / run-experiment) and the consume path (the merge gate
re-checks before merge, so a hand-edited branch can't smuggle payload past).

### The classification: three tiers

Each record type is assigned one tier. A tier is the *default* visibility of that record's body; the policy
(below) may tighten it but never loosen it.

- **T0 — pointer-only.** The record's body must NOT be committed inline to the trail. Only an artifact-store
  pointer (an opaque handle, see the pointer schema) and a non-sensitive caption may appear. This is for
  records whose payload is *inherently* the sensitive thing: raw rollouts, generated/training datasets,
  judge-input transcripts, anything the experiment *elicited*.
- **T1 — structured-with-redaction.** The record may be committed inline, but it carries **declared payload
  loci** — either named fields (for records that already have a schema) or a **payload-pattern** (for the
  free-form Markdown the audit producers emit today). Each payload locus is replaced by a pointer (or a
  redaction marker) before the write. The non-payload structure (hypothesis, arms, metric names, decision
  rules, finding ids/severities/summaries, triage statuses, counts/aggregates) stays inline so the trail is
  readable. This is the working tier for the gate outputs and triage. **The payload locus depends on the
  record's current shape** (see "Two T1 surfaces" below) — the contract does not assume a structure that
  doesn't exist yet.
- **T2 — inline-clear.** The record may be committed inline verbatim. Reserved for content that is *authored
  by the AAR for the human reader* AND contains no elicited model output, no third-party data, AND **no
  operational-sensitive config** (exact prompts, eval/grader definitions, raw artifact paths, model IDs that
  reveal a pre-release model). T2 is the design/result *prose* and decision rationale — not a brief or
  checklist that embeds executable config (those are T1; see Finding-2 fix below).

Default assignment by record type (the produce/consume contract keys on this table):

| Record | Tier | Rationale |
|---|---|---|
| `DESIGN.md` prose (problem/hypothesis/arms/metric/decision-rules/cost narrative) | **T2** | AAR-authored design intent; no elicited payload, no executable config. |
| `RESULTS.md` narrative + aggregate metrics/tables | **T2** | Outcome prose + numbers the AAR writes; no raw rows. |
| `START.md`, `CHECKLIST.md`, and `DESIGN.md` *config subfields* (exact prompts, eval/grader definitions + flags, raw artifact paths, model IDs, seed/sample data) | **T1** | AAR-authored but operationally sensitive: a verbatim prompt/eval/grader or a pre-release model ID is payload even though no model produced it. Safe-field allowlist below; everything else in the brief is a payload locus → pointer/redact. |
| `RESULTS.md` per-example rows / transcript excerpts | **T0** | Raw elicited output → pointer-only. |
| `verify_claim` output | **T1** | Today free-form → **pointer-only**; once structured-emit lands, verdict + payload-free summary inline, quotes → pointer. |
| `audit_experiment --design` output | **T1** | Today free-form → **pointer-only**; structured-emit inlines id/severity/safe-summary, quoted brief payload → pointer. |
| `audit_experiment --data` output | **T1** | Today free-form → **pointer-only**; structured-emit inlines findings + surfaces-checked, sampled/quoted rows → pointer. |
| `audit_experiment` close output | **T1** | Today free-form → **pointer-only**; structured-emit inlines findings, quoted RESULTS/rollout payload → pointer. |
| Triage responses (per finding) | **T1** | Status + reason inline; any quoted payload in the reason → pointer. |
| Raw rollouts / datasets / judge-input transcripts / model-output dumps | **T0** | Inherently the sensitive payload. |
| PR body (umbrella: first-para Problem + Approach) | derived | Built only from T2 record bodies → inherits T2; never from T0/T1 payload. |
| Posted PR **review** comment | special (see PR-quote rule) | A reviewer-produced surface; its own quote ceiling. |

The four gate outputs are T1, not T0, on purpose: their **structure** (which finding, what severity, the
triage decision) is exactly the browsable trail the umbrella wants, and it is not itself the sensitive payload.
What is sensitive is any *quoted payload* a finding cites ("the rollout said X"), which the redaction layer
pointer-izes per the payload-locus rule. The reviewer always reads the full payload from the artifact store
(per #150's reviewer-resolution); the *posted* output never has to.

**The brief is T1, not T2 (prior Finding-2 fix).** `START.md` / `CHECKLIST.md` and the config subfields of
`DESIGN.md` are authored by the AAR but carry the experiment's *executable* surface — the exact prompts, the
eval and grader definitions and flags, raw artifact-store paths, and model IDs that can reveal a pre-release
model. "AAR-authored" is therefore **not** sufficient for T2; T2 additionally requires no operational-sensitive
config.

**But today's briefs are free-form Markdown, so they are pointer-only until #155 gives them a schema
(Finding-3 fix).** `DESIGN.md` / `START.md` / `CHECKLIST.md` today interleave exact evals, paths, model IDs,
and rationale in prose — there are no named fields to selectively redact. Per the payload-locus rule, a
free-form T1 surface is **pointer-only** (a free-form brief body inline → BLOCK). The contract therefore
defines the **target safe-field allowlist** that #155 (the canonical-path record layout) must realize as a
machine-readable brief schema. **A safe field is a constrained display alias/summary with a content validator,
not a raw value passed through by field name (Finding-4 fix)** — because a "field name is safe" rule would let
a sensitive model ID ride inline inside an "arm label" or a prompt fragment inside a "hypothesis." The
inline-safe fields are: a hypothesis *summary*, arm *display labels* (validated against a no-raw-identifier
content check), metric *names* (from a constrained vocabulary), decision rules, cost estimate, gate checklist
*structure* (which gate, pass/fail), and the design *rationale prose* (T2). Raw model/eval/prompt identifiers
are **always payload** regardless of which field they appear in — the validator's content check forces them to
a pointer even if a schema field nominally "allows" them. Everything else — verbatim prompts, eval/grader
bodies, raw paths — is a payload field carried as a pointer. **#155 owns turning the free-form brief into that structured form; until it lands,
the brief is committed to the artifact store and the trail carries the pointer + the `visibility.yml` sidecar
ONLY.** Even the rationale prose is pointer-only pre-#155 (Finding-3): a free-form `DESIGN.md` interleaves
rationale with exact evals/paths/model IDs, so there is no machine-checkable boundary separating "T2 rationale"
from config until #155's schema draws it — so nothing from the un-schematized brief is inlined except the
closed-schema sidecar. Inline rationale returns only through #155's structured schema. This is the brief's
analogue of the audit structured-emit prerequisite: selective inline redaction is unlocked only by a structured
schema, never by pattern-matching prose. An instance may tighten the allowlist (e.g. drop
`model_id` to pointer-only); it may extend it only via a product-owned schema enum (see Finding-5 fix in the
policy).

#### Two T1 surfaces — named-field vs. free-form (Finding-1 fix)

T1 covers two physically different record shapes, and the validator handles them by **shape**, not by assuming
a uniform structure:

- **Named-field T1** (records with a structured schema): the future schema'd records (#151 triage, #145
  clearance) and the brief *once #155 schematizes it*. The owning schema **declares its payload field names**;
  the validator reads those named fields and pointer-izes/redacts them, keeping the allowlisted fields inline.
  A record only enters this surface when its schema exists — until then it is treated as free-form (below).
- **Free-form T1** (the audit producers *as they emit today*) is **pointer-only at publish boundaries until
  the structured-emit lands** — see below. The reviewer reads the full free-form audit from the artifact store;
  the trail gets a pointer + the parsed severity/summary header only.

**Structured sanitized emit is a PREREQUISITE, not a ride-along (Finding-2 fix).** A pattern-match over the
`evidence:` convention alone *under-solves* leakage: `audit_experiment` is instructed to "quote the claim and
the evidence," so payload can land in a finding's **issue** and **recommendation** prose, not only in an
`evidence:` quote or a fenced block. Redacting only the quote leaves a leak. Therefore the contract does **not**
treat free-form pattern-matching as a sufficient publish path. Instead:

- The audit producers (`verify_claim` / `audit_experiment`) must gain a **structured sanitized output**: named
  safe fields + every quote / cited excerpt carried as an `artifact_ref`, never inline. **The inline safe
  fields are deterministic metadata only by default** (finding id, a severity from the closed enum, the
  finding's *dimension* tag) — NOT a free-text summary. A free-text one-line summary is **not** trusted as
  inline-safe merely because the producer "guarantees" it (a producer assertion is not machine-checkable, and a
  summary can carry semantic payload — Finding-1); a summary is inline only if it passes a **mechanical content
  validator** (no raw identifiers, length-bounded, drawn from constrained vocab), else it is pointer-only. This
  is a **`verify-claims` producer-interface child with its own canonical schema + tests** (Finding-2 — it
  belongs in `verify-claims`, not coupled to the GitHub wiring), and it is a **hard prerequisite** of the
  wiring child — the GitHub commit/post wiring may not be authorized until it lands.
- **Until structured-emit lands, legacy free-form audit output is rejected at every publish boundary** — it is
  pointer-only (committed to the artifact store, a pointer + parsed header on the trail). The validator
  fail-closes on any attempt to inline a legacy free-form audit body. There is no "redact the quote and publish
  the rest" path, precisely because the rest can also carry payload.

This resolves both the "T1 assumes structure that doesn't exist" gap and the "pattern-match under-solves"
gap: the trail only ever carries audit content that a producer has *structurally* guaranteed safe; everything
else is a pointer.

### The payload-locus rule (what T0/T1 actually redact)

A **payload locus** is any field, quote, or block whose value is, or directly embeds, content that is either
(a) *elicited or ingested* by the experiment (a raw model completion, a row of generated/training data, a
judge-input transcript, a verbatim source/citation body, an inline example of any of those) or (b)
*operationally sensitive* config (an exact prompt, an eval/grader definition, a raw artifact path, a
pre-release model ID). A T0 record is entirely payload (body → pointer). A T1 record's payload is located by **shape**: for a record with a
**structured sanitized schema** (the schema'd records, and the audit outputs once structured-emit lands) the
validator pointer-izes the declared payload fields and inlines the declared safe fields; for any record that is
still **free-form Markdown** (today's audit outputs, today's free-form briefs) the validator does **not** try
to selectively redact — that surface is **pointer-only** until it has a structured schema (a free-form body
inline → BLOCK). The validator replaces each payload locus with either an **artifact-store pointer** (preferred,
so the reviewer can still reach it) or a **redaction marker** `[[redacted: <reason>]]` when no stable artifact
exists. Anything the validator cannot prove safe → BLOCK, never publish-through.

Pointer schema (the single shape every pointer uses — this is the contract the artifact store and the trail
agree on):

```yaml
artifact_ref:
  handle: "<store-issued opaque id>"  # opaque artifact ID; NOT a raw bucket/path; resolved to a real URI privately by #153
  bytes:  <int>                       # size, for the reader's sense of scale (optional)
  caption: "<non-sensitive one-line>"# OPTIONAL; only if it passes the mechanical content validator, else omit
  # integrity hash is NOT on the public trail for sensitive artifacts — see below
```

`caption` is **optional and mechanically validated** (Finding-1): a free-text caption is not trusted as safe by
assertion — it appears on the trail only if it passes the same content validator the safe-summary uses (no raw
identifiers, length-bounded). When in doubt it is omitted; the `handle` alone is a valid pointer.

**The trail carries an opaque `handle`, never a raw store path (prior Finding-4 fix).** A raw `r2://<bucket>/<key>`
URI is itself operational-sensitive payload (it leaks the store layout / bucket names), so it must not appear on
the trail. The pointer on the trail carries only a **store-issued opaque handle**; the **instance profile
(#153) resolves that handle to a real, possibly-credentialed store URI privately** at fetch time. The validator
rejects an `artifact_ref` whose `handle` looks like a raw path (contains a scheme like `r2://`/`s3://` or a
`/`-delimited bucket path) → BLOCK. The `handle` is opaque and must NOT be the content hash (see next).

**The integrity hash stays off the public trail for sensitive artifacts (Finding-5 fix).** A raw `sha256` of a
sensitive artifact is itself a membership/identity oracle on a public trail — anyone with a candidate
dataset/prompt/output file can hash it and confirm it was used. So for any artifact whose source record is
`sensitive` (or on a public repo by default), the **integrity hash is resolved privately by #153 alongside the
URI**, not committed to the trail; the reviewer verifies the fetched content against the privately-resolved hash.
Only a `standard`-sensitivity artifact on a private repo may carry an inline `sha256`. The validator BLOCKs an
inline `sha256` on a pointer to a `sensitive`/public-trail artifact. (The opaque `handle` therefore must be a
store-issued id, not the hash — otherwise the hash would leak via the handle.)

### The PR-quote rule (the review surface)

A posted design/close **review comment** is produced by the cross-family reviewer, which reads the full
payload from the artifact store. The comment must not echo that payload back onto the trail. Rule:

- A review comment may quote **only T2-tier content** (AAR-authored design/result prose) and the **structured,
  non-payload fields** of T1 records (finding id/severity/summary, triage status). It may reference any
  payload only by **pointer** (`artifact_ref`), never by inline quote.
- A bounded exception: the reviewer may inline up to **`max_quote_chars` (default 0)** characters of payload
  *only if* the instance policy raises that ceiling above 0 (e.g. a private repo where short excerpts are
  acceptable). Default-deny: at 0, no payload quote is ever emitted; the reviewer cites the pointer instead.
  This keeps the public-repo default safe and lets a private instance opt into short excerpts deliberately.

**Posted reviews are rendered from the structured sanitized audit record, not free-text-validated
(Finding-3 fix).** Trying to *prove* a free-form review body is payload-free would reintroduce exactly the
heuristic redaction path this contract rejects. So the helper (#150) does not scan raw reviewer prose: a posted
review is **rendered from the structured sanitized audit record** (the same structured-emit the audit producers
gain) — safe fields inline, payload as `artifact_ref`. Raw free-form reviewer text is treated as a free-form T1
surface: **pointer-only** (committed to the artifact store; the trail/PR carries the rendered structured review
+ a pointer to the full text). The post-time validator then only has to check the *rendered* output's structured
fields + the quote ceiling — never to prove a free-text body safe.

### The instance policy (declared in the instance profile, #153)

The contract ships **safe defaults**; the instance profile (#153, the machine-discoverable execution-profile
config) carries the per-instance overrides under a `record_visibility` block. The contract defines the schema;
#153 owns the file's location and discovery. Fields:

```yaml
record_visibility:
  require_private_repo: <bool>        # if true, the gate fails closed unless the research repo is private
  tier_overrides:                    # may only TIGHTEN (T2→T1→T0), never loosen; validator rejects a loosen
    RESULTS_narrative: T1            # e.g. an instance that won't even publish result prose inline
  brief_safe_fields_remove:          # instance may only REMOVE keys from the product allowlist (tighten);
    - model_display_label            #   extension is NOT allowed here — see brief_safe_fields_enable
  brief_safe_fields_enable:          # extension is restricted to a PRODUCT-OWNED enum the brief schema (#155)
    - model_display_label            #   a RELEASED-public display label only; a raw/pre-release model_id is ALWAYS payload
  max_quote_chars: <int>             # PR-quote ceiling; default 0 (no payload quote). >0 requires private repo.
  redaction_marker: "[[redacted: %s]]"  # format; default as above
```

**Per-experiment visibility, merged with the instance floor (most-restrictive wins).** Sensitivity is *not*
uniform across an instance's experiments — one run may probe a pre-release model whose very *aggregate* outcome
is sensitive, while the next is fully public. An instance-wide policy alone is therefore the wrong granularity:
default-public + T2 result aggregates would publish a private model's behavior. So the contract takes a
**per-experiment declaration** in a **mandatory, always-inline visibility sidecar** —
`experiments/<exp>/visibility.yml`, a small product-schema'd file that is **explicitly T2-safe by construction**
(a closed enum + tier names + booleans; no free prose, no payload), merged with the instance floor by
**most-restrictive wins** (a tier may only be tightened by the merge, never loosened; the more-private repo
requirement wins):

```yaml
# experiments/<exp>/visibility.yml — mandatory, always inline, product-schema'd (closed values only)
sensitivity: standard | sensitive   # closed enum; `sensitive` = pre-release model / private data / block-prone elicitation
tier_overrides: { RESULTS_narrative: T1 }   # values are tier names (T0/T1/T2) only; tighten only; merged over the instance floor
require_private_repo: true                  # bool; may raise the floor; may never lower it
```

**`standard` is mechanically verified, not merely asserted (Finding-2 fix).** A self-declared `sensitivity:
standard` cannot be *trusted* — a run could be sensitive and (mistakenly or otherwise) declare itself standard,
and the gate would then enforce consistency against a false assertion. So the validator runs **closed mechanical
trigger checks** before accepting `standard`: if the experiment references a model ID on the instance's declared
**pre-release/private model list**, or a **private-dataset handle**, or any record carries a `sensitive`-marked
artifact, the trigger **forces the effective sensitivity to `sensitive`** regardless of the sidecar's
declaration (and a `standard` declaration against a fired trigger is logged). `standard` is therefore a
*verified* state (no trigger fired), not a bare claim. The instance's pre-release model list + private-dataset
namespace are part of the #153 profile (it already owns model/data identity); the contract owns the trigger
*rule* (closed, mechanical, fail-closed: an unparseable model/data reference → treat as sensitive). This makes
the gate enforce consistency against a *checked* assertion, and keeps the public-default safe without flipping
the product floor to private-by-default (see the decision note).

**Why a sidecar, not `DESIGN.md` front-matter (prior Finding-1 fix).** The visibility metadata *decides* visibility,
so it cannot itself be pointer-only — yet `DESIGN.md` is free-form and therefore pointer-only until #155
schematizes it (a circularity). Resolving it: the declaration is a **separate, mandatory, structured sidecar
file** whose schema admits only closed values (the enum, tier names, booleans) and is therefore inline-safe by
construction — it can never carry payload, so it is exempt from the free-form pointer-only rule. The validator
**fail-closes if the sidecar is absent or malformed** at PR-open and at merge: no experiment posts without a
parsed visibility declaration. This keeps the decision inline and readable while the design *prose* it governs
can still be pointer-only until #155.

The **merge gate and PR-open both fail closed** if a `sensitivity: sensitive` experiment is about to post to a
non-private repo, or if its effective (merged) tiers would inline any payload. `sensitive` forces, at minimum,
`RESULTS_narrative` and aggregate metrics to T1 (pointer-only outcome) unless the repo is private — a
private-model run cannot publish even its aggregate behavior to a public trail. The per-experiment declaration
can only *tighten* the instance floor; an experiment can never declare itself *more* public than the instance
allows. This closes the "instance-wide seam is the wrong granularity" gap: the floor is the instance's, the
ceiling is per-experiment, and the validator enforces the stricter of the two at every boundary.

**`require_private_repo` and the visibility floor.** The contract does not *force* private on every instance —
a public alignment-research repo is a legitimate, deliberate choice for non-sensitive work, and the umbrella
already says the repo is instance config, not hardcoded. Instead the contract gives the instance a declared
floor and the gate enforces *consistency*: if `require_private_repo: true`, the merge gate (and the PR-open
step) fail closed unless GitHub reports the repo private; if `max_quote_chars > 0`, that also requires a
private repo (you cannot opt into inline payload excerpts on a public trail). The default profile a fresh
instance gets is `require_private_repo: false, max_quote_chars: 0` — public-safe because the tier defaults keep
all payload off the trail regardless of repo visibility. **The private-repo requirement is therefore a
defense-in-depth toggle, not the primary control; the primary control is the tier classification + redaction,
which holds even on a public repo.** (This is the one genuine product choice and is recorded in the decision
note below.)

### Validation + fail-closed rules (the gate)

A single **validator** is the contract's enforcement point. It takes (record-type, record-body, policy) and
either returns a trail-safe rendering or BLOCKS. It runs at three boundaries — the same fail-closed shape
ship-change's own merge gate uses (parse an authoritative verdict; missing/garbled → BLOCK):

1. **Produce-time (write a record to the branch).** `design-experiment` / `run-experiment` call the validator
   before committing any record. T0 body present inline → BLOCK. A **free-form** T1 body (legacy audit output,
   un-schematized brief) present inline → BLOCK (pointer-only until it has a structured schema). A structured
   T1 payload field not pointer-ized/redacted → BLOCK. A pointer missing `handle`, a `handle` that
   looks like a raw store path (`r2://`/`s3://`/bucket path) or equals the content hash → BLOCK, an inline
   `sha256` on a sensitive/public-trail pointer → BLOCK, or a `caption` that itself contains payload → BLOCK.
   A missing/malformed `visibility.yml` sidecar → BLOCK. A free-text summary/caption that fails the content
   validator → pointer-only (or BLOCK if inlined). A `sensitivity: standard` declaration while a mechanical
   trigger fired (pre-release model ID / private-dataset handle / sensitive-marked artifact) → effective
   sensitivity forced to `sensitive`; an unparseable model/data reference → treat as `sensitive`. A tier override that *loosens* (instance or per-experiment) → BLOCK (config error). A
   `brief_safe_fields_enable` key not in the product-owned schema enum → BLOCK.
2. **Post-time (a PR review comment / PR body).** The helper (#150) runs the validator over the review/PR-body
   text before calling GitHub. Payload quote over `max_quote_chars` → BLOCK. `max_quote_chars > 0` on a
   non-private repo → BLOCK. **Also at PR-open:** a `sensitivity: sensitive` experiment whose effective
   (instance-floor ⊓ per-experiment) policy would post to a non-private repo, or inline any payload → BLOCK
   before the PR is created.
3. **Merge-time (the close gate, re-check).** The merge gate re-runs the validator over the **full diff being
   merged** (every record file the PR adds/edits) so a hand-edited branch or a bypassed produce-time call
   cannot smuggle a T0 body, a free-form T1 body, or un-redacted T1 payload onto `main`. This mirrors
   ship-change's "re-review the final diff" integrity property: the merged trail is the validated trail. A
   `require_private_repo: true` (instance OR per-experiment) policy against a public repo also BLOCKS here.

**Fail-closed posture (explicit):** unknown record type → treat as **T0** (most restrictive) and BLOCK if any
inline body is present — a new record type cannot accidentally publish before it is classified. A malformed or
unreadable policy → BLOCK (do not silently fall back to permissive). A validator crash → BLOCK (no result is
not "clean"). The contract is default-deny end to end: the only way content reaches the trail inline is an
explicit T2 classification or an explicitly-pointer-ized T1 field.

### What this contract does NOT do (scope fence)

- It does not define the artifact store, its auth, or how a `handle` resolves to a real URI — that is the
  instance profile (#153) and the existing run-experiment artifact-store seam. **#153 must supply an immutable
  artifact-index/resolver** (Finding-4): a handle namespace, an immutable handle→URI mapping, private hash
  storage, resolver discovery, and tombstone/rotation behavior — without it the opaque handles are not
  reproducibly auditable. The contract owns only the **pointer shape** (opaque `handle` on the trail; integrity
  hash resolved privately); the index that makes a handle resolvable is #153's, and the wiring child is
  `blocked-by` it. The contract only fixes the **pointer shape** the trail
  uses.
- It does not implement the validator or wire it into the skills — the validator *library* is the `ready`
  child; the wiring is the `blocked-by` child (see Rollout).
- It does not define the triage-artifact field schema (#151), the design-clearance artifact (#145), or
  terminal-state evidence (#152). It classifies the **visibility tier** of those records' content and declares
  their payload-field rule; their internal field schemas are those children's. The contract is additive: each
  of those schemas declares its own payload fields, and this contract says how they render on the trail.

## Alternatives considered

- **All-records-pointer-only (everything T0).** Rejected: it would empty the trail of exactly the browsable
  index #130 is built to create — you could no longer read the design, the findings, or the result without
  fetching the artifact store. The value of #130 is a readable record; default-deny on *payload*, not on
  *everything*, preserves it.
- **Private-repo-only (require private, no tiers).** Rejected: it makes "private" the only control, which (a)
  contradicts the umbrella's "repo is instance config, may be public" and forecloses public alignment-research
  use, and (b) is brittle — one repo-visibility flip silently world-exposes every past payload. Tier
  classification + redaction holds regardless of repo visibility; private becomes defense-in-depth, not the
  load-bearing control.
- **Allowlist instead of default-deny (publish unless flagged sensitive).** Rejected: the silent-failure mode
  here is a confidently-published payload, the research-validity analogue the constitution warns about. An
  allowlist fails *open* on anything unanticipated (a new record type, a field nobody marked); default-deny
  fails closed, which is the only safe default for a world-readable trail.
- **Redact at read/render time only (store raw, hide in the UI).** Rejected: the raw payload would still be
  committed to `main` and in git history forever; a viewer-side redaction is not a contract, it's a curtain.
  The payload must never reach the trail in the first place.
- **A free-form per-record "sensitive: true" boolean.** Rejected: too coarse — a record is usually *partly*
  payload (a finding's structure is safe, its quoted excerpt is not). The payload-*field* rule is what lets the
  structure stay readable while the payload goes to a pointer.

## Blast radius

- **No code in this PR.** Doc-only design; the deliverable is the contract above. Two `ready` children (the
  dependency-free validator *library*; the `verify-claims` structured sanitized audit-emit) and one
  `blocked-by` child (the produce/post/merge wiring) are spawned (see Rollout).
- **Unblocks (the umbrella's `blocked-by` wiring):** #155 (canonical-path record layout) consumes the tier
  table to decide which record content is committed vs pointer-ized, **and owns schematizing the free-form
  brief into the safe-field allowlist this contract defines** (until #155 lands, the brief is pointer-only);
  #156 (design-experiment PR-open + --design
  review posting) consumes the produce-time + post-time validation; #157 (run-experiment push/close + merge
  gate) consumes all three boundaries. None of those may be authorized until this lands (umbrella rule); this
  doc is the thing that unblocks them.
- **Touches #153 (instance-profile interface):** adds the `record_visibility` block to the profile schema #153
  defines, and requires #153 to supply (a) the **pre-release/private model list + private-dataset namespace**
  the `standard`-verification trigger checks against, and (b) the **immutable artifact-index/resolver** (handle
  namespace, handle→URI mapping, private hash storage, resolver discovery, tombstone/rotation) that makes the
  opaque handles resolvable and auditable. #153 owns the file location/discovery + these resolvers; this
  contract owns the block's fields, the trigger rule, and the pointer shape. Coordinated, not contradictory —
  #153's schema should reserve `record_visibility` for this contract.
- **Touches #150 (shared GitHub-lifecycle helper):** the post-time validator runs inside the helper's
  review/PR-body posting path, and the merge-time re-check runs in the helper's merge gate. The helper hosts
  the *enforcement call site* on the rungs it runs (--design, close, post, merge); this contract supplies the
  validator and rules it calls. The helper does not own the classification — same separation #130 decision 5
  uses for cross-family enforcement.
- **Touches `verify-claims`:** the structured sanitized audit-emit is a producer-interface change in
  `verify-claims` (its canonical home), spawned as a `ready` child — not coupled to the GitHub wiring. The
  posted review is *rendered from* that structured record, so the helper never validates free-form reviewer
  prose.
- **Touches #151 (triage schema) / #145 (clearance schema) / #152 (terminal states):** classifies their
  records as T1 and states the payload-field rule for them; their internal field schemas remain theirs. No
  contradiction — each declares its own payload fields; this says how they render.
- **Product/instance boundary:** the contract + validator are **product** (ship in the skills/helper); the
  `record_visibility` policy values and the repo's actual visibility are **instance** config (#153). The
  defaults are public-safe so a fresh instance is safe with no configuration.

## Rollout + rollback

Doc-only design PR; lands the contract on `main` via the cross-family `--scaffold` gate (closes exactly #146,
disposition `needs-design`). The decomposition is split so the `ready` unit is genuinely dependency-free and
the dependent wiring is honestly `blocked-by` — matching the umbrella's discipline (the umbrella kept *its
own* pieces `needs-design`/`blocked-by` precisely because they had hidden dependencies; this child spawns one
narrow piece that does not, and files the rest blocked):

- **`ready` — the record-visibility validator *library*.** A pure function `validate(record_type, body,
  policy) → safe_render | BLOCK` plus the public-safe default policy and its own unit smoke (a T0 body inline,
  a loosening tier override, a payload quote over `max_quote_chars`, an unknown record type, a malformed
  `evidence:` quote — each must BLOCK). This is `ready` because it has **no** GitHub / helper / profile / skill
  dependency — it is a self-contained classifier+redactor tested against fixture record bodies. The tiers, the
  table, the pointer shape, the two T1 surfaces, and the policy schema are all fixed in this doc, so it carries
  no open design.
- **`ready` — the `verify-claims` structured sanitized audit-emit.** A separate child against the
  `verify-claims` producers (`verify_claim` / `audit_experiment`): emit a structured sanitized record (named
  safe fields the producer guarantees payload-free + every quote/excerpt as an `artifact_ref`) alongside the
  existing free-form output, with its own canonical schema + producer-side tests. This is **`ready`** (no
  GitHub/helper dependency — it's a producer interface change) and it belongs in `verify-claims`, its canonical
  home, not coupled to the GitHub wiring (Finding-2 fix). The GitHub wiring *consumes* this schema; it does not
  own it.
- **`blocked-by` — the produce/post/merge wiring.** Wiring the validator into `design-experiment` /
  `run-experiment` (produce-time), the helper's review/PR-body post path rendered from the structured record
  (post-time), and the merge gate (merge-recheck). Filed `blocked-by` #150 (helper hosts the post/merge call
  sites), #153 (the `record_visibility` policy block lives in its profile), #155 (record layout + brief
  schema), **and the structured-emit child above** (the post path renders from it). It cannot land before those
  seams exist.

Rollback is a normal revert of the validator + wiring; with the contract reverted, the umbrella's `blocked-by`
pieces are simply un-authorized again — no data loss, since no experiment-PR path ships before this contract's
validator does.

## Decision note (for the PM record)

One genuine product choice surfaced and is recorded here rather than blocking: **whether the contract should
*force* every instance's research repo to be private, or make private a declared, defense-in-depth toggle on
top of a tier-classification that is safe even on a public repo.** This doc takes the latter (default
`require_private_repo: false`, all payload kept off the trail by the tier defaults regardless of repo
visibility) as the most defensible default — it preserves the umbrella's "repo is instance config, may be
public" promise and public alignment-research use, and does not make a single visibility flip the only thing
standing between a payload and the world. An instance that wants the stricter posture sets
`require_private_repo: true`. If Anton prefers private-by-default at the product floor, that is a one-line
default flip in the spawned child, not a redesign.
