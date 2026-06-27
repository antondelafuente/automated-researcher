# Proposal: add the feedback-loop plugin (#125)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

The reusable feedback loop still lives in Anton's home skills. A fresh user of `automated-researcher`
can install GPU execution, experiment lifecycle, verification, and the engineering workflow, but it cannot
install the two skills that keep the scaffold improving:

- `file-feedback`, used by an AAR as a product user to file operational friction while it is still fresh;
- `triage-feedback`, used by a maintainer AAR to route open feedback into product fixes or instance-only
  follow-ups.

The live home skills are useful, but they are not product-shaped. They hardcode this deployment's tracker,
paths, archives, peer-coordination habits, and wrappers: `antondelafuente/automated-researcher`,
`/home/anton/orchestrator/experiment_gotchas.md`, `AAR_BACKLOG.md`, closed-entry archive filenames,
`message-aar`, `CLAIMED_BY`, local changelog and pipeline paths, and `gh-as-engineer`. Copying that text into
the product would make an outside install appear to work only because it inherited Anton's topology.

At the same time, leaving these skills outside the product keeps the product feedback loop invisible to
zero-context agents. #111 established the boundary: reusable product feedback belongs in product source;
deployment-only file bookkeeping belongs in the consuming instance.

## Approach

Add a new plugin, `feedback-loop`, with two product skills and one initializer.

### Plugin shape

- `plugins/feedback-loop/.claude-plugin/plugin.json`
- `plugins/feedback-loop/skills/file-feedback/SKILL.md`
- `plugins/feedback-loop/skills/triage-feedback/SKILL.md`
- `plugins/feedback-loop/skills/file-feedback/scripts/feedback_loop_init.sh`
- `plugins/feedback-loop/skills/*/references/DISPOSITIONS.md`

The plugin uses the same Agent Skills layout as the existing modules. README and marketplace docs list it as
optional but recommended: it is how users report product friction and how maintainers process that friction.
Codex installs symlink the two skill dirs independently.

### Local config

`feedback_loop_init.sh` writes `~/.config/feedback-loop/env` with mode `0600`, following `gpu_job_init.sh`'s
local-config convention: no secrets are committed, non-interactive env preseed works, and interactive terminals
are prompted.

The config keys are:

- `FEEDBACK_PRODUCT_REPO`: required `OWNER/REPO` for product issues.
- `FEEDBACK_INSTANCE_GOTCHAS_FILE`: optional local gotcha destination for deployment-only incidents.
- `FEEDBACK_INSTANCE_BACKLOG_FILE`: optional local backlog destination for deployment-only ideas.
- `FEEDBACK_INSTANCE_GOTCHAS_ARCHIVE`: optional closed gotcha archive.
- `FEEDBACK_INSTANCE_BACKLOG_ARCHIVE`: optional closed backlog archive.
- `FEEDBACK_PEER_COORDINATION`: optional free-text pointer to the consuming instance's coordination channel.
- `FEEDBACK_INSTANCE_CHANGELOG`: optional local changelog pointer.
- `FEEDBACK_INSTANCE_PIPELINES_DIR`: optional local pipelines/helper pointer.
- `FEEDBACK_ISSUE_COMMAND`: optional issue creation/comment command override.

The initializer may suggest `antondelafuente/automated-researcher` only when it can identify the plugin source
checkout as this upstream repository. It must not derive the product repo from the caller's current directory,
and it must not silently default outside installs to Anton's tracker.

### `file-feedback`

The product skill keeps the routing judgment from the live skill:

1. Decide whether the feedback would affect an external adopter of the product.
2. Product/user-facing feedback goes to `FEEDBACK_PRODUCT_REPO` as a GitHub Issue with a type label and exactly
   one disposition label when the answer is clear.
3. Deployment-only feedback goes to the configured instance gotcha/backlog files when those are configured.
4. A small mechanical fix can be applied immediately at the canonical home, but product fixes still go through
   `ship-change`.

The productized skill removes Anton-specific commands. When `aar-engineering` is installed and the current host
has an engineer identity, it prefers:

`wf.sh issue <family> create|comment ...`

When that path is missing, it either uses `FEEDBACK_ISSUE_COMMAND` or drafts the exact issue/comment body for the
researcher to submit. It never tells an outside user to call `gh-as-engineer`, never assumes Anton's owner token,
and never writes to `/home/anton/...` unless the instance config explicitly points there.

For instance-only file targets, the skill owns only the generic shape: symptom -> cause -> fix/cost for gotchas,
and what/why/take/next-step for backlog ideas. The exact archive vocabulary and closed-file maintenance remain
consuming-instance procedure.

### `triage-feedback`

The product skill is the maintainer side of the same loop. It processes:

- open product Issues in `FEEDBACK_PRODUCT_REPO`;
- optional instance gotcha/backlog files when configured.

Its reusable core is product issue and PR triage: maintain disposition labels, classify product feedback as
ready/needs-design/needs-shaping/blocked/parked/other, group duplicates, and route product-scaffold fixes through
`ship-change`.

The skill must not run automatically; it is an explicit maintainer pass. It can mention an instance's configured
coordination channel for live ownership checks, but it cannot require `message-aar` or a `CLAIMED_BY` convention.

Checklist promotion is split by genericity:

- recurring generic validity gates become product `experiment-lifecycle` checklist changes through
  `ship-change`;
- deployment-specific gates stay in the consuming instance's configured checklist/guidance.

### Shared disposition reference

Both skills ship `references/DISPOSITIONS.md`, copied from the marked canonical block in repo-root
`AGENTS.md`. The existing `.aar-ci` drift check from #121 already checks every packaged
`plugins/*/skills/*/references/DISPOSITIONS.md`, so adding these references enrolls `feedback-loop` in the same
single-source contract rather than hand-maintaining a second vocabulary.

### Experiment-lifecycle references

Update the lifecycle skills/templates so feedback remains optional:

- replace hardcoded `file-feedback` requirements with neutral wording that says to use the installed feedback
  loop or the consuming instance's feedback process;
- replace literal `experiment_gotchas.md`/`AAR_BACKLOG` assumptions with configured instance feedback surfaces;
- keep the design/run retro requirement, but do not require `feedback-loop` to be installed for
  `experiment-lifecycle` to make sense.

## Alternatives considered

- **Copy the home skills nearly verbatim.** Rejected: that would preserve the hidden coupling to Anton's home
  checkout and make outside installs fail in confusing ways.
- **Make feedback-loop the canonical home for disposition definitions.** Rejected by #111/#121: dispositions
  govern the whole product issue lifecycle and are enforced by `aar-engineering`; repo-root `AGENTS.md` remains
  the editorial source, with packaged references for plugin installs.
- **Only document "file an Issue" in README.** Rejected: the live workflow has real routing judgment, duplicate
  handling, disposition assignment, and fix-now discipline. That belongs in a point-of-need skill.
- **Require `aar-engineering` for issue filing.** Rejected: the integration is valuable when configured, but a
  product user should still get a safe draft/fallback when engineer Apps are not installed.
- **Move all instance archive procedure into product.** Rejected: local gotcha/archive filenames and emoji
  markers are deployment policy. The product should provide routing and shape, not freeze Anton's file layout.

## Blast radius

- Adds one product plugin and two product skills.
- Updates root marketplace and README install/docs.
- Updates `experiment-lifecycle` prose/templates only where they currently assume the home-only feedback skills
  or Anton's feedback filenames.
- Adds packaged disposition references under the new skills; existing CI drift checks cover them.
- Does not change `ship-change`, GitHub branch protection, GPU execution behavior, or research experiment method.
- Does not edit Anton's instance wrappers in this PR; the controller symlink/wrapper flip remains routed
  instance work after merge.

## Rollout + rollback

Roll out through the normal `ship-change` lifecycle: draft PR, scaffold review, implementation, code review,
classification, checks, fake-HOME smoke, final review, protected merge. The new plugin is opt-in, so existing
installs keep working if they do not install it.

After merge, this deployment can flip the local Claude/Codex wrapper skills to the product source and then keep
instance-only file/archive details in `/home/anton` guidance.

Rollback is a normal revert of the merge commit. Because the plugin is additive and the lifecycle text degrades
to neutral instance-feedback wording, rollback risk is low.
