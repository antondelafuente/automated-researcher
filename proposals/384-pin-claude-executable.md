# Proposal: pin the Claude Code executable in implement-on-ready.yml (#384)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

After the #382/#381 fixes, `implement-on-ready` runs still die at SDK launch. `claude-code-action` auto-installs
Claude Code on the runner with no version pin, and as of 2026-07-11 that resolves to v2.1.206. The inner CLI
process exits 1 immediately — before any API call — surfacing only the action's opaque "SDK execution error"
(runs 29134553863, 29134534809). The exact same invocation (same `claude_args`, same `--json-schema` string,
same API key, model `claude-sonnet-5`) succeeds on this box, which runs Claude Code v2.1.207 (verified, exit
0). The failure signature matches a family of open upstream `claude-code-action` issues: #947 ("CLI crashes on
startup in CI, exit code 1, ajv schema validation"), #892, #804 — a known startup-crash class in the
auto-installed version, not something wrong with our prompt/schema/auth.

## Approach

Pin Claude Code to the known-good v2.1.207 instead of letting the action auto-install whatever is latest:

1. Add a step in the `implement` job, before the `claude-code-action` step, that installs Claude Code at a
   pinned version: `npm install -g @anthropic-ai/claude-code@2.1.207`. `ubuntu-latest` GitHub-hosted runners
   ship Node.js (and npm) preinstalled, so no `actions/setup-node` step is needed — confirmed via GitHub's
   runner image docs; if that ever stops being true, `actions/setup-node` pinned by full commit SHA is the
   fallback, added right before the install step.
2. Resolve the installed binary's path with `command -v claude` and pass it to `claude-code-action` via its
   documented `path_to_claude_code_executable` input. This input tells the action to use the given binary
   instead of auto-installing its own, which is the actual mechanism that skips the broken auto-install path.
3. Comment the new step with the rationale (the upstream issue numbers, and the local-vs-CI version diff that
   diagnosed this) and note that bumping the pinned version later is a normal PR edit (bump the npm version
   string, re-verify SDK launch survives, done — no special process).
4. Scope: `implement-on-ready.yml` only. `review-on-pr.yml` runs `codex-action`, which is unaffected by this
   Claude Code CLI bug. `checks.yml` doesn't invoke `claude-code-action` at all. Neither is touched.

## Alternatives considered

- **Pin via a `claude_code_version` action input instead of a separate install step.** `claude-code-action` has
  no such input as of the pinned action SHA in this workflow (v1.0.170) — `path_to_claude_code_executable` is
  the documented mechanism for supplying a specific binary, so a pre-install step + path handoff is the
  supported path, not a workaround.
- **Bump the pinned `claude-code-action` version instead, hoping a newer action release fixes the auto-install
  crash.** Rejected: the upstream issues (#947/#892/#804) are open and unresolved in the CLI itself, not the
  action wrapper — bumping the action would still auto-install a CLI version with no guarantee it isn't
  affected. Pinning the CLI version directly is the only lever that's actually verified to work (v2.1.207,
  confirmed exit 0 on this box).
- **Do nothing and retry on failure.** Rejected: the crash is deterministic on the affected CLI version, not
  transient — retries would just fail the same way.

## Blast radius

Touches exactly one file: `.github/workflows/implement-on-ready.yml` (adds one step, adds one action input).
No change to `review-on-pr.yml`, `checks.yml`, the implementor prompt, or any script. This is CI-pipeline-only
(the SWE pipeline itself, not the shipped research product) — it changes how the `implement` job's runner
prepares before invoking `claude-code-action`, not the job's authorization logic, outputs, or the
`enable-automerge` job.

## Rollout + rollback

No staged rollout needed — this only affects the next `ready`-triggered (or `workflow_dispatch`-triggered)
implement run, and the acceptance check (a `ready` re-flip surviving past SDK launch) is immediate and
observable in the Actions log. Rollback is a one-line revert of the added step + input, restoring auto-install
behavior. Bumping the pinned version forward, if a later Claude Code release is verified to work, is a normal
PR editing the `@2.1.207` version string.
