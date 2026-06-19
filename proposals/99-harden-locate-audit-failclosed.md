# Proposal: harden locate_audit — fail-closed on ls-tree error + smoke env hygiene (#99)

> Canonical design doc. Reviewed by `--scaffold` before build. Lands on main.

## Problem

Fast-follow on #82 (trusted-but-current verify-claims reviewer resolution). The #82 merge-gate `--code`
review approved at 0 HIGH but left two non-HIGH follow-ups in the new code:

1. **MED [security] — `git ls-tree` failure conflated with "no verify-claims at base."** In
   `audit_from_base_ref`, after a base ref is confirmed to exist, the in-tree reviewer is detected with
   `relp=$(git -C "$repo" ls-tree -r --name-only "$base" 2>/dev/null | grep -m1 … || true)`. If `ls-tree`
   itself *fails* (corrupt object DB, partial/blobless clone), the pipe yields nothing, `grep` finds nothing,
   and `relp` is empty — indistinguishable from a legitimate "this base has no verify-claims." The empty
   `relp` then falls through to the installed reviewer. That is the exact silent-staleness / fail-open class
   #82 set out to eliminate, one layer deeper: we already have a valid base ref, so an enumeration failure is
   an *error*, not a "nothing here."
2. **LOW — `locate_audit_smoke.sh` inherits `AUDIT_EXPERIMENT`.** `AUDIT_EXPERIMENT` is the top-priority
   manual override in `locate_audit`. The smoke never clears it, so if it happens to be set in the runner's
   environment, every `wf.sh locate-audit` call returns the override and the smoke silently exercises the
   override path instead of the resolver it exists to test — a green run that proved nothing.

## Approach

Two small, self-contained changes; no interface change.

1. **Fail closed on `ls-tree` error.** Capture `ls-tree` separately from the `grep`, keying on its exit
   status now that a base ref is known to exist:

   ```sh
   tree=$(git -C "$repo" ls-tree -r --name-only "$base" 2>/dev/null) || return 2   # base exists but enumeration failed -> fail closed
   relp=$(printf '%s\n' "$tree" | grep -m1 -E 'verify-claims.*/scripts/audit_experiment\.sh$' || true)
   [ -n "$relp" ] || return 0                                                       # genuinely no verify-claims at base -> fall through
   ```

   A nonzero `ls-tree` (after `rev-parse --verify` already confirmed the ref) returns rc 2 → `locate_audit`
   aborts rather than downgrading to a possibly-stale install. A clean enumeration with no match keeps the
   legitimate rc-0 fall-through.

   This single check also closes the related base-resolution concern (a present-but-corrupt `origin/main`),
   thanks to git's `rev-parse` semantics: `git rev-parse --verify -q <ref>` returns the ref's SHA *even when
   its object is missing/corrupt*, and only "fails" (empty) when the ref is genuinely *absent*. So the existing
   `rev-parse origin/main || rev-parse main` falls back to local `main` ONLY when `origin/main` is absent (the
   legitimate no-remote-tracking-ref case) — a present-but-corrupt `origin/main` yields its own dangling SHA
   and is *not* masked by a stale local `main`; the `ls-tree` step above then fails closed on the unusable
   base. No separate `show-ref`/object-presence probe is needed (an earlier draft added one, but `show-ref
   --verify` itself fails on a missing object, so it would have mis-classified corrupt-as-absent). The rc-2
   contract (and the abort message) is reworded to cover "the base ref couldn't be inspected, or verify-claims
   is present but extraction failed."

   A new smoke case (7) exercises these error modes for real (previously only *claimed* covered), each with an
   installed reviewer present and asserting fail-closed (non-zero exit, never the stale install): (7a) removes
   the base commit's *tree* object so `ls-tree` fails while the commit still resolves; (7b) removes the
   *commit* object so the ref is present but its object is gone; (7c) corrupts `origin/main`'s object while a
   *diverged, intact* local `main` exists, proving the canonical base isn't masked by local `main`.

2. **Clear `AUDIT_EXPERIMENT` in the smoke.** `unset AUDIT_EXPERIMENT` at the top of `locate_audit_smoke.sh`
   (alongside the existing `HOME`/`GIT_CONFIG_GLOBAL` isolation) so the smoke always tests the resolver, never
   an ambient override. A new smoke case asserts the override, when set, does NOT leak into the resolver test.

## Alternatives considered

- **Treat any `ls-tree` non-match as fall-through (status quo).** Rejected: that is the fail-open the MED
  flags — once a base ref exists, an enumeration error must fail closed, consistent with #82's whole point.
- **`env -u AUDIT_EXPERIMENT` per `wf.sh` call in the smoke.** Equivalent effect; a single `unset` at the top
  is less repetitive and matches the smoke's existing top-of-file environment isolation. Minor preference.

## Blast radius

- One function (`audit_from_base_ref`) and one test (`locate_audit_smoke.sh`) in the `aar-engineering`
  ship-change skill; `SKILL.md` resolution-order text is unchanged (the happy-path resolution order is
  identical; only error modes change from fail-open to fail-closed, and the rc-2 comment/abort wording in
  `wf.sh` is updated to match). `plugin.json` version bump.
- No change to the resolution interface or any caller. The only externally observable change is that a
  corrupt/partial repo now BLOCKS (fail-closed) instead of silently using an installed reviewer — the
  intended direction.
- This PR touches the reviewer-resolution code, so by #82's own rule its reviews resolve verify-claims from
  the repo's *base* (pre-this-PR) copy, not this branch — the safe path, and proven current by the smoke.

## Rollout + rollback

- Pure hardening; no state, no migration. Rollback = revert the commit. `AUDIT_EXPERIMENT` remains the manual
  escape hatch throughout.
