# Proposal: Teach ship-change Claude review latency norms (#96)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

Codex authors sometimes treat a quiet Claude-family `wf.sh` review as suspicious after roughly one minute. That has led to noisy status narration and duplicate kill/retry decisions while the reviewer is still in a normal latency window.

The missing product behavior is not a timeout mechanism; it is a clear norm at the moment an agent is likely to worry. With `AUDIT_VERIFIER_CMD='claude -p ... > "$OUT_TMP"'`, the output file often remains empty until Claude completes the full response, so an empty temp output file before five minutes is not evidence of a hang.

## Approach

Split the fix by canonical home:

- `plugins/verify-claims/skills/verify-claims/SKILL.md`: add the canonical model-independent rule for `audit_experiment.sh`: verifier output is written to a temp file and atomically moved into the final findings file only on success, so an empty final findings file while the verifier is running is not evidence of a hang.
- `plugins/verify-claims/skills/verify-claims/scripts/audit_experiment.sh`: print a short stderr note before invoking the verifier with the same mechanism, so direct research-audit users see it too.
- `plugins/aar-engineering/skills/ship-change/SKILL.md`: add the ship-change operator norm in generic terms: Claude-family reviews may be quiet for several minutes; do not kill/retry purely because the findings file is still absent/empty; use the runbook for local debug thresholds.
- `plugins/aar-engineering/skills/ship-change/RUNBOOK.md`: add the as-built thresholds from issue #96: 0-5 minutes is normal on this fleet, at 5 minutes inspect process/log state once without interrupting, and at 10 minutes treat the run as suspicious unless there is evidence of progress.
- `plugins/aar-engineering/skills/ship-change/scripts/wf.sh`: print a concise generic note immediately before invoking a review, so the expectation appears in terminal output when the author is waiting. Do not hardcode minute thresholds in the script.
- Plugin manifests: bump `aar-engineering` from `0.3.17` to `0.3.18` and `verify-claims` from `0.7.0` to `0.7.1` because both shipped plugins change.

Keep this as guidance. Do not add a hard timeout in `wf.sh` or `audit_experiment.sh`: timeout policy would need a separate design because review duration depends on prompt size, model state, and provider latency. This issue is specifically about preventing premature human-agent reactions during the normal quiet window.

## Alternatives considered

- Put all threshold values in `SKILL.md`/`wf.sh`. Rejected after design review because those are generic product surfaces; concrete minute thresholds are fleet observations and belong in the as-built RUNBOOK.
- Only update ship-change. Rejected after design review because the empty-output behavior lives in `verify-claims/audit_experiment.sh`, which is also used by research audits outside `ship-change`.
- Only update `SKILL.md`. Rejected because the user specifically called out operational thresholds/debug policy and the terminal moment where agents worry.
- Only update `wf.sh` output. Rejected because the norm would disappear from the durable skill docs and would not help agents reasoning about a blocked or inherited run.
- Add automatic timeout/retry behavior. Rejected for this ready issue because automatic retry risks duplicate reviews and stale outputs; the desired fix is instruction, not orchestration.

## Blast radius

This touches `aar-engineering` docs/output, `verify-claims` docs/output, and both plugin versions. It does not change review execution, PR posting, merge gates, branch protection, verifier selection, or timeout behavior.

The runtime blast radius is low: every ship-change review prints one extra expectation line before the potentially quiet reviewer call, and every direct `audit_experiment.sh` invocation prints one extra mechanism line before invoking the verifier. Both lines should be concise so they reduce chatter rather than add a new source of noise.

## Design review response

Claude design review found two HIGH issues in the first proposal:

- Threshold values are instance-tuned and should not be hardcoded into generic product surfaces. Accepted: `SKILL.md` and `wf.sh` get the generic quiet-review rule; concrete 0-5 / 5 / 10 minute thresholds live only in `ship-change/RUNBOOK.md`.
- The empty-output behavior belongs to `verify-claims/audit_experiment.sh`, not `ship-change`. Accepted: the canonical mechanism note and direct stderr cue are added in `verify-claims`, with `ship-change` referencing that behavior.

## Rollout + rollback

Roll out through the standard `ship-change` path for ready issue #96: design review, implementation, code review, classifier, `.aar-ci` checks including fake-HOME smoke for the plugin, final review, and merge.

Rollback is a normal revert PR restoring the previous docs/output/version if the added note proves noisy or misleading.
