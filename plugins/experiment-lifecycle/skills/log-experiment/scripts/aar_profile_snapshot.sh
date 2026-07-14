#!/usr/bin/env bash
# aar_profile_snapshot.sh snapshot|check <START.md path>
#
# The aar-profile discovery + START.md snapshot helper (#153 decision 4 / #195, revived #469): the ONE
# deterministic place that (a) resolves the live instance profile, once, at design time, and freezes the
# NON-SECRET [github] facts + the [recipes.viewer] pointer into a fenced-TOML "## Instance profile
# (snapshot)" block in START.md, and (b) later verifies that frozen block is still present, parseable, and
# NOT STALE relative to the live profile — the deterministic gate `log-experiment.sh`'s design-stage kind
# runs before merging the design PR. Built because #469's incident (three closed experiments silently
# missed the viewer-publish leg) traced to no script ever writing or checking this block: only a
# parenthetical mention in design-experiment/SKILL.md, so a designer had to remember an aside.
#
# Deliberately narrow: only [github] + [recipes.viewer] are read/snapshotted here — never
# [recipes.visualization_*], which `visualize-results` resolves LIVE by design (see the role-split section
# of ../references/SCHEMA.md). Identity/protection/other-recipe fields are out of THIS slice (#469's
# re-scope); a future pass may extend the snapshot to the full #153 field set — this block is additive, so
# that would not conflict with what's written here.
#
# Discovery order (identical to every other aar-profile reader in this product):
#   1. $AAR_PROFILE                                             (explicit override; test seam)
#   2. ${XDG_CONFIG_HOME:-~/.config}/experiment-lifecycle/aar-profile.{toml,json}   (.toml wins)
# Fails CLOSED (a one-line `BLOCK: ...` on stderr, non-zero exit) on: no discoverable profile, an unknown
# schema_version MAJOR, a malformed [github] table, or (check only) a missing/stale/unparseable snapshot
# block — this is what makes a profile-less or unknown-schema instance BLOCK at snapshot time, never
# silently fall back to manifest-only.
#
# snapshot <START.md>: resolve the live profile, then WRITE/REPLACE the fenced-TOML block in START.md
#   (idempotent — re-running replaces the prior block in place, so a re-snapshot after a profile edit is
#   just running this again). Prints "OK: ..." on success.
# check <START.md>: read the block already in START.md, re-resolve the LIVE profile, and verify the
#   block's profile_sha256 still matches the live file's bytes (staleness) and that [recipes.viewer]'s
#   presence agrees between the block and the live profile. Prints "OK: ..." on success, "BLOCK: <reason>"
#   (+ non-zero exit) otherwise — this exact text is what the design-stage gate surfaces to a human.
#
# Packaging: this file is shipped as a byte-identical copy under log-experiment/scripts/ (the design-stage
# gate's enforcement owner lives in that skill) — same per-skill-copy + .aar-ci/checks.sh drift-check
# precedent as the aar-profile SCHEMA.md and feedback-loop's init helper. Edit one, mirror the other.
set -euo pipefail

HEADING='## Instance profile (snapshot)'

usage() { echo "usage: aar_profile_snapshot.sh snapshot|check <START.md path>" >&2; exit 1; }
[ $# -eq 2 ] || usage
MODE="$1"; START_PATH="$2"
case "$MODE" in snapshot|check) : ;; *) usage ;; esac
[ -f "$START_PATH" ] || { echo "BLOCK: START.md not found: $START_PATH" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || { echo "BLOCK: python3 is required to resolve the instance profile" >&2; exit 1; }

MODE="$MODE" START_PATH="$START_PATH" HEADING="$HEADING" python3 - <<'PY'
import hashlib
import os
import re
import sys

try:
    import tomllib
except Exception:
    tomllib = None
import json

HEADING = os.environ["HEADING"]


def block(msg):
    print(f"BLOCK: {msg}", file=sys.stderr)
    sys.exit(1)


def resolve_profile_path():
    cands = []
    if os.environ.get("AAR_PROFILE"):
        cands.append(os.environ["AAR_PROFILE"])
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    d = os.path.join(base, "experiment-lifecycle")
    cands += [os.path.join(d, "aar-profile.toml"), os.path.join(d, "aar-profile.json")]
    path = next((c for c in cands if c and os.path.isfile(c)), None)
    return path, cands


_SEG = r"[A-Za-z0-9._-]+"
_SAFE_OWNER_REPO = re.compile(rf"^{_SEG}/{_SEG}$")
_SAFE_REL_PATH = re.compile(rf"^{_SEG}(?:/{_SEG})*$")
_SAFE_SHA = re.compile(r"^[0-9a-fA-F]{7,64}$")
_SAFE_HEXDIGEST = re.compile(r"^[0-9a-fA-F]{64}$")
_SAFE_URI = re.compile(rf"^(?:r2|s3|https)://{_SEG}(?:/{_SEG})*$")
_SAFE_BRANCH = re.compile(rf"^{_SEG}$")
_SAFE_BRANCH_PREFIX = re.compile(rf"^{_SEG}/$")   # e.g. "run/" — matches #129's run/<exp> convention


def _no_traversal(v):
    return ".." not in v.split("/")


def load_profile(path):
    try:
        raw = open(path, "rb").read()
    except Exception as e:
        block(f"instance profile at {path} could not be read: {e}")
    try:
        if path.endswith(".toml"):
            if tomllib is None:
                block("profile is TOML but this python3 has no tomllib (need Python >= 3.11)")
            data = tomllib.loads(raw.decode("utf-8"))
        else:
            data = json.loads(raw.decode("utf-8"))
    except SystemExit:
        raise
    except Exception as e:
        block(f"instance profile at {path} could not be parsed: {e}")
    return data, raw


def require_github(data, path):
    gh = data.get("github")
    if not isinstance(gh, dict):
        block(f"instance profile at {path} is missing required table [github]")
    out = {}
    for field, rx in (
        ("research_repo", _SAFE_OWNER_REPO),
        ("base_branch", _SAFE_BRANCH),
        ("branch_prefix", _SAFE_BRANCH_PREFIX),
    ):
        v = gh.get(field)
        if not isinstance(v, str) or not v or not rx.match(v) or not _no_traversal(v):
            block(f"instance profile at {path} has a missing/invalid required field [github].{field}")
        out[field] = v
    priv = gh.get("private")
    if not isinstance(priv, bool):
        block(f"instance profile at {path} has a missing/invalid required field [github].private (must be bool)")
    out["private"] = priv
    issue_repo = gh.get("issue_repo")
    if issue_repo is not None:
        if not isinstance(issue_repo, str) or not _SAFE_OWNER_REPO.match(issue_repo) or not _no_traversal(issue_repo):
            block(f"instance profile at {path} has an invalid [github].issue_repo")
        out["issue_repo"] = issue_repo
    return out


def read_viewer(data, path):
    recipes = data.get("recipes")
    if recipes is None:
        return None
    if not isinstance(recipes, dict):
        block(f"recipes must be a table in the instance profile at {path}")
    table = recipes.get("viewer")
    if table is None:
        return None
    if not isinstance(table, dict):
        block(f"recipes.viewer must be a table in the instance profile at {path}")
    kind = table.get("kind")
    if kind not in ("repo", "uri"):
        block(f"recipes.viewer.kind must be 'repo' or 'uri' (got: {kind!r})")
    out = {"kind": kind}
    if kind == "repo":
        for field, rx in (("repo", _SAFE_OWNER_REPO), ("path", _SAFE_REL_PATH), ("git_ref", _SAFE_SHA)):
            v = table.get(field)
            if not isinstance(v, str) or not v or not rx.match(v) or not _no_traversal(v):
                block(f"recipes.viewer is missing/has an invalid field '{field}' for kind=repo")
            out[field] = v
    else:
        v = table.get("uri")
        if not isinstance(v, str) or not _SAFE_URI.match(v) or not _no_traversal(v):
            block(
                "recipes.viewer.uri is missing, has an unsupported scheme (must be r2://, s3://, or "
                "https://), or contains characters outside the safe charset"
            )
        out["uri"] = v
        d = table.get("sha256")
        if not isinstance(d, str) or not _SAFE_HEXDIGEST.match(d):
            block("recipes.viewer is missing required field 'sha256' for kind=uri")
        out["sha256"] = d
    return out


def resolve_live():
    path, looked = resolve_profile_path()
    if not path:
        block("no instance profile found (looked: " + ", ".join(looked) + ")")
    data, raw = load_profile(path)
    if not isinstance(data, dict):
        block(f"instance profile at {path} does not parse to a table at its root")
    sv = data.get("schema_version")
    if sv is None:
        block(f"instance profile at {path} is missing required field 'schema_version'")
    if sv != 1:
        block(
            f"instance profile at {path} declares schema_version={sv!r}; this product understands only 1 "
            "(refuse-unknown-MAJOR)"
        )
    gh = require_github(data, path)
    viewer = read_viewer(data, path)
    digest = hashlib.sha256(raw).hexdigest()
    return {"path": path, "sha256": digest, "schema_version": sv, "github": gh, "viewer": viewer}


def _toml_str(value):
    # json.dumps's quoting (\" \\ \n \t \r \b \f \uXXXX) is a valid TOML basic string for every value we
    # emit here — needed because the resolved profile PATH is not charset-restricted like the [github] /
    # viewer fields are (those are regex-validated in require_github/read_viewer above), so a path
    # containing a literal '"' or '\' would otherwise break the emitted TOML.
    return json.dumps(value)


def render_block(live):
    lines = [HEADING, "", "```toml"]
    lines.append(f'profile_path   = {_toml_str(live["path"])}')
    lines.append(f'profile_sha256 = {_toml_str(live["sha256"])}')
    lines.append(f'schema_version = {live["schema_version"]}')
    lines.append("")
    lines.append("[github]")
    gh = live["github"]
    lines.append(f'research_repo  = {_toml_str(gh["research_repo"])}')
    lines.append(f'base_branch    = {_toml_str(gh["base_branch"])}')
    lines.append(f'branch_prefix  = {_toml_str(gh["branch_prefix"])}')
    if "issue_repo" in gh:
        lines.append(f'issue_repo     = {_toml_str(gh["issue_repo"])}')
    lines.append(f'private        = {"true" if gh["private"] else "false"}')
    if live["viewer"] is not None:
        lines.append("")
        lines.append("[recipes.viewer]")
        v = live["viewer"]
        lines.append(f'kind    = {_toml_str(v["kind"])}')
        if v["kind"] == "repo":
            lines.append(f'repo    = {_toml_str(v["repo"])}')
            lines.append(f'path    = {_toml_str(v["path"])}')
            lines.append(f'git_ref = {_toml_str(v["git_ref"])}')
        else:
            lines.append(f'uri     = {_toml_str(v["uri"])}')
            lines.append(f'sha256  = {_toml_str(v["sha256"])}')
    lines.append("```")
    return "\n".join(lines) + "\n"


# From the fixed heading through the first closing fence that follows the first opening ```toml fence —
# replaces exactly the one block owned by this heading; never touches anything else in START.md.
_BLOCK_RE = re.compile(re.escape(HEADING) + r".*?```toml\n.*?\n```\n?", re.DOTALL)


def find_block(text):
    return _BLOCK_RE.search(text)


def extract_toml(block_text):
    m = re.search(r"```toml\n(.*?)\n```", block_text, re.DOTALL)
    return m.group(1) if m else None


start_path = os.environ["START_PATH"]
mode = os.environ["MODE"]
text = open(start_path, "r", encoding="utf-8").read()

if mode == "snapshot":
    live = resolve_live()
    new_block = render_block(live)
    m = find_block(text)
    if m:
        text = text[: m.start()] + new_block + text[m.end() :]
    else:
        text = text.rstrip("\n") + "\n\n" + new_block
    open(start_path, "w", encoding="utf-8").write(text)
    viewer_note = "[recipes.viewer] present" if live["viewer"] is not None else "no [recipes.viewer] (manifest-only)"
    print(f"OK: wrote instance-profile snapshot to {start_path} ({viewer_note})")
    sys.exit(0)

# mode == check
m = find_block(text)
if not m:
    block(
        f"no instance-profile snapshot block found in {start_path} (expected heading '{HEADING}') — "
        "run 'aar_profile_snapshot.sh snapshot' first"
    )
toml_text = extract_toml(m.group(0))
if toml_text is None:
    block(f"instance-profile snapshot block in {start_path} has no fenced ```toml body")
if tomllib is None:
    block("this python3 has no tomllib (need Python >= 3.11) to parse the snapshot block")
try:
    snap = tomllib.loads(toml_text)
except SystemExit:
    raise
except Exception as e:
    block(f"instance-profile snapshot block in {start_path} is not valid TOML: {e}")

snap_hash = snap.get("profile_sha256")
snap_sv = snap.get("schema_version")
snap_gh = snap.get("github")
if not isinstance(snap_hash, str) or not _SAFE_HEXDIGEST.match(snap_hash):
    block(f"instance-profile snapshot block in {start_path} is missing/has an invalid 'profile_sha256'")
if snap_sv != 1:
    block(f"instance-profile snapshot block in {start_path} declares schema_version={snap_sv!r}; expected 1")
if not isinstance(snap_gh, dict) or not snap_gh.get("research_repo"):
    block(f"instance-profile snapshot block in {start_path} is missing required [github] fields")
snap_recipes = snap.get("recipes")
snap_viewer = snap_recipes.get("viewer") if isinstance(snap_recipes, dict) else None
if not isinstance(snap_viewer, dict):
    snap_viewer = None
snap_viewer_present = snap_viewer is not None

live = resolve_live()
if live["sha256"] != snap_hash:
    block(
        f"instance-profile snapshot in {start_path} is stale: snapshot profile_sha256={snap_hash} but the "
        f"live profile at {live['path']} hashes to {live['sha256']} — re-run 'aar_profile_snapshot.sh snapshot'"
    )
live_viewer_present = live["viewer"] is not None
if live_viewer_present != snap_viewer_present:
    block(
        f"instance-profile snapshot in {start_path} [recipes.viewer] presence ({snap_viewer_present}) "
        f"disagrees with the live profile ({live_viewer_present}) — re-run 'aar_profile_snapshot.sh snapshot'"
    )

# The hash check above only catches the LIVE profile changing since the snapshot was taken. It says
# nothing about the BLOCK ITSELF having been hand-edited while profile_sha256 was left intact — so
# re-derive every snapshotted value from the live profile (render_block(live) is deterministic) and
# compare field by field; the first mismatch names the tampered field.


def tampered(field, snap_val, live_val):
    if snap_val != live_val:
        block(
            f"instance-profile snapshot in {start_path} has a tampered field '{field}': snapshot={snap_val!r} "
            f"but the live profile has {live_val!r} — re-run 'aar_profile_snapshot.sh snapshot' (or revert "
            "the tampering)"
        )


tampered("schema_version", snap_sv, live["schema_version"])
for field in ("research_repo", "base_branch", "branch_prefix", "private", "issue_repo"):
    tampered(f"github.{field}", snap_gh.get(field), live["github"].get(field))
if live_viewer_present:
    lv = live["viewer"]
    tampered("recipes.viewer.kind", snap_viewer.get("kind"), lv["kind"])
    value_fields = ("repo", "path", "git_ref") if lv["kind"] == "repo" else ("uri", "sha256")
    for field in value_fields:
        tampered(f"recipes.viewer.{field}", snap_viewer.get(field), lv.get(field))

viewer_note = "[recipes.viewer] present" if live_viewer_present else "no [recipes.viewer] (manifest-only is legitimate)"
print(f"OK: instance-profile snapshot in {start_path} is present and matches the live profile ({viewer_note})")
sys.exit(0)
PY
