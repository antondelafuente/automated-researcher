# Proposal: implement strict ship-change engineer identity policy (#109)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

#107 settled the design: ambient `gh` is fine for inspection, but protected `ship-change` workflow mutations
must not silently use the owner credential when the intended engineer identity is missing. The current driver
still warns and falls back unless strictness variables are present, which fails exactly when a shell has not
sourced the engineer-token env.

This child implements that already-landed design.

## Approach

Update `wf.sh` at the existing identity seams:

1. Make named author/reviewer paths strict by default, with `WF_ALLOW_AMBIENT_IDENTITY=1` as the explicit
   permissive override. This covers author tokens, author git identity, reviewer tokens for interim reviews,
   classification comments, and final native approvals.
2. Block author omission for `open` and `classify` unless the permissive override is set.
3. Add visible diagnostics for fail-closed identity errors: name the missing seam and the escape hatch where
   applicable.
4. Add `wf.sh doctor <author> [repo-or-worktree]`, implemented through the same helper predicates the workflow
   uses, reporting ambient gh login, author/reviewer bot logins, git-author readiness, Codex reviewer command
   readiness, and whether the permissive override is enabled. Its exit contract is: exit 0 iff the full
   ship-change workflow identity path would proceed under the current configuration, including a deliberate
   `WF_ALLOW_AMBIENT_IDENTITY=1` permissive run.
5. When the permissive override is used for protected mutations, emit a terminal warning and leave a best-effort
   GitHub trail when a natural PR/Issue target exists.
6. Treat `WF_REQUIRE_ENGINEER_IDENTITY` and `WF_REQUIRE_NATIVE_REVIEW` as legacy/no-longer-needed under the new
   strict default, and update docs/help so no path still presents them as the opt-in strictness switches.
7. Add a unit-style smoke for the strict-gate/`doctor` behavior and wire it into `.aar-ci/checks.sh` when
   `wf.sh` changes, next to the existing `locate_audit_smoke.sh`.
8. Update `ship-change` SKILL.md/RUNBOOK/help text and bump `aar-engineering` plugin version.

## Alternatives considered

- **Only docs.** Rejected by #107: the invariant must live in the workflow action itself.
- **Hardcode `/home/anton/.env`.** Rejected by #107 as instance-specific. The product exposes seams; instances
  may source env in their own wrappers.
- **Keep `WF_REQUIRE_*` strictness flags as the gates.** Rejected by #107 because unsourcing the env removes
  the guard and the guarded token config together.

## Blast radius

`aar-engineering` only: `wf.sh`, the `ship-change` skill docs/RUNBOOK, and the plugin manifest version. The
behavior change affects protected `wf.sh` PR/Issue mutations, not ordinary bare `gh` commands outside the
workflow.

## Rollout + rollback

Merge through the normal ship-change code path. Rollback is reverting this PR. Operational escape hatch during
or after rollout: set `WF_ALLOW_AMBIENT_IDENTITY=1` for a deliberate permissive workflow run. After this lands,
any in-flight or future shell that has ambient `gh` but has not sourced the engineer-token seams will fail closed
on protected `wf.sh` mutations; recovery is to source the instance engineer env or set the explicit permissive
override for that run.
