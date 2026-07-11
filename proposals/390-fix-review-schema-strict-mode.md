# Proposal: fix `review-on-pr`'s codex-action output-schema to pass OpenAI strict-mode validation (#390)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

Both live `review-on-pr` workflow runs failed ~20s in with:

    Invalid schema for response_format 'codex_output_schema': 'additionalProperties' is required to be supplied and to be false

The `output-schema` passed to `openai/codex-action` in `.github/workflows/review-on-pr.yml` (~line 114)
is not valid under OpenAI's structured-outputs STRICT-mode validator. This blocks the review leg of the
GitHub-native SWE pipeline end-to-end — no PR can get a codex review, so `submit-verdict` never runs and
nothing merges through the enforced gate. This is bug 5 in the pipeline-bootstrap chain (#381, #382, #384,
#387 — vendor-dialect quirks found live only once each step actually ran; #382 was the Anthropic-side
mirror of this same genre of "the vendor's real-world validator is stricter than the docs example implied").

Concretely, the current schema:

    {
      "type": "object",
      "required": ["verdict", "findings"],
      "properties": {
        "verdict": { "enum": ["approve", "changes_requested"] },
        "findings": {
          "type": "array",
          "items": {
            "type": "object",
            "required": ["severity", "summary"],
            "properties": {
              "severity": { "enum": ["P0", "P1"] },
              "summary": { "type": "string" },
              "evidence": { "type": "string" }
            }
          }
        }
      }
    }

violates two of OpenAI's documented strict-mode rules (verified against
https://developers.openai.com/api/docs/guides/structured-outputs):

1. `additionalProperties: false` must be set explicitly on *every* object level. Neither the top-level
   object nor the nested `findings.items` object sets it.
2. Every key present in an object's `properties` map must also appear in that object's `required` array —
   optionality is expressed via a nullable type (`["string", "null"]`), not by omitting the key from
   `required`. `findings.items` declares `evidence` in `properties` but not in `required`.

## Approach

Make the schema strict-mode valid, checked against the full OpenAI strict-schema rule set (not just the
two rules the error message names), so it passes validation on the first retry:

    {
      "type": "object",
      "additionalProperties": false,
      "required": ["verdict", "findings"],
      "properties": {
        "verdict": { "type": "string", "enum": ["approve", "changes_requested"] },
        "findings": {
          "type": "array",
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["severity", "summary", "evidence"],
            "properties": {
              "severity": { "type": "string", "enum": ["P0", "P1"] },
              "summary": { "type": "string" },
              "evidence": { "type": ["string", "null"] }
            }
          }
        }
      }
    }

Changes from the current schema:
- `"additionalProperties": false` added at both object levels (top-level and `findings.items`).
- `evidence` moved into `required`; its type becomes `["string", "null"]` so the model can express "no
  evidence" as an explicit null rather than by omitting the field (which strict mode disallows).
- `"type": "string"` added alongside the two `enum` declarations (`verdict`, `severity`). Not itself the
  cause of the observed failure — OpenAI's own examples show `enum` used both bare and paired with an
  explicit `type`, and the community reports of enum-specific strict-mode failures found during review
  were about literal quote/linefeed characters *inside* enum values (irrelevant here — our enum values are
  plain tokens). Added anyway per the "first retry" bar in the Issue: it's the form on record in OpenAI's
  own documented examples and removes one more untested corner from a schema that has already round-tripped
  once for other reasons.
- Root stays a top-level `object` (already satisfies the "root must be an object" rule).

**Downstream null-safety.** The `submit-verdict` job's jq body renders each finding as
`.evidence and (.evidence | length) > 0` to decide whether to append an "evidence:" line. Checked directly:
`jq` treats `null` as falsy for `and`, and `null | length` is `0`, so a `null` evidence value already
renders as "no evidence line" without any crash or `null`-literal leaking into the PR comment. No change
needed there — verified, not assumed.

## Alternatives considered

- **Drop `evidence` from the schema entirely.** Rejected: it's useful review context ("cite the exact file
  and evidence" is explicitly requested in the review prompt); nullable-required is the standard strict-mode
  idiom for an optional field, not a workaround.
- **Switch `enum` fields to a bare `enum` with no `type`.** Current form (bare enum, no type) is what's
  live and broken-on-an-unrelated-axis; since the docs' own examples pair `type` + `enum`, there's no
  reason to keep the untested bare form when the paired form is strictly not worse and closes off one more
  hypothetical validator quirk before the next live retry.

## Blast radius

Single file: `.github/workflows/review-on-pr.yml` (the `output-schema` block passed to
`openai/codex-action`, ~line 114). No change to `implement-on-ready.yml` or `checks.yml`. No change to
repo settings (auto-merge was already fixed separately, per the Issue). Runtime effect is scoped to how
the codex review response is validated/shaped for this one workflow — the review's semantic content
(severity levels, verdict values) is unchanged.

## Rollout + rollback

No staged rollout needed — this is a workflow-file-only change exercised the next time a `review-on-pr` run
fires (i.e. on this very PR, via the cross-family `--code` review gate in `wf.sh finish`, which is itself
gated by the fixed pipeline). Rollback is a plain revert of the one commit if a further strict-mode
violation surfaces; the prior (broken) schema is preserved in git history for diffing.
