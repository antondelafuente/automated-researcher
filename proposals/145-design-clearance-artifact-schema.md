# Proposal: Design-clearance artifact schema — the pre-run gate's machine-readable record (#145)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.
> Doc-only design PR (two-phase, Step 1 of 2); spawns `ready` issues for the implementation.
> Child of #130 (experiments through GitHub). Sibling foundation designs: #150 (shared GitHub-lifecycle
> helper), #153 (instance-profile interface), #154 (audit-runner cross-family contract).

## Problem

When an experiment runs through GitHub (#130), the human clears the design *before* the run, and only then
is the brief handed to a fresh zero-context executor that spends real compute and API budget. The executor
is, by construction, brand new: it did not watch the design conversation, it did not see the human say
"cleared," and it cannot read intent. So before it touches a pod or an API key it must answer one question
from files alone — *is this design actually cleared to run, and is the brief in front of me the one that was
cleared?* — and it must answer it **fail-closed** (no clearance found = do not run).

#130 settles the *model* for this (decision 2, "design approval blocks the run" + "clearance binds to the
reviewed commit"): clearance is recorded against the one commit that carries the full brief
(`DESIGN.md` + `START.md` + `CHECKLIST.md`), and any later change to that brief forces re-clearance. But the
umbrella deliberately leaves the concrete artifact open. Today there is **no file** the executor can read,
no defined fields, and no proceed/block rule — so "the executor verifies the brief commit before any spend"
is an unbacked promise. This design defines that artifact: what it is called, where it lives, what it
contains, who writes it, and the exact rule the executor evaluates to decide proceed-vs-block.

This is the design-gate analogue of the close-gate's triage-artifact (the sibling `needs-design` child of
#130, not yet filed). The two gate **different events** — clearance gates the *run*, triage gates the
*merge* — but they share a per-finding response vocabulary, and this design keeps them consistent so an
executor and a reader learn one finding-response shape, not two.

## Approach

Define a single committed file, `CLEARANCE.json`, that lives in the experiment's canonical working directory
(`experiments/<exp>/`, the durable per-experiment home #130 decision 1 establishes). It is written once by
the **designer** side (`design-experiment`) at the moment the human arbitrates the design audit, and it is
read by the **executor** side (`run-experiment`) as the very first thing it does, before acquiring any
compute. It records *who* cleared the run, *which brief commit* they cleared, and *a response to every
surviving HIGH/MED design-audit finding* — and the executor recomputes the current brief commit and refuses
to run unless it matches the cleared one with a clean, complete set of finding responses.

The artifact is **plain JSON** (machine-read by the executor; trivially human-read in the PR), schema-
versioned, and committed to the branch in its own clearance commit so it lands on `main` in
`experiments/<exp>/` exactly like the rest of the record. It is not a new source of truth about the design —
the `DESIGN.md` + the posted `--design` audit are that — it is the **decision record on top of them**: the
human's verdict, frozen against a SHA.

**The artifact is not self-attesting — and its content is digest-bound to two externally-authored events.** A
designer-written file that merely *says* "anton cleared this" is forgeable; so is one whose internal hash
(`findings_sha256`) is recomputed in the same edit that tampers the findings it hashes. Closing both holes
requires the *trusted, externally-authored* events to attest the **digests of the branch-authored content**,
not just author + SHA. So:

- **(a) The `--design` audit event attests the findings-record digest.** When the `--design` audit is posted
  (by the audit-runner / helper, not the designer), the posted event carries the canonical
  `sha256(findings_record)` in its machine-readable marker. The executor verifies `findings_sha256` in the JSON
  equals **the digest the posted audit event attests** — so an edited `findings_record` (dropping a HIGH) no
  longer matches the audit GitHub published, and BLOCKs. (Hashing the local file against a hash *in the same
  JSON* alone is necessary but not sufficient; the audit event is the external anchor.)
- **(b) The clearance event attests the `CLEARANCE.json` digest.** The authorized clearance event's marker
  carries `sha256(CLEARANCE.json-without-the-event-block)` plus the repo+PR identity. The executor verifies the
  on-disk `CLEARANCE.json` digest equals what the authorized actor's event attests — so editing
  `finding_responses` (e.g. flipping an unanswered HIGH to `justified`) after clearance invalidates the
  attestation and BLOCKs. The actor is committing to *these responses on this brief*, not just "I approve."

**The approver attests a fully-determined pre-approval subdocument — no chicken-and-egg.** The clearance event
must attest the *content*, but the event is authored *before* the final `CLEARANCE.json` exists. This resolves
cleanly because what the approver attests is the **`attested_clearance` subdocument**, which is fully
determined before the event (it is the brief + findings + verdicts; it does **not** contain the approval block).
Ordering:

1. The producer computes the canonical `attested_clearance` subdocument (defined below) from the cleared brief,
   the structured findings record, and the arbitrated responses.
2. The producer presents it to the approver — as the canonical bytes (and their digest) embedded in the
   clearance-comment body, so the approver authorizes exactly those bytes. (A staged `CLEARANCE.draft.json`
   holding the subdocument is an equivalent implementation; the contract is "the approver sees and attests the
   exact subdocument.")
3. The authorized actor posts the clearance event; its marker carries `sha256(attested_clearance)` + the cleared
   SHA + repo/PR identity.
4. `design-experiment` writes the final `CLEARANCE.json` = the attested subdocument **plus** the `approval`
   block (which references that event). Because the approval block is *outside* the attested subdocument, adding
   it does not change the attested digest — no circularity.

**Digests are over a canonical serialization, not raw bytes**, so producer and consumer hash identical bytes:

- The **`attested_clearance` subdocument** is exactly these fields, no more: `schema_version`, `experiment`,
  `decision`, `brief_commit`, `brief_files`, `digest_algorithm`, `brief_blobs`, `design_audit`,
  `finding_responses` — i.e. the whole document **minus** `cleared_at` and the `approval` object (JSON Pointers
  `/cleared_at` and `/approval`, the attestation-pointer fields, which cannot be inside what they attest).
  `brief_files` **is** attested (it pins which files are load-bearing). Serialized as **JCS, RFC 8785**
  (canonical JSON: UTF-8, sorted keys, no insignificant whitespace, canonical number forms); the digest is
  `sha256` over that byte string.
- The `findings_record` is likewise serialized as JCS before hashing, so `findings_sha256` and the audit
  event's attested digest are computed over the same canonical bytes.

The implementation ships a **producer/consumer test vector** (a fixed subdocument → its JCS bytes → its
`sha256`) so both sides are proven to compute the identical digest. The JSON thus records *pointers and the
verdict*; the two external events anchor both the **identity** (authorized actor, cleared SHA) **and the
content** (brief, findings + responses) — so the gate cannot be passed by editing the branch files alone.

**The clearance event is NOT a merge-satisfying GitHub `APPROVED` review.** #130 decision 2 is explicit: the
design review gates the *run*, never the merge — only the *close* gate posts the final merge-satisfying native
APPROVE. If clearance were a native `APPROVED` review it would satisfy branch protection and could merge an
*un-run* experiment, defeating the close gate and the "main only receives closed experiments" promise. So the
clearance event is a **non-merge-satisfying signal**: a structured **clearance comment** (a canonical PR
comment carrying a machine-readable marker — `clearance: cleared`, the cleared SHA, the repo+PR identity, and
the attested `CLEARANCE.json` digest) posted by the authorized actor. The executor re-fetches it via the helper
and verifies author + SHA + repo/PR identity + the attested digest; it never reads as a GitHub approval, so it
cannot satisfy the merge gate. (A GitHub *review thread* could also carry it if the
helper guarantees it is posted as a COMMENT/REQUEST_CHANGES event, never APPROVE — but the canonical-comment
form is the safe default precisely because it is structurally incapable of satisfying branch protection.)
`approval.event_kind` records which form was used so the executor checks the right surface; the field is named
`approval` for continuity but the event is a clearance signal, not a merge approval.

### The schema

`experiments/<exp>/CLEARANCE.json`:

```json
{
  "schema_version": 1,
  "experiment": "exp-slug",
  "decision": "cleared",
  "cleared_at": "2026-06-28T19:04:00Z",
  "approval": {
    "approver": "anton",
    "approver_role": "design-approver",
    "event_kind": "pr_comment",
    "event_ref": "https://github.com/<owner>/<repo>/pull/<n>#issuecomment-<id>",
    "event_id": "IC_kwDO...abc123",
    "actor": "anton",
    "cleared_sha": "9f3a1c4e8b2d6a0f5c7e9b1d3f5a7c9e1b3d5f7a"
  },
  "brief_commit": "9f3a1c4e8b2d6a0f5c7e9b1d3f5a7c9e1b3d5f7a",
  "brief_files": ["DESIGN.md", "START.md", "CHECKLIST.md", "data_audit_manifest.md"],
  "digest_algorithm": "sha256",
  "brief_blobs": {
    "DESIGN.md": "b1946ac9...",
    "START.md": "591785b7...",
    "CHECKLIST.md#gates": "1d229271...",
    "data_audit_manifest.md#design": "84a516841..."
  },
  "design_audit": {
    "audit_ref": "https://github.com/<owner>/<repo>/pull/<n>#pullrequestreview-<id>",
    "audit_commit": "9f3a1c4e8b2d6a0f5c7e9b1d3f5a7c9e1b3d5f7a",
    "findings_record": "experiments/<exp>/audits/design-audit.json",
    "findings_sha256": "9b74c9897bac770ffc029102a200c5de...",
    "summary": { "high": 0, "med": 2, "low": 4 }
  },
  "finding_responses": [
    {
      "id": "M1",
      "severity": "med",
      "status": "justified",
      "evidence": "Single-seed accepted: effect size >> documented run-to-run variance; see DESIGN.md §5."
    },
    {
      "id": "M2",
      "severity": "med",
      "status": "deferred",
      "followup_issue": "#161",
      "evidence": "Cross-model generalization is a separate experiment; out of scope for this run."
    }
  ]
}
```

`brief_blobs` are illustrative truncated digests; the implementation uses the single `digest_algorithm`
(`sha256` in schema v1 — one algorithm, not a per-file choice, for determinism) over each drift-checked unit,
captured at clearance — see the brief-integrity rule. The `--design` audit is persisted as
a **structured `findings_record`** (a machine-readable finding list: stable id, severity, text per finding)
committed alongside the brief, and `findings_sha256` pins its content so the response set is validated against
the *actual* findings, not a copied integer. **The findings record is the one from the audit on the cleared
brief** (the final audit, after any fixes) — see "The fix loop" below; that is why the example shows `high: 0`
and the surviving responses are `justified`/`deferred`, never `fixed`.

**Field contract:**

| Field | Type | Required | Meaning |
|---|---|---|---|
| `schema_version` | int | yes | Schema generation; executor rejects an unknown major it cannot parse (fail-closed). |
| `experiment` | string | yes | Experiment slug; must equal the `experiments/<exp>/` dir name (cross-check against path). |
| `decision` | enum `cleared` \| `blocked` | yes | The verdict. Only `cleared` permits a run; `blocked` is a terminal record (see Terminal states). |
| `cleared_at` | RFC-3339 UTC | yes | When the verdict was recorded. |
| `approval.approver` | string | yes | Identity recorded as having arbitrated (human-readable). |
| `approval.approver_role` | string | yes | Fixed `"design-approver"` today; a field, not a literal, so a future delegated-approver policy needs no schema bump. |
| `approval.event_kind` | enum `pr_comment` \| `non_approve_review` | yes | Which **non-merge-satisfying** surface carries the clearance signal, so the executor fetches the right one. Never a GitHub `APPROVED` review (#130 decision 2). |
| `approval.event_ref` | string (URL) | yes | Human pointer to the clearance event. Pointer only — never a payload (#130 record-sensitivity). |
| `approval.event_id` | string | yes | The GitHub node-id of the clearance comment/review the executor **re-fetches** to verify; not trusted from the JSON. |
| `approval.actor` | string | yes | The GitHub login that authored the clearance event. Must be an **authorized approver** (instance-profile policy, #153) — the executor checks the fetched event's author equals this and is authorized; a designer cannot self-clear by writing a string. |
| `approval.cleared_sha` | 40-hex SHA | yes | The commit the clearance event names (carried in the comment marker / review SHA). Must equal `brief_commit`. |
| `brief_commit` | 40-hex SHA | yes | The commit carrying the cleared brief — the **final** audited brief (the binding target, #130 decision 2). |
| `brief_files` | string[] | yes | The brief files present at `brief_commit`; `["DESIGN.md","START.md","CHECKLIST.md"]` (#130), **plus `data_audit_manifest.md` (required on the GitHub path)** — its `#design` block is drift-checked, its generated values are not (see "Data-audit manifest"). Listed so the verifier can assert presence. Drift-coverage differs per file — see `brief_blobs`. |
| `digest_algorithm` | enum (fixed `"sha256"` in v1) | yes | The one digest algorithm for `brief_blobs`/all digests in this schema. Fixed for determinism (#130 F3 fix); a future algorithm is a schema-version bump, not a per-file choice. |
| `brief_blobs` | object (unit→digest) | yes | `digest_algorithm` digest of each **drift-checked unit** at `brief_commit`: `DESIGN.md` whole, `START.md` whole, `CHECKLIST.md#gates` (gate-definition block only), and `data_audit_manifest.md#design` (the design-intent block; **required on the GitHub path**) — in each case the run-evidence/generated section is excluded so the executor can write it. The integrity anchor the executor compares current content against (brief-integrity rule). |
| `design_audit.audit_ref` | string (URL) | yes | Pointer to the posted `--design` PR review the verdict arbitrates. Pointer only — never the audit payload (#130 record-sensitivity). |
| `design_audit.audit_commit` | 40-hex SHA | yes | The commit the `--design` audit reviewed. Must equal `brief_commit`; if they differ the executor blocks (the audited design is not the cleared brief). |
| `design_audit.findings_record` | string (path) | yes | Committed path of the **structured** machine-readable audit finding list (id, severity, text per finding) the responses are validated against — not a copied count. |
| `design_audit.findings_sha256` | hex | yes | Content hash of `findings_record`, pinning the exact finding set the responses answer (so an edited file is detected). |
| `design_audit.summary` | `{high,med,low}` ints | yes | The audit's `SUMMARY` counts; a fast cross-check, but completeness is validated against `findings_record`, not this number. |
| `finding_responses` | object[] | yes (may be empty only if the findings record has zero HIGH and zero MED) | One entry per HIGH/MED finding in `findings_record`. |
| `finding_responses[].id` | string | yes | The finding identifier; **must match an id present in `findings_record`** (validated, not trusted). |
| `finding_responses[].severity` | enum `high` \| `med` | yes | Echoes the finding's severity (LOW findings need no response). |
| `finding_responses[].status` | enum `justified` \| `deferred` | yes | The verdict on a finding that **survives** into the cleared brief. |
| `finding_responses[].evidence` | string | yes | Why: the justification or the deferral rationale. Non-empty. |
| `finding_responses[].followup_issue` | string | required iff `status=="deferred"` | The issue the deferral is tracked in. Must be a valid issue reference — `#123` or a full GitHub issue URL (the same syntax `ship-change`'s `disposition_gate.sh` enforces); the executor rejects a malformed link. |

The status vocabulary is the close-gate triage artifact's `{fixed | justified | deferred}` **minus `fixed`**.
The reason is structural, not a divergence (see "The fix loop"): a `fixed` finding required a post-audit brief
change, so it cannot survive into a clearance bound to the *same* commit the final audit reviewed — a fix is
represented by the finding being **absent** from the cleared findings record, not by a `fixed` status. The
close gate keeps `fixed` because its fixes happen in-PR against the merge head; clearance's fixes happen by
re-auditing the corrected brief. So the two gates share the *surviving-finding* vocabulary
(`justified`/`deferred`) exactly — the consistency ask in #145/#130 — and differ only where the lifecycle
genuinely differs.

### The fix loop (why `audit_commit == brief_commit` is consistent with fixing findings)

The design audit can return HIGH/MED findings the designer wants to *fix*, not justify. Fixing a finding
changes the brief — which would break the invariant that the cleared brief is the *audited* brief. The loop
that resolves this, and the reason the proceed rule can safely require `audit_commit == brief_commit`:

1. Audit runs on brief commit *A*. Designer triages: fix some findings (edit `DESIGN.md`/`START.md`), justify
   or defer the rest.
2. If anything was **fixed**, the brief changed → the designer **re-runs `--design`** on the new brief commit
   *B*. (This is the same "any change forces re-clearance/re-review" property #130 already requires; a fix is a
   change.) Repeat until an audit run reviews the *current* brief with no findings the designer still intends
   to fix.
3. **Clearance binds that final commit**: `brief_commit` = the commit the *final* audit reviewed,
   `audit_commit == brief_commit`, and `findings_record` is that final audit's output. The only findings left
   in it are the ones the designer chose to **justify or defer** — never `fixed`, because a fixed finding is
   gone from the final audit. That is why `fixed` is not in the clearance vocabulary and why rule 5
   (`audit_commit == brief_commit`) is not in tension with fixing: fixes happen *before* the binding audit, not
   recorded against it.

So "fix a finding" is fully supported — it just resolves to *re-audit then bind the clean commit*, the
re-clearance loop, rather than a `fixed` annotation on a stale audit.

### Checklist: pin the gate definitions, leave the evidence mutable

There is a real tension here. #130 decision 2 says clearance binds the brief commit carrying **all three**
files — including `CHECKLIST.md` — and any later change forces re-clearance; the *gates* the executor must pass
are exactly the kind of thing that must not silently change after clearance. But the executor also *works*
`CHECKLIST.md` during the run (ticking gates, recording evidence — `run-experiment`'s "work the checklist as
you go"), so a naive content-equality rule over the whole file would block the executor on its own expected
edits.

Resolution — **separate the immutable gate definitions from the mutable run-evidence**, and drift-check only
the former. Concretely, the checklist's static content (the gate/instruction definitions — *what* must pass) is
captured at clearance as a pinned representation in `brief_blobs` (a `CHECKLIST.gates` digest over the checklist's
gate-definition section, the part the executor reads but must not change), while the run-evidence the executor
appends (checkmarks, per-gate notes) is written to a **separate run record** (or a clearly-delimited evidence
section excluded from the digest). So:

- The **gate definitions are drift-checked** — changing what the executor must satisfy after clearance forces
  re-clearance, honoring #130's "later brief change forces re-clearance" for the load-bearing part.
- The **evidence is freely mutable** — the executor records its work without tripping the gate.

**The split is a concrete delimiter, fixed here** (not left to the children) so producer and consumer hash the
same bytes. Today's `CHECKLIST_TEMPLATE.md` interleaves protocol + annotated record in one file, so the schema
mandates a delimited **gates block** within `CHECKLIST.md`:

```
<!-- BEGIN GATES (immutable after clearance) -->
... gate definitions: what must pass ...
<!-- END GATES -->
... run-evidence below: freely mutable by the executor ...
```

`CHECKLIST.md#gates` is the canonical content **between** those two markers (the markers included, the bytes
outside excluded), normalized to UTF-8 with trailing-whitespace stripped per line — that exact byte range is
what `brief_blobs["CHECKLIST.md#gates"]` digests, and the executor recomputes the same range. The executor
writes evidence only *outside* the block, so its edits never change the digested bytes. (`CHECKLIST_TEMPLATE.md`
gains these markers — a one-line addition to the producer child's template edit.) `brief_files` lists all three
files (#130); `brief_blobs` pins `DESIGN.md` and `START.md` whole plus this gates block.

**On the GitHub path the gates block is mandatory — fail-closed.** A GitHub-path checklist with **no
`BEGIN/END GATES` block BLOCKs** (a markerless checklist there would have nothing to pin, fail-*open* on the
load-bearing gates — unacceptable). Markerless checklists are allowed **only on the legacy local path**, where
they keep today's tick-in-place behavior. So the contract is: gate definitions are pinned and drift-checked
(and *required* on the GitHub path); run-evidence is not — satisfying both #130 (the brief's gates bound at
clearance) and the run-mutability reality.

**Evidence maps back to gates by stable id.** Because evidence now lives *outside* the pinned block, the
zero-context executor/reader must still map each evidence note to its gate. So each gate definition carries a
**stable gate id**, and the mutable evidence section references findings/notes **by that id** (the evidence↔gate
mapping the one-file format gave for free). The exact evidence record format (a delimited per-id evidence
section vs. a separate run-record) is the producer child's call; the *contract* fixed here is "gates have stable
ids; evidence references them," so nothing is lost by moving evidence out of the block.

### Data-audit manifest: pin the design-intent block, leave the generated values mutable

The scaffold treats `data_audit_manifest.md` as a standing **load-bearing design artifact** — purpose,
sources, transformations, invariants, and *what would invalidate the experiment* (the `--data` gate's
reference) — so on the GitHub path it is **required**, not optional. But like `CHECKLIST.md` it is *partly
executor-mutated*: the executor fills in generated paths/hashes/counts *after* generating the data. So pinning
it whole would block on those expected edits — the same trap. It gets the **same delimited-block treatment** as
the checklist:

```
<!-- BEGIN MANIFEST DESIGN (immutable after clearance) -->
... purpose, sources, transformations, invariants, what-would-invalidate ...
<!-- END MANIFEST DESIGN -->
... generated paths / hashes / counts: filled by the executor, mutable ...
```

`data_audit_manifest.md#design` (the normalized byte range between the markers) is the drift-checked unit pinned
in `brief_blobs` and included in the attested subdocument; the generated-values section below `END MANIFEST
DESIGN` stays mutable. The rule is **required + fail-closed on the GitHub path**: a GitHub-path experiment must
have a manifest, and a **missing `BEGIN/END MANIFEST DESIGN` block, or a present-but-unpinned design block,
BLOCKs** (so the load-bearing intent/invariants cannot be quietly omitted or silently changed after clearance).
`DATA_AUDIT_MANIFEST_TEMPLATE.md` gains these markers (the producer child's template edit, same shape as the
checklist one); markerless manifests are allowed **only on the legacy local path**, where they keep today's
behavior (back-compat, as with the checklist).

### Path and produce/consume contract

- **Path / home.** `experiments/<exp>/CLEARANCE.json` — the canonical per-experiment dir on the research
  repo's `main` (#130 decision 1). Clearance is **its own commit on top of the brief commit**, not co-located
  in the brief commit: it is recorded *after* the audit and arbitration, and what binds it to the brief is the
  `brief_commit` field, not physical co-location. (Co-committing clearance with the brief would make the
  binding circular — you cannot name a commit's own SHA from inside that same commit — and would itself change
  the brief tree, re-triggering re-clearance.)
- **Producer = `design-experiment`** (the designer side). The clearance event itself is the authorized actor's
  **non-merge-satisfying clearance signal** on the experiment PR (the structured clearance comment / non-APPROVE
  review above) — that is what the executor verifies, so it must be authored by an authorized actor, not
  synthesized by the designer agent. After that event exists (against the *final*, post-fix-loop brief commit),
  `design-experiment` *records* it: it writes `CLEARANCE.json` with `decision:"cleared"`, the `approval` block
  fetched from the clearance event (`event_kind`, `event_id`, `actor`, `cleared_sha`), the arbitrated finding
  responses, `brief_commit` = the cleared SHA, and the `brief_blobs` digests; commits it; and only then hands
  off to the executor. A `decision:"blocked"` verdict is written instead when the authority declines to clear —
  a terminal record, no executor handoff (the precise blocked-state semantics are owned by #130's terminal-states
  child; this schema only reserves the enum value so the file shape is forward-compatible).
- **Consumer = `run-experiment`** (the executor side). Step 0, before any compute/API spend: read
  `experiments/<exp>/CLEARANCE.json`, **re-fetch and verify the clearance event** and the structured findings
  record (not trusting the JSON's copies), evaluate the proceed condition (below), and **block** (do not
  acquire a pod, do not call an API) on any failure, emitting the precise reason.

### Validation + fail-closed proceed rule

The executor proceeds **iff all** hold; **any** failure blocks (fail-closed — a missing/malformed file is a
block, never a pass). Crucially, rules 4, 6, and 7 verify against **external sources** (Git content, the
authorized clearance event's attested digest, and the posted audit event's attested findings digest), so the
gate cannot be passed by editing the branch files in concert — the externally-authored events anchor both
identity and content:

1. **File exists and parses** as JSON with a `schema_version` the executor supports. Missing file, parse
   error, or unknown major version → BLOCK.
2. **`decision == "cleared"`.** Any other value (`blocked`, or absent) → BLOCK.
3. **`experiment`** equals the `experiments/<exp>/` directory name → else BLOCK (mis-filed artifact).
4. **Brief integrity (the re-clearance trigger) — two-sided, both against `brief_blobs`.** The drift-checked
   units are `DESIGN.md` whole, `START.md` whole, the **gate-definition block of `CHECKLIST.md`** (the static
   gates — *not* the run-evidence section the executor mutates; see "Checklist" above), and the
   **design-intent block of `data_audit_manifest.md`** (`#design` — required on the GitHub path; *not* the
   generated paths/hashes/counts the executor fills; see "Data-audit manifest" below). For each unit the
   executor performs **both** comparisons, and BLOCKs on either mismatch:
   - **(a) `brief_blobs` actually describes the audited commit.** Recompute the unit's digest **from the Git
     tree at `brief_commit`** and require it equals the `brief_blobs` entry. This closes the hole where a
     `brief_blobs` digest is fabricated to match drifted working-tree content while `brief_commit` (the audited
     SHA) holds different bytes — without it, the gate could bind the audit SHA but run un-audited content.
   - **(b) the working tree has not drifted since clearance.** Recompute the unit's digest from the **current
     working-tree content** and require it equals the same `brief_blobs` entry.

   The executor compares content digests, not commit identity (clearance is its own commit on top, so
   `HEAD != brief_commit` always — comparing SHAs directly would block every run). (a) anchors `brief_blobs` to
   the audited commit; (b) is the re-clearance trigger. Any unit failing either → BLOCK with the precise reason
   ("brief_blobs does not match brief_commit" or "brief changed since clearance — re-clear before running").
   This is #130's "any later change forces re-clearance" for the load-bearing brief content, made mechanical,
   while leaving checklist evidence freely writable.
5. **Audit binds the cleared brief.** `design_audit.audit_commit == brief_commit` → else BLOCK (the audited
   design is not the brief being run). Consistent with fixing findings via the fix loop above — the binding
   audit is the *final* one.
6. **Clearance event is real, non-merge-satisfying, authorized, and content-attesting.** The executor
   **re-fetches** the event named by `approval.event_id`/`event_kind` (via the shared helper, #150) and
   requires: it exists and is the declared kind; it is **not** a GitHub `APPROVED` review (a clearance event
   must be structurally non-merge-satisfying — #130 decision 2); its author equals `approval.actor`; `actor` is
   an **authorized approver** per the instance-profile policy (#153); the repo+PR identity in its marker matches
   this experiment; the SHA it names equals `approval.cleared_sha == brief_commit`; **and the digest it attests
   equals `sha256` of the on-disk `attested_clearance` subdocument** (the exact field set defined above —
   document minus `/cleared_at` and `/approval` — serialized JCS/RFC 8785). A missing event, an APPROVE-typed
   event, an unauthorized actor, a wrong repo/PR, a SHA mismatch, or a digest mismatch → BLOCK. Producer and
   consumer run the identical transform (proven by the shipped test vector), so the check is deterministic. (The
   digest attestation is what stops a designer editing `finding_responses` after clearance: the authorized actor
   committed to *these* responses.)
7. **Finding-response completeness, validated against the externally-attested findings record.** The executor
   loads `design_audit.findings_record`, verifies `sha256(findings_record) == findings_sha256` **AND that this
   digest equals the one the posted `--design` audit event attests** (else BLOCK — the findings were edited
   after the audit GitHub published). It then requires: every HIGH and every MED finding **id present in the
   findings record** has exactly one `finding_responses` entry with matching `id` and `severity`; every response
   `id` exists in the record (no phantom responses); every response has non-empty `evidence`; every `deferred`
   has a `followup_issue` that is a **valid issue reference** (`#123` or a GitHub issue URL — the
   `disposition_gate.sh` syntax). A HIGH/MED with no response, a phantom/mismatched id, an empty evidence, or a
   deferral with a missing/malformed issue link → BLOCK. (`summary` is a fast cross-check only; the
   *externally-attested record* is the denominator, so a hand-shrunk count or a re-hashed local file can't hide
   an unanswered finding.)

The executor records the verdict (proceed or the block reason) to its run log / ledger, so the
proceed-decision is itself auditable. The block reason is a single precise line (which rule failed), never a
generic "not cleared."

### What this does NOT own (seams to siblings)

- **Who may approve / the authorized-approver policy** — `approval.approver_role` is a field so a future
  delegated-approver policy is a value change, not a schema change; *which* actors count as authorized is the
  instance-profile's call (#153). This schema requires the executor to check `actor` against that policy, but
  it does not define the policy.
- **Fetching/verifying the GitHub clearance event** — the read is performed via the shared GitHub-lifecycle
  helper (#150). This schema names what to fetch (`event_id`/`event_kind`) and the proceed condition (including
  the "must not be APPROVE", repo/PR-identity, and `CLEARANCE.json`-digest checks); the helper owns the GitHub
  read. And the cross-family guarantee on the `--design` audit the responses answer is owned by the
  audit-runner cross-family contract (#154). This schema only *records results*; it must not become a second
  home for cross-family enforcement (the #130 decision-5 boundary).
- **The posted `--design` audit event attesting the findings digest** — for the external-content anchor (proceed
  rule 7) to hold, the audit-posting step (the helper / audit-runner, #150/#154) must include
  `sha256(findings_record)` in the posted audit event's marker. This schema *requires* that attestation and
  *consumes* it; producing it is the audit-posting step's job, named here as a dependency so #150/#154 carry it.
  Likewise the authorized clearance-comment marker (carrying the `CLEARANCE.json` digest) is posted via the
  helper. This schema does not own GitHub posting — only what the markers must contain and how the executor
  checks them.
- **Emitting the structured `findings_record`** — `findings_sha256`/`findings_record` require a machine-readable
  audit finding list with **stable ids** (id, severity, text per finding). The audit engine
  (`verify-claims`/`audit_experiment`) currently emits markdown `FINDING:`/`SUMMARY:` text, not canonical JSON
  with ids, so this schema **depends on** a structured-audit-output capability (a thin parser of the existing
  markdown into a stable-id JSON record, or a small `verify-claims` emit-JSON mode). That capability is a named
  **prerequisite** of the consumer child (Rollout), not owned here — this schema only *consumes* the record.
- **How `experiments/<exp>/` is located** (repo / base branch / branch prefix) — the instance-profile
  interface (#153). This schema names the path *relative to* that dir; it does not resolve the dir.
- **Whether/how committed clearance content is sensitive** — the audit-derived content this artifact commits
  (`summary`, per-finding `evidence`, the `findings_record`) is governed by #130's **record-sensitivity /
  visibility contract**, which the umbrella makes a hard blocker for any committed audit-derived evidence. This
  schema constrains itself to **pointers** for the approval/audit *events* (`pr_ref`, `audit_ref` — URLs, never
  payloads), but the finding evidence text and the findings record are committed content, so the implementation
  children are **`blocked-by` the record-sensitivity contract** (see Rollout).
- **The blocked/terminal-state semantics** beyond reserving the `decision:"blocked"` enum value — #130's
  terminal-experiment-states child.
- **The close-gate triage artifact** — the sibling design; this one shares its vocabulary but gates a
  different event.

## Alternatives considered

- **No artifact — clearance is implicit in a posted PR review.** Rejected: a zero-context executor cannot
  reliably parse an arbitrary human review body into a proceed/block decision, and a PR review is not bound
  to the brief SHA the way a recorded `brief_commit` is. The whole point is a file the executor reads
  fail-closed; an implicit signal fails open.
- **Encode clearance as a Git signed tag / trailer instead of a file.** Rejected: a tag carries no
  per-finding response set and no audit binding; the finding-response completeness rule is the substance of
  the gate, and a tag has nowhere to put it. A committed JSON file lands in `experiments/<exp>/` with the
  rest of the record and is the same shape the reader/close gate already expect.
- **YAML / front-matter inside `DESIGN.md`.** Rejected: putting clearance *inside* the brief makes the
  binding circular (the clearance would change the brief it claims to clear, re-triggering re-clearance), and
  couples a machine-gate to prose parsing. A separate file binds cleanly by SHA.
- **Reuse the close-gate triage artifact verbatim (one schema, both gates).** Rejected as over-coupling: the
  two gate different events with different required fields (clearance needs the `approval` block + `brief_commit`
  + audit binding; triage needs the merge-head SHA + per-finding merge disposition). Sharing the **status
  vocabulary** captures the real overlap without forcing one file to serve two gates — and lets each evolve.
- **Parse `high=0` from the audit summary as the proceed rule (no per-finding responses).** Rejected for the
  same reason #130 rejects it for the close gate: the research protocol permits a HIGH to be *justified*, not
  only *fixed*, so a raw count would block a legitimately-justified design. The per-finding response set is
  what lets a justified HIGH proceed while an unanswered HIGH blocks.
- **Use a native GitHub `APPROVED` review as the clearance event.** Rejected: #130 decision 2 forbids it — a
  native APPROVE would satisfy branch protection and could merge an *un-run* experiment, defeating the close
  gate. Clearance must be structurally non-merge-satisfying (a structured comment / non-APPROVE event), and the
  proceed rule explicitly BLOCKs on an APPROVE-typed clearance event.
- **Record `fixed` findings in the clearance responses (one vocabulary with the close gate).** Rejected: a
  `fixed` finding implies a post-audit brief change, contradicting the `audit_commit == brief_commit` binding.
  Fixes resolve via the re-audit loop (the finding disappears from the final record), so clearance carries only
  `justified`/`deferred` — sharing the close gate's *surviving-finding* vocabulary without the structurally
  inapplicable `fixed`.

## Blast radius

- **Product skills** (`automated-researcher`): `design-experiment` gains "write `CLEARANCE.json` at
  clearance"; `run-experiment` gains "read + evaluate `CLEARANCE.json` as the pre-spend gate." These are the
  implementation `ready` children spawned from this design.
- **Scoped to the GitHub experiment-lifecycle path — NOT a global `run-experiment` change.** The fail-closed
  CLEARANCE step applies only on the #130 GitHub-PR experiment path (an experiment that has an
  `experiments/<exp>/` dir on a `run/<exp>` branch). Today's local brief handoff — a `run-experiment` that
  reads `DESIGN.md` + `START.md` + `CHECKLIST.md` from a working tree with no `experiments/<exp>/` / no
  experiment PR — is **unaffected**: the gate is the new GitHub path's contract, not a retrofit onto every
  existing/in-flight run. So no in-flight local run breaks for lack of a `CLEARANCE.json`. (Making the GitHub
  path the *default* is #130's own staged rollout, not this schema's.)
- **The shared checklist template change is back-compatible (the one genuinely shared edit).** Adding the
  `BEGIN/END GATES` markers touches `CHECKLIST_TEMPLATE.md` and `run-experiment`'s evidence-writing, which all
  runs consume — so it must not break a **markerless** checklist (every existing/in-flight checklist, and the
  local-handoff contract). Contract: the markers are **additive and optional**; a markerless checklist behaves
  exactly as today — the executor ticks in place as before, and the GitHub-path drift check simply has no
  `CHECKLIST.md#gates` unit to pin (a markerless checklist is not gate-drift-checked). On the **GitHub path the
  markers are mandatory and a missing block BLOCKs** (fail-closed — never fail-open on the load-bearing gates);
  markerless is allowed *only* on the legacy local path, where behavior is unchanged. So the prior bullet's
  "local handoff unaffected" holds: the shared template gains structure that is required on the new path and
  optional (behavior-preserving) on the old one.
- **Canonical record path:** adds `CLEARANCE.json` + a committed structured `findings_record` to the
  `experiments/<exp>/` layout #130 establishes — event references are pointer-only (`event_ref`/`audit_ref`
  URLs), but the per-finding evidence + findings record are committed content governed by #130's
  record-sensitivity contract (see Rollout `blocked-by`).
- **Touches the shared GitHub-lifecycle helper (#150):** as a *consumer*, the executor needs a primitive to
  fetch + verify a non-approve clearance event (`event_id`/`event_kind` → actor/SHA/repo-PR/attested-digest,
  assert not APPROVE). As a *producer requirement*, the audit-posting and clearance-comment steps must include
  the findings digest / `attested_clearance` digest in their event markers (the external-content anchors). This
  marker **verification path is run-authority**: it is exactly the authority the executor trusts to decide
  proceed-vs-spend, so a branch-modified verifier reading its own forged marker would be the run-side analogue
  of the merge-authority trust hole. Whether marker production/verification therefore loads from #150's
  trusted-base source (vs plain runtime) is **#150's open trust-split decision** — this schema does **not**
  pre-decide it (an earlier draft wrongly classified it as non-trusted-base plumbing). It only states the
  requirement: the verification must be trustworthy under whatever #150 settles, and the implementation children
  are `blocked-by` #150 for that classification.
- **Depends on a structured-audit-output capability** (correcting the prior draft's "no `verify-claims`
  change"): the `findings_record` needs stable-id JSON findings, which the audit engine does not emit today.
  This is a named prerequisite of the consumer child (a thin markdown→JSON parser with id generation + a parser
  smoke, or a small `verify-claims` emit-JSON mode) — see Rollout.
- **Product, not instance.** The schema is product (it ships in the skills); the `CLEARANCE.json` files it
  produces land in the instance research repo, like every other experiment record. The authorized-approver
  *policy* is instance config (#153).

## Rollout + rollback

Doc-only design PR: lands the schema on `main` via the `--scaffold` gate, then spawns the implementation
`ready` child(ren):

0. **Prerequisite: structured `--design` audit output with stable ids** — a thin markdown→JSON parser of the
   existing audit `FINDING:`/`SUMMARY:` output (id generation + a parser smoke), or a small `verify-claims`
   emit-JSON mode. The `findings_record`/`findings_sha256` rules depend on it, so it lands before (or with) the
   consumer child.
1. **`design-experiment`: write `CLEARANCE.json` at clearance** — the producer step: after the authorized
   non-merge-satisfying clearance event exists against the final brief commit, record the `approval` block,
   finding responses, `brief_commit`, and `brief_blobs`; commit + a writer-side schema assert. **Includes the
   checklist + manifest contract restructure**: add the `BEGIN/END GATES` markers to `CHECKLIST_TEMPLATE.md`
   and the `BEGIN/END MANIFEST DESIGN` markers to `DATA_AUDIT_MANIFEST_TEMPLATE.md`, and update both
   `design-experiment` (gates/design-intent defined inside the blocks) and `run-experiment` (evidence and
   generated values written *outside* the blocks — "tick in place" / "fill paths/hashes/counts" relocated below
   the `END` markers) instructions + tests, so producer and consumer hash the same pinned bytes and in-place
   executor edits never trip the drift check. Markerless files keep today's behavior (back-compat).
2. **`run-experiment`: read + evaluate `CLEARANCE.json` as the pre-spend gate (GitHub path only)** — the
   consumer step + the 7-rule fail-closed proceed rule, with smokes that each of these BLOCKs: a
   missing/malformed file; a brief-drifted file (gate-definition section changed) — while checklist *evidence*
   edits do **not** block; a forged/absent clearance event; an APPROVE-typed event (clearance is not
   merge-satisfying); a `CLEARANCE.json` whose digest the clearance event does not attest (tampered responses);
   a `findings_record` whose digest the posted audit event does not attest (tampered findings); and that a
   local-handoff run with no `experiments/<exp>/` is untouched.

Both implementation children are filed **`blocked-by`**: the GitHub-lifecycle helper (#150, for the
clearance-event fetch/verify primitive + the resolved commit/branch identity), the instance-profile interface
(#153, for *where* `experiments/<exp>/` lives and the authorized-approver policy), the structured-audit-output
prerequisite (step 0), **and #130's record-sensitivity / visibility contract** (for what finding-evidence
content may be committed vs redacted vs pointer-only — the umbrella makes this a hard blocker for committed
audit-derived evidence). They are filed at design-merge so the dependency graph is explicit, and become
actionable when those parents land.

Rollback is a normal revert of the spawned skill edits: the lifecycle falls back to the status-quo
(clearance lives only in the design conversation, executor trusts the handoff) with no data loss — the schema
file is additive and unread by anything until the consumer step ships.
