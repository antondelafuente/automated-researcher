---
name: verify-claims
description: Independent cross-family adversarial checks across the experiment lifecycle (the facts→logic→data→evidence ladder), each read by a model family you're too invested to judge. verify_claim — the brief's FACTS ("X is the baseline", "no checkpoint survives", a lineage claim); audit_experiment --design — the design's DATA-TRUSTABILITY (comparability, confounds that corrupt the number, variable-pinning, anchor; claim-rigor only if the design asserts a verdict) pre-launch; audit_experiment --data — the actual DATA's sanity vs intent (truncation, leakage, confounds, mislabeling) mid-run; audit_experiment (close) — the result's EVIDENCE (reproducibility, overclaim, postdictions) at close. Use when verifying claims, auditing a design before launch, sanity-checking generated/training/eval data, or auditing a finished experiment — anything where a confidently-wrong number would move money or conclusions. (The SWE-review modes --scaffold/--code that this engine used to carry now live in agentic-engineering's verify-claims, sourced by ship-change.)
---

# verify-claims — don't check your own claims

An agent cannot reliably catch its own wrong claims: whoever wrote a claim believes it, and
whoever received it was told it's true. This skill routes claims to a FRESH adversarial verifier that sees ONLY the primary records —
a different model family when your main agent isn't Codex (the default verifier). If your main
agent IS Codex, set VERIFIER_CMD to a different-family CLI for family independence; a fresh
zero-context instance still gives you context independence either way.

## When to invoke

- Before spending money or drawing conclusions that depend on factual claims about artifacts:
  identity of a baseline, location of original results, existence/provenance of a checkpoint,
  lineage of a derived model.
- On design documents (`DESIGN.md`) and their amendments.
- On your own draft writeups: do the methods-section claims survive contact with the records?
  (Every UNKNOWN = a detail your readers won't be able to verify either.)

## How

1. Write the claims as a numbered list in a file — one atomic, record-checkable claim per line.
   Don't editorialize; state each claim exactly as strongly as it's being relied upon.
2. Collect the primary records into one directory (copies/symlinks fine). The verifier sees
   ONLY this directory — if the claim needs evidence that isn't there, that's a finding.
3. Run: `scripts/verify_claim.sh <claims-file> <evidence-dir>`
4. Read the verdict file it writes:
   - **DISPUTE** → stop; resolve before proceeding (the verifier cites the contradicting line).
   - **UNKNOWN** → the records are too thin to support the claim; treat as a record gap.
   - **CONFIRM** → proceed; the citation is your receipt.

## Requirements / configuration

- Default verifier: OpenAI Codex CLI (`codex` on PATH, authed). Runs `--sandbox read-only`
  (mechanically cannot write; needs unprivileged userns for bubblewrap — see script header).
- Any other CLI model runner: set `VERIFIER_CMD` (receives the prompt on stdin, cwd = evidence
  dir, writes its final answer to the out-file).
- Calibration provenance: see `references/CALIBRATION.md` — replayed three real research-ops
  incidents as planted errors; 3/3 caught with correct citations, 0 false disputes on 7 controls.


## Audit modes — the cross-family ladder (`audit_experiment.sh`)

`verify_claim.sh` checks a claim list (the FACTS, pre-launch). Its sibling `audit_experiment.sh`
audits the experiment ITSELF at three points. Together they form the **facts → logic → data →
evidence** ladder — each rung read by a foreign model family you're too invested to judge:

- **`verify_claim.sh` — the brief's FACTS** (pre-launch; above).
- **`audit_experiment.sh --design <exp> [design-file]`** → `DESIGN_AUDIT.md` — the design's
  **DATA-TRUSTABILITY**, PRE-LAUNCH: will it produce reliable, comparable data for its stated purpose?
  comparability / co-measurement, confounds that corrupt the number, variable-pinning, anchor reproduction,
  honest component / parse% reporting, right/cheapest-data — plus a qualitative evidence-quality read.
  Claim-rigor (decision rules, claim-scope, power) fires **only if the design asserts a verdict** — a
  measurement design states a purpose, not a claim. (Audit once → triage as a peer → surface survivors to the
  human; on a re-run it's a peer debate, not a fresh scan.)
- **`audit_experiment.sh --data <exp> <manifest>`** → `DATA_AUDIT.md` — the actual **DATA's sanity**
  vs the design intent, MID-RUN before train/eval. The SEMANTIC layer: a foreign model reads a
  STRATIFIED high-risk sample and asks "would this data make the experiment invalid or misleading?"
  Pairs with the deterministic full-pool layer (`scripts/audit_data.py`: counts / truncation /
  finish_reason / schema / dupes / balance, and it emits the stratified sample this mode reads).
  Run BOTH layers on all three data surfaces — training data, eval inputs, and the model-generated
  eval rollouts. (Motivated by a generated-replay
  truncation bug — 1160/6457 rows truncated mid-CoT — that a 2-sample self-smoke missed.)
- **`audit_experiment.sh <exp>`** → `AUDIT.md` — the finished result's **EVIDENCE**, AT CLOSE:
  reproducibility, claim-vs-evidence, confounds/validity, data sanity, conclusions-vs-postdictions,
  records self-sufficiency, honest bounds.

Output (all modes): severity-rated FINDINGs with record citations + the dimensions where nothing
material was found. "No material finding" is allowed and common — it does NOT cry wolf (same
calibration discipline as the claim checker; the close mode validated 2026-06-12 catching a repro gap
+ in-sample steering + overclaim from a cold read, zero false findings).

Verifier output is atomic: `audit_experiment.sh` writes the model response to a temp file and moves it to the
final findings path only after the verifier exits successfully. While the verifier is still running, an
absent or empty final findings file is not evidence of a hang; inspect the process/log state instead of killing
or retrying solely because the findings file has not appeared.

**Cross-family selection (required `AAR_SUBSTRATE`).** Set `AAR_SUBSTRATE` to the family that RAN the work
(`claude` or `codex`) — it is REQUIRED and the script fails closed if unset/unknown, so a wrong default can
never make the audit same-family (matching `log-experiment`). The auditor is ALWAYS the opposite family and
each family has a correct built-in default verifier (it runs the auditor in the experiment dir and captures
its answer to `"$OUT_TMP"`), so you normally set nothing else: a Claude runner audits with Codex, a Codex
runner audits with Claude (`( cd <exp> && claude -p ) > "$OUT_TMP"`). `AUDIT_VERIFIER_CMD` is an OPTIONAL
override honored only when it is a DIFFERENT family than the runner, and it MUST run in the experiment dir
and write its final answer to `"$OUT_TMP"`; a same-family value — e.g. an instance `BASH_ENV` that re-injects
`AUDIT_VERIFIER_CMD` into every non-interactive shell (#262) — is ignored with a warning and the
opposite-family default is used.

**Wired into the experiment lifecycle:** `--design` at the design stage (the `design-experiment`
skill), `--data` + close at execution (the `run-experiment` skill) — each via the experiment
CHECKLIST. Respond to every finding (fix, or a one-line `RESPONSE:` accepting/deferring with a
reason); HIGH findings get fixed or explicitly justified.
