# automated-researcher

Modular skills for coding agents doing real research work — extracted from a working
autonomous-research lab (a MATS alignment-research program run by agents end-to-end),
released piece by piece as each module proves out in production.

**The thesis:** your agent doesn't need a new platform — it needs powers. Each module here
is a thin skill + battle-tested scripts that work in Claude Code, Codex CLI, and anything
else that reads the [Agent Skills](https://agentskills.io) format. The conversation stays
the interface.

Legacy note: this repo was previously named `aar-skills`. During migration, existing local installs may keep
that as a compatibility alias, but new installs should use `automated-researcher`.

## If you are a coding agent handed this link

Your human wants these skills available. Do this, in order:

1. **Clone:** `git clone <this-repo-url> ~/automated-researcher` (anywhere is fine; remember the path).
2. **Install the skills** (pick your harness):
   - *Claude Code* — use the HEADLESS CLI, not the interactive `/plugin` UI:
     ```
     claude plugin marketplace add ~/automated-researcher
     claude plugin install gpu-job@automated-researcher
     claude plugin install verify-claims@automated-researcher
     claude plugin install experiment-lifecycle@automated-researcher
     claude plugin install feedback-loop@automated-researcher
     ```
     Then tell your human to run `/reload-plugins` (or restart the session) to activate.
     (`experiment-lifecycle` also needs an **execution profile** — your instance's provisioning,
     frozen recipes, artifact store, ledger, and teardown/cost policy — before `run-experiment`
     can drive a real run; the installed skill alone is not enough. The build-the-product layer —
     `ship-change` (the `aar-engineering` plugin) — lives in the separate `agentic-engineering` repo;
     install it from there only if you're developing these skills, not just using them.)
   - *Codex CLI / other Agent-Skills harnesses* — symlink each source skill dir into the harness's
     skills directory (note a plugin can expose more than one skill — `experiment-lifecycle` has four):
     ```
     mkdir -p ~/.codex/skills
     ln -s ~/automated-researcher/plugins/gpu-job/skills/gpu-job                    ~/.codex/skills/gpu-job
     ln -s ~/automated-researcher/plugins/verify-claims/skills/verify-claims        ~/.codex/skills/verify-claims
     ln -s ~/automated-researcher/plugins/experiment-lifecycle/skills/design-experiment ~/.codex/skills/design-experiment
     ln -s ~/automated-researcher/plugins/experiment-lifecycle/skills/log-experiment    ~/.codex/skills/log-experiment
     ln -s ~/automated-researcher/plugins/experiment-lifecycle/skills/run-experiment    ~/.codex/skills/run-experiment
     ln -s ~/automated-researcher/plugins/experiment-lifecycle/skills/visualize-results ~/.codex/skills/visualize-results
     ln -s ~/automated-researcher/plugins/feedback-loop/skills/file-feedback        ~/.codex/skills/file-feedback
     ln -s ~/automated-researcher/plugins/feedback-loop/skills/triage-feedback      ~/.codex/skills/triage-feedback
     ```
     If you are developing the scaffold itself, install `ship-change` from the `agentic-engineering` repo
     (the engineering team's tooling — it owns the SWE pipeline that builds this product):
     ```
     ln -s ~/agentic-engineering/plugins/aar-engineering/skills/ship-change          ~/.codex/skills/ship-change
     ```
     `ship-change` in an enforced repo also needs engineer identity config and a cross-family reviewer command
     (for Codex authors, `AUDIT_VERIFIER_CMD` should point at a Claude-family CLI); see its `RUNBOOK.md` in that repo.
     Local harness wrappers are optional convenience files. Keep them thin: point at these source skills instead of
     copying the procedures.
3. **Configure gpu-job:** run `~/automated-researcher/plugins/gpu-job/skills/gpu-job/scripts/gpu_job_init.sh`.
   It writes a local config (`~/.config/gpu-job/env`, chmod 600) and uploads nothing.
   **You will need to ask your human for, verbatim:**
   - a **RunPod API key** — they create it at runpod.io → Settings → API Keys (needs a funded
     account; pods bill by the minute, a small test costs cents);
   - confirmation of an **SSH keypair** to use (offer to `ssh-keygen -t ed25519` if they don't
     have one — the PUBLIC key goes to pods, the private key never leaves this machine);
   - *(optional but recommended)* an **rclone remote** for artifact persistence (any backend:
     Cloudflare R2, S3, Backblaze…). If `rclone config` shows none, offer to set one up with them.
   `verify-claims` needs the OpenAI **Codex CLI** installed and authed (or set `VERIFIER_CMD`
   to another model CLI).
4. **Configure feedback-loop:** run `~/automated-researcher/plugins/feedback-loop/skills/file-feedback/scripts/feedback_loop_init.sh`.
   It writes `~/.config/feedback-loop/env` (chmod 600). Set `FEEDBACK_PRODUCT_REPO` to the product
   Issue tracker (`OWNER/REPO`); optionally set `FEEDBACK_INSTANCE_GUIDANCE` to a local doc that explains
   deployment-only feedback files, archives, changelog, and coordination.
5. **Verify cheaply before relying on it:** with your human's OK on ~$0.05 of spend, deploy the
   cheapest GPU (`GPU_TYPE='NVIDIA RTX 4000 Ada Generation' DISK_GB=20 POD_NAME=smoke python3
   scripts/deploy_pod.py`), run one `nvidia-smi` job via `run_remote.sh`, confirm the artifact
   lands in their store, **tear down** (`teardown.sh <pod-id>`), and confirm nothing is left
   RUNNING. Read the gpu-job SKILL.md rules first — especially the completion boundary and
   pod-id-scoped teardown.
6. Report back to your human: what is configured, what it costs, and the one rule they should
   know — pods bill until torn down, and the skills treat verified-teardown as non-optional.

## Modules

| module | what your agent learns | status |
|---|---|---|
| **gpu-job** | disposable cloud GPU pods: deploy, run detached, persist artifacts, verified teardown — never bill an idle GPU | shipped |
| **verify-claims** | adversarial fact / design / data / code review of load-bearing work, read by an independent model *family* — the cross-family validity gate | shipped |
| **experiment-lifecycle** | run a GPU experiment like a researcher: `design-experiment` (pre-register a design, clear it with the human through the validity gates) → `log-experiment` (land the design-stage pre-registration, and later the finished result, to the research repo as a gated PR) → `run-experiment` (a zero-context executor acquires, provisions, drives, collects, closes) → `visualize-results` (the local-first, researcher-driven editorial visualization loop, distinct from `run-experiment`'s own close-time viewer publish leg) | shipped |
| **feedback-loop** | report and triage scaffold friction: `file-feedback` captures product/user pain while fresh, `triage-feedback` maintains dispositions and routes fixes through the product workflow | shipped |
| *reproduce-paper* | point an agent at a paper, get a graded reproduction | planned |

(The SWE pipeline that *builds* this product — `ship-change` / the `aar-engineering` plugin — lives in the
separate `agentic-engineering` repo, not here.)

(Exact versions live in each `plugins/<module>/.claude-plugin/plugin.json` — the one canonical home — not duplicated here.)

**The product vs the pipeline that builds it.** The modules above are what an agent *uses* while doing
research. The SWE pipeline that *builds* this product — `ship-change` (the `aar-engineering` plugin) — lives in
the separate **`agentic-engineering`** repo: agents author changes, review each other's PRs across model
families (Claude's work reviewed by Codex and vice-versa), and merge when clean. The product is built the way it
ships: by agents, gated by agents. (Detail: `AGENTS.md`.)

## Install (human, interactive)

If *you* are setting these up by hand in the Claude Code UI (the agent path is the headless CLI in
"If you are a coding agent" above — follow one or the other, not both):
```
/plugin marketplace add <this-repo>
/plugin install gpu-job@automated-researcher
/plugin install verify-claims@automated-researcher
/plugin install experiment-lifecycle@automated-researcher
/plugin install feedback-loop@automated-researcher
```

**Codex CLI / other Agent-Skills harnesses:** clone, then symlink each source skill dir into your harness's
skills directory (e.g. `~/.codex/skills/`) — use the explicit per-skill `ln -s` lines in "If you are a
coding agent" above. Install `ship-change` (from the separate `agentic-engineering` repo) only if you are developing the scaffold itself. A plugin can expose
more than one skill, so symlink the `skills/<skill>` dirs, not `skills/<module>`. Scripts are referenced
relative to each skill.

## Updating

Claude Code: `/plugin update`. Plain clones: `git pull`. Versions are rolling (commit-SHA)
while pre-1.0; releases will be tagged when a cohort depends on stability.

## Feedback

Issues are the product's bug tracker — file footguns you hit and ideas for what would have
made your run smoother. Install `feedback-loop` for the point-of-need filing and triage skills. Recurrence
drives priority. Every module here exists because the lab's own agents filed exactly such reports.

## Provenance & philosophy

- Every script header cites the real incidents it encodes (the "gotchas"): these are not
  best-practice guesses, they're paid-for lessons.
- One canonical home per fact: code over prose; skills stay thin.
- Read-only where possible, verified before destructive, pod-id-scoped always.
