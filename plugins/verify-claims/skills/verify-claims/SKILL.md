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
  lineage of a derived model. **A claimed resume-from-checkpoint path is a distinct fact class:**
  verify the checkpoint's TYPE for the SPECIFIC resume API the plan will call (e.g. Tinker's
  resumable `weights` vs. inference-only `sampler_weights`), not just that a checkpoint with a
  matching base_model/rank exists via a generic metadata lookup — that lookup doesn't distinguish
  checkpoint flavors, and a wrong type surfaces only at launch, not at the claim-check (#348).
- On design documents (`DESIGN.md`) and their amendments.
- On your own draft writeups: do the methods-section claims survive contact with the records?
  (Every UNKNOWN = a detail your readers won't be able to verify either.)

## How

1. Write the claims as a numbered list in a file — one atomic, record-checkable claim per line.
   Don't editorialize; state each claim exactly as strongly as it's being relied upon.
2. Run it. **Inside an experiment dir, use `--exp` and let the packet be built by code** (below):
   `scripts/verify_claim.sh --exp <experiment-dir> <claims-file>`.
   Outside one, collect the primary records into one directory yourself (copies/symlinks fine) and
   run `scripts/verify_claim.sh <claims-file> <evidence-dir>` — the verifier sees ONLY that
   directory, so anything the claim needs and you didn't copy comes back UNKNOWN.
3. Read the verdict file it writes:
   - **DISPUTE** → stop; resolve before proceeding (the verifier cites the contradicting line).
   - **UNKNOWN** → the records are too thin to support the claim; treat as a record gap.
   - **CONFIRM** → proceed; the citation is your receipt.

### `--exp` — the evidence packet built by code (automated-researcher#817)

The hand-assembled packet was the mechanical waste in the design gate: the verifier sees only the
evidence dir, so **any path the designer forgot to copy came back UNKNOWN *by construction*** — a
packing mistake wearing a records-finding's clothes — and the only fix was reassemble + rerun
(~2-3 min and ~$1-2 a time; a transcript read found the retry in 3 of 3 recent designs, and no rerun
ever turned up a new contradiction). `--exp` removes the cause rather than the symptom:

- **The packet is assembled from the experiment dir.** `DESIGN.md` always, plus every path the claims
  file cites that actually resolves (searched under the experiment dir, its parent, the repo root,
  and the cwd — so a sibling experiment's record resolves too). A bare `RESULTS.md` counts as much as
  `registry/x/data/train.jsonl` or `artifacts/model.safetensors`: **inclusion is decided by
  resolution, not by how path-shaped the token looks.** Files over `VERIFY_CLAIM_MAX_BYTES` (2 MiB)
  go in as a head+tail excerpt; directories go in as a listing, and a listing cut at 500 entries says
  so in the facts, the manifest, and the listing file (unlisted is not the same as absent).
- **A `<path>@<sha>` citation pins a REVISION, and the packet carries that revision's bytes** — the
  blob is materialized from git as `<path>@<sha>` and hashed/line-counted from those bytes, so the
  verifier reads what the claim pinned rather than a working-tree file that may have been amended
  since. It works for a path that has since been moved or deleted, and when the two differ the facts
  say so and name the pinned copy as the one to judge against. This is what makes the light design
  path's parent-drift check (`design-experiment` Step 2b) checkable at all.
- **`MECHANICAL_FACTS.md` is computed and put in the packet before the model sees anything** —
  existence, byte size, sha256, line count, git-tracked status, and for a cited `<path>@<sha>`,
  whether the path existed at that commit, whether the commit is an ancestor of HEAD, and the pinned
  blob's own size/hash/lines. The verifier is told this file is a primary record and must not answer
  UNKNOWN on anything it settles. A cited path that resolves to nothing — in the working tree and at
  every commit it pins — is reported loudly, in the verdict and on stderr, as itself; a token that is
  neither resolvable nor unambiguously a path (backticked, `@sha`-pinned, or two-plus slashes) is
  treated as prose rather than a missing record. Use `check: exists <path>` when you need an
  unresolvable bare name to fail the gate outright.
- **`check:` directives settle a claim without a model at all** — opt-in, indented under the claim:
  `check: exists <path>` · `check: sha256 <path> <hex>` · `check: rows <path> <n>` ·
  `check: commit <path>@<sha>`. All directives pass → deterministic `CONFIRM`; any fails → `DISPUTE`
  (a cited path that doesn't resolve fails CLOSED, on purpose — a gate that fails open is not a gate).
  Those claims never reach the verifier, so the model's pass is spent on the **semantic** provenance
  claims, which is what it is actually better than a script at. A directive the *environment* can't
  evaluate (e.g. `commit` outside a git repo) settles nothing: that claim goes to the verifier with a note.
- **Write directives only for what a script can truly settle.** A claim whose sentence asserts more
  than its directives check (identity, lineage, "same construct as") is a semantic claim — leave the
  directives off and let the verifier read it, with the mechanical facts now in front of it.
- The verdict file records the packet manifest, the mechanically-resolved verdicts, the verifier's
  verdicts, and **exactly one** `SUMMARY:` line — the combined one over both halves, at the end. The
  verifier's own SUMMARY is folded into it and does not appear separately, so a consumer that greps
  the first `SUMMARY:` cannot read semantic-only counts and miss the mechanical DISPUTEs above them.
  `VERIFY_CLAIM_KEEP_EVIDENCE=1` keeps the generated packet dir for inspection. The two-argument form
  is unchanged for existing callers.

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
  instrument pins (unpinned judge/rubric/battery/eval definitions), cross-scale band hygiene (the scale unit is
  the serving SESSION, not the wave: any delta read across two sessions — a cited prior-wave value or the
  design's own second session alike — carrying no measured wobble band, or a delta smaller than its band with
  nothing re-served together to resolve it) — never the mere
  absence of arms served together, which is the standing default,
  confounds that corrupt the number, variable-pinning, anchor reproduction,
  honest component / parse% reporting, right/cheapest-data — plus a qualitative evidence-quality read.
  Claim-rigor (decision rules, claim-scope, power) fires **only if the design asserts a verdict** — a
  measurement design states a purpose, not a claim. **Schedule efficiency (#311, reframed #322):** enumerate
  the parallelizable steps and their max sensible fan-out — is the design at max fan-out for each, or did the
  researcher explicitly decline it? A resource limit that is itself a discretionary design choice (e.g. "only
  one pod") is NOT a valid reason to serialize. Does its cost reasoning distinguish per-compute billing
  (N parallel costs the same as N serial) from per-wallclock billing (a rented pod)? (Audit once → triage as a
  peer → REPORT the survivors to the human — a report at the end, not a gate mid-run, except for a
  load-bearing arbitration, automated-researcher#817; on a re-run it's a peer debate, not a fresh scan.)
- **`audit_experiment.sh --data <exp> <manifest>`** → `DATA_AUDIT.md` — the actual **DATA's sanity**
  vs the design intent, MID-RUN before train/eval. The SEMANTIC layer: a foreign model reads a
  STRATIFIED high-risk sample and asks "would this data make the experiment invalid or misleading?"
  Pairs with the deterministic full-pool layer (`scripts/audit_data.py`: counts / truncation /
  finish_reason / schema / dupes / balance, and it emits the stratified sample this mode reads).
  Run BOTH layers on all three data surfaces — training data, eval inputs, and the model-generated
  eval rollouts. (Motivated by a generated-replay
  truncation bug — 1160/6457 rows truncated mid-CoT — that a 2-sample self-smoke missed.)
  **Always pass `audit_data.py --label-field`** when the surface being audited has an added/edited
  subset within a much larger unchanged base (ablations, add-back waves, targeted edits) — without it,
  the default stratified sample can end up almost entirely base rows and miss the minority subset the
  gate is meant to check (it prints a runtime WARN when `--label-field` is omitted, but don't rely on
  catching that after the fact).
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
opposite-family default is used. `audit_experiment.sh` also unsets
`BASH_ENV` for its own subshells/eval/external processes as soon as it starts (#373, defense-in-depth): the
same `~/.env` re-injection can't clobber a caller's override a second time inside a child bash the script
spawns — this does not by itself fix #262's re-injection into the script's own top-level invocation, which
still needs the documented `BASH_ENV=` workaround.

**Built-in codex auditor quota fallback (#373).** If the built-in codex auditor's ChatGPT-subscription
transport fails with a usage-limit error (matched via `AUDIT_QUOTA_ERROR_PATTERN`, default `usage limit`),
`audit_experiment.sh` retries via an ephemeral, apikey-authenticated `CODEX_HOME` (`codex login --with-api-key`,
fed `OPENAI_API_KEY` over stdin so it never appears in the process argument list — `-c
preferred_auth_method=apikey` alone does not switch auth in codex 0.144, and `--api-key VALUE` is not a
supported flag).
This moves the audit onto API billing (~$2-5/audit) instead of the free ChatGPT transport, so it always
announces the switch loudly in stderr/the run log — never silently — and only fires for the built-in codex
default, never for an `AUDIT_VERIFIER_CMD` override (the caller owns that command's own retry policy). With
no `OPENAI_API_KEY` set, the run BLOCKs with a message naming the missing key rather than retrying blindly.

**Wired into the experiment lifecycle:** `--design` at the design stage (the `design-experiment`
skill), `--data` + close at execution (the `run-experiment` skill) — each via the experiment
CHECKLIST. Respond to every finding (fix, or a one-line `RESPONSE:` accepting/deferring with a
reason); HIGH findings get fixed or explicitly justified.
