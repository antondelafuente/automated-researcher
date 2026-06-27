# Proposal: recover the disposition-gate trusted findings list from the durable GitHub review, not `/tmp` (#143)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

The disposition-aware merge gate (#138/#139) has a deterministic structural backstop in `wf.sh finish`: over
the union of (a) the **reviewer-derived** HIGH finding ids and (b) the disposition state's own HIGH ids, every
HIGH must be validly dispositioned or the merge BLOCKS. The reviewer-derived half is the trust anchor — it is
what stops an author from silently **deleting or downgrading** a disposition to slip a real HIGH past the gate
(the state itself is author-maintained, so it cannot be its own trust source).

Today that trusted list is read from a **transient, local, author-writable file**:

```
PRIORREV="${TMPDIR:-/tmp}/wf_${PK}_$(wt_branch "$WT" | tr '/' '_').md"   # PK = code | scaffold
[ -f "$PRIORREV" ] || die "… run code-review/design-review first, then finish."
REVHIGH=$(fd_review_high_list "$PRIORREV")
```

`/tmp/wf_<mode>_<branch>.md` is the local output of the last `run_review`. It is:

- **transient** — gone on a reboot, a fresh worktree, a different machine, or a different agent picking up the
  PR; the gate then can't run (it fails closed, but it is also trivially defeated by *absence*), and
- **locally modifiable** — any process with write access to `/tmp` can edit it between the review and `finish`
  to drop a `FINDING … HIGH` line, weakening the deterministic backstop the gate exists to provide.

#139 already fails **closed** when the file is absent (good); this issue hardens the *trust* of the file's
**contents** when it is present. The authoritative, tamper-resistant copy of the same findings already exists:
the cross-family review `wf.sh` posts to the PR under the **reviewer-bot identity**, whose body embeds the raw
`FINDING … HIGH` block. An author cannot edit another identity's PR review/comment, so GitHub is the durable
trust anchor `/tmp` only approximated.

## Approach

Recover the trusted reviewer-derived HIGH list **from the durable GitHub review record**, authored by the
reviewer-bot identity — not from `/tmp`. Two small, composable pieces:

### 1. Mark trusted reviews on post (so recovery is unambiguous)

`run_review` already posts the review body (native review for `--code` / approving `--scaffold`; a PR comment
for an interim `--scaffold`). Embed a hidden, machine-readable marker in that body identifying it as a
gate-relevant reviewer review and naming its kind:

```
<!-- WF-REVIEW pk=code sha=<reviewed-sha> -->      # or pk=scaffold
```

The **fresh-eyes sweep** (`fresh_sweep`, #140) is *also* posted by the reviewer bot and *also* embeds
`FINDING`/`SUMMARY` lines, but it is **candidate-only** and must never be trusted by the gate. Give it a
**distinct** marker so recovery excludes it explicitly rather than by fragile heading text:

```
<!-- WF-FRESH-SWEEP -->
```

(Markers are HTML comments — invisible in rendered Markdown, stable across heading-text edits.)

### 2. Recover the HIGH list from GitHub at gate time

A new helper `fd_review_high_github <repo> <pr> <pk> <rtok> <reviewer_login>`:

1. Fetches the PR's **native reviews** (`/pulls/<pr>/reviews`) and **issue comments**
   (`/issues/<pr>/comments`) — the two surfaces `run_review` posts to.
2. Keeps only items whose **author login == the reviewer-bot login** AND whose body contains
   `<!-- WF-REVIEW pk=<pk> …`. The login filter is the tamper-resistance: a body the *author* posts (even one
   that copies the marker) is excluded because it is not authored by the reviewer identity. Items carrying
   `<!-- WF-FRESH-SWEEP -->` are excluded.
3. Picks the **most recent** surviving item by timestamp (the latest review of that mode — mirroring how the
   `/tmp` file was always the last `run_review` output).
4. Extracts the embedded `FINDING … HIGH` block and runs the existing `fd_review_high_list` over it (the
   raw lines survive verbatim inside the body's code fence, so the parser is unchanged).

The **reviewer-bot login** is `WF_ENGINEER_LABEL_<opposite-family>` (e.g. `codex-engineer[bot]` when the
author is `claude`) — an already-configured instance value (currently unused in `wf.sh`).

### 3. Use it in `finish`; fail closed if unrecoverable

In the structural-gate block, replace the `/tmp` read with `fd_review_high_github`. The union with the
state's own HIGH ids (`fd_high_list`), the duplicate-id check, and the call into `disposition_gate.sh` are all
**unchanged** — only the *source* of `REVHIGH` changes. Recovery failure (GitHub error, or no marked reviewer
review found) **BLOCKs**, exactly as the absent-`/tmp` case does today — the gate never falls back to the
untrusted local file.

**No reviewer-login configured / unenforced installs.** When `WF_ENGINEER_LABEL_<opposite>` is unset (a
permissive `WF_ALLOW_AMBIENT_IDENTITY=1` install with no engineer Apps), there is no reviewer identity to
anchor trust on. The gate cannot establish the trusted list and **fails closed** with a clear message — the
same fail-closed posture #139 already takes when no list is present. (Enforced installs, the ones that gate
merges, always have the label.)

## Alternatives considered

- **Keep `/tmp`, add a checksum/signature.** Rejected — still local and author-writable; any signing key the
  author can reach the author can re-sign with. GitHub's per-identity write permission *is* the signature.
- **Store the trusted list as a PR-local canonical artifact (a marked comment) like the disposition state.**
  Rejected as the primary source: the disposition state is *author*-posted; a parallel author-posted "trusted
  list" has the same trust problem. The reviewer-bot-authored review already IS the tamper-resistant artifact —
  recover from it rather than mint a second one.
- **Match the review by heading text instead of a marker.** Rejected — headings are human-facing prose
  (`Code review (\`--code\`)`, `Final code review (merge gate)`, …) and the fresh-eyes sweep shares the same
  `FINDING`/`SUMMARY` shape; a hidden marker is the robust, edit-stable discriminator.
- **SHA-bind the recovered list to HEAD.** Deferred — the `/tmp` list was never SHA-bound either, and the
  merge gate already re-runs `run_review` on the final SHA as the authoritative model gate; the structural
  backstop only needs the reviewer-derived HIGH *ids*. The marker carries the SHA for forensics, but enforcing
  it is a separable follow-up, out of scope here.

## Blast radius

- **SWE pipeline only** (`plugins/aar-engineering/skills/ship-change/scripts/wf.sh`): `run_review` gains a
  marker line in the posted body; `fresh_sweep` gains its own marker; a new `fd_review_high_github` helper; the
  `finish` structural-gate block swaps its trusted-list source. No change to `disposition_gate.sh`, the
  disposition state schema, `fd_review_high_list`, or any research-side skill.
- **Behavioral:** the gate now requires a recoverable reviewer review **on GitHub** (it already required a
  local review output); a PR with disposition state but no recoverable reviewer review BLOCKs (fail-closed) —
  the correct posture, and the normal flow always posts one during `design-review`/`code-review`/`finish`.
- **Trust:** closes the `/tmp`-tamper / `/tmp`-absence hole the issue describes; the trusted anchor moves to a
  record the author cannot write.
- **Reversibility:** a self-contained revert of the `wf.sh` change restores the `/tmp` read; no migration, no
  persisted state, no cross-component contract change.

## Rollout + rollback

Single-phase `ship-change` run (code PR, gated on `--code`). Validated by the `.aar-ci` checks + the fake-HOME
behavior smoke, plus a targeted check that `fd_review_high_github` extracts the same HIGH id set from a posted
review body that `fd_review_high_list` extracts from the raw file. Rollback is a normal revert of the diff.
