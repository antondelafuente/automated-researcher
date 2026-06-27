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
- `plugins/feedback-loop/skills/triage-feedback/scripts/feedback_loop_init.sh`
- `plugins/feedback-loop/skills/*/references/DISPOSITIONS.md`

The plugin uses the same Agent Skills layout as the existing modules. README and marketplace docs list it as
optional but recommended: it is how users report product friction and how maintainers process that friction.
Codex installs symlink the two skill dirs independently.

`feedback_loop_init.sh` must be discoverable from either skill. The canonical implementation can live in one
place, but `triage-feedback` must ship an executable wrapper or copy so a maintainer-only install can configure
`FEEDBACK_PRODUCT_REPO` without also installing `file-feedback`.

### Local config

`feedback_loop_init.sh` writes `~/.config/feedback-loop/env` with mode `0600`, following `gpu_job_init.sh`'s
local-config convention: no secrets are committed, non-interactive env preseed works, and interactive terminals
are prompted.

The config keys are:

- `FEEDBACK_PRODUCT_REPO`: required `OWNER/REPO` for product issues.
- `FEEDBACK_INSTANCE_GOTCHAS_FILE`: optional local gotcha destination for deployment-only incidents.
- `FEEDBACK_INSTANCE_BACKLOG_FILE`: optional local backlog destination for deployment-only ideas.
- `FEEDBACK_INSTANCE_GOTCHAS_ARCHIVE`: optional closed gotcha archive, used by `triage-feedback` when configured.
- `FEEDBACK_INSTANCE_BACKLOG_ARCHIVE`: optional closed backlog archive, used by `triage-feedback` when configured.
- `FEEDBACK_PEER_COORDINATION`: optional free-text pointer to the consuming instance's coordination channel,
  surfaced before touching files or helpers that may be under live ownership.
- `FEEDBACK_INSTANCE_CHANGELOG`: optional local changelog pointer, surfaced as the release-note destination for
  instance-visible changes.
- `FEEDBACK_INSTANCE_PIPELINES_DIR`: optional local pipelines/helper pointer, used as context when triaging
  instance gotchas that can become code.
- `FEEDBACK_ISSUE_COMMAND`: optional issue creation/comment command override.

The initializer always requires `FEEDBACK_PRODUCT_REPO` through an environment preseed or an interactive prompt.
It does not auto-detect or auto-suggest `antondelafuente/automated-researcher`; that avoids a fork/upstream
ambiguity and removes the hidden "works on Anton's box" class entirely. A non-interactive run without
`FEEDBACK_PRODUCT_REPO` exits with a clear message and leaves no partial config.

The skills read `~/.config/feedback-loop/env` at point of need. If the config file or `FEEDBACK_PRODUCT_REPO` is
missing, product feedback is not silently sent anywhere: the skill drafts the exact Issue/search/comment text for
the researcher and tells them to run `feedback_loop_init.sh` to enable direct filing. Deployment-only feedback
requires the corresponding instance file keys; when absent, the skill drafts a local note instead of writing to
Anton paths.

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
and what/why/take/next-step for backlog ideas. When archive keys are configured, `triage-feedback` may perform
the generic close-by-move operation: remove the resolved entry from the configured live file and append a
one-line pointer to the configured archive. The product owns only that generic operation and the marker vocabulary;
the consuming instance owns which files exist, what local entries mean, and any richer archive policy.

### `triage-feedback`

The product skill is the maintainer side of the same loop. It processes:

- open product Issues in `FEEDBACK_PRODUCT_REPO`;
- optional instance gotcha/backlog files when configured.

Its reusable core is product issue and PR triage: maintain disposition labels, classify product feedback as
ready/needs-design/needs-shaping/blocked/parked/other, group duplicates, and route product-scaffold fixes through
`ship-change`.

The skill must not run automatically; it is an explicit maintainer pass. It can mention an instance's configured
coordination channel for live ownership checks, but it cannot require `message-aar` or a `CLAIMED_BY` convention.
When configured, it should use `FEEDBACK_PEER_COORDINATION`, `FEEDBACK_INSTANCE_PIPELINES_DIR`, and
`FEEDBACK_INSTANCE_CHANGELOG` as concrete pointers for coordination, code-home inspection, and release notes;
when unset, it should say the relevant instance key is missing instead of naming Anton paths.

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

Update the lifecycle skills/templates so feedback has a concrete product pointer while remaining optional:

- reference `feedback-loop`'s `file-feedback` skill by name at retro/checklist points;
- add explicit fallback wording: if `feedback-loop` is not installed or configured, use the consuming instance's
  feedback process and record the note where the instance tells you to;
- replace literal `experiment_gotchas.md`/`AAR_BACKLOG` assumptions with configured instance feedback surfaces;
- keep the design/run retro requirement, but do not require `feedback-loop` to be installed for the rest of
  `experiment-lifecycle` to make sense.

## Alternatives considered

- **Copy the home skills nearly verbatim.** Rejected: that would preserve the hidden coupling to Anton's home
  checkout and make outside installs fail in confusing ways.
- **Fold `file-feedback` / `triage-feedback` into `aar-engineering`.** Rejected: `triage-feedback` uses
  `ship-change` when it is maintaining the product, but `file-feedback` is also a user-side research skill for
  people who install `experiment-lifecycle` without the build-the-product SWE layer. Keeping a separate
  `feedback-loop` plugin preserves the install boundary: research users can report friction without installing
  the engineering workflow, while maintainers can optionally integrate with `aar-engineering`.
- **Make feedback-loop the canonical home for disposition definitions.** Rejected by #111/#121: dispositions
  govern the whole product issue lifecycle and are enforced by `aar-engineering`; repo-root `AGENTS.md` remains
  the editorial source, with packaged references for plugin installs.
- **Only document "file an Issue" in README.** Rejected: the live workflow has real routing judgment, duplicate
  handling, disposition assignment, and fix-now discipline. That belongs in a point-of-need skill.
- **Auto-default `FEEDBACK_PRODUCT_REPO` to this upstream repo when the checkout looks like upstream.** Rejected:
  upstream/fork detection is exactly the wrong place to be clever. An explicit prompt/env key is simpler,
  clearer, and cannot misroute an outside install's feedback to Anton's tracker.
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
- The product PR does not edit Anton's home directory, but same-day deployment is part of the release step:
  after merge, flip the local Claude/Codex wrapper skills for `file-feedback` and `triage-feedback` to point at
  the product plugin source, preserving any instance-only overlay guidance in `/home/anton` rather than leaving
  duplicate live skill bodies.

## Rollout + rollback

Roll out through the normal `ship-change` lifecycle: draft PR, scaffold review, implementation, code review,
classification, checks, fake-HOME smoke, final review, protected merge. The new plugin is opt-in, so existing
installs keep working if they do not install it.

After merge, this deployment must flip the local Claude/Codex wrapper skills to the product source in the same
work session and keep instance-only file/archive details in `/home/anton` guidance. The ordered deployment step is:

1. Run `feedback_loop_init.sh` non-interactively with Anton's real values so `~/.config/feedback-loop/env` exists
   before any wrapper points at the new product skill.
2. Flip the local Claude/Codex wrapper skills for `file-feedback` and `triage-feedback` to point at the product
   plugin source.
3. Reload or restart live sessions that need the changed skills.

If that instance flip cannot be completed immediately, open a tracked instance follow-up before marking this
shipped; do not leave two independently-editable live copies as the steady state.

Rollback is a normal revert of the merge commit. Because the plugin is additive and the lifecycle text degrades
to neutral instance-feedback wording, rollback risk is low.
