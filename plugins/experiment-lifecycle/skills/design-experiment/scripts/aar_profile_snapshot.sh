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
# [recipes.visualization_*], which `update-site` resolves LIVE by design (see the role-split section
# of ../references/SCHEMA.md). `update-dashboard` also resolves [recipes.viewer] itself, live, for its
# own post-close purposes (#484) — a second, narrower live reader of this snapshot's own key.
# Identity/protection/other-recipe fields are out of THIS slice (#469's
# re-scope); a future pass may extend the snapshot to the full #153 field set — this block is additive, so
# that would not conflict with what's written here.
#
# Discovery order (identical to every other aar-profile reader in this product):
#   1. $AAR_PROFILE                                             (explicit override; test seam)
#   2. ${XDG_CONFIG_HOME:-~/.config}/experiment-lifecycle/aar-profile.{toml,json}   (.toml wins)
# Fails CLOSED (a one-line `BLOCK: ...` on stderr, non-zero exit) on: no discoverable profile, an unknown
# schema_version MAJOR, a malformed [github] table, or (check only) a missing/stale/unparseable snapshot
# block — this is what makes a profile-less or unknown-schema instance BLOCK at snapshot time, never
# silently fall back to manifest-only. The supported schema_version integer is never hardcoded here: it is
# read from the `SCHEMA_VERSION` HTML-comment marker on line 1 of the co-located `../references/SCHEMA.md`
# (resolved relative to this script's own location) — a missing/unparsable marker is itself a fail-closed
# BLOCK, since a reader that can't confirm what version it understands must refuse to guess.
#
# snapshot <START.md>: resolve the live profile, then WRITE/REPLACE the fenced-TOML block in START.md
#   (idempotent — re-running replaces the prior block in place, so a re-snapshot after a profile edit is
#   just running this again). Prints "OK: ..." on success.
# check <START.md>: read the block already in START.md, re-resolve the LIVE profile, verify the block's
#   profile_sha256 still matches the live file's bytes (staleness — a distinct message from tampering,
#   checked first), then re-render the block from the live profile via the SAME render_block() snapshot
#   uses and require the START.md block's text to match it exactly (trailing whitespace normalized) — this
#   is what catches tampering, including type coercion (schema_version = true), an omitted field, or any
#   future field, without re-implementing the comparison field by field. Prints "OK: ..." on success,
#   "BLOCK: <reason>" (+ non-zero exit) otherwise — this exact text is what the design-stage gate surfaces
#   to a human.
#
# Packaging: this file is shipped as a byte-identical copy under log-experiment/scripts/ (the design-stage
# gate's enforcement owner lives in that skill) — same per-skill-copy + .aar-ci/checks.sh drift-check
# precedent as the aar-profile SCHEMA.md and feedback-loop's init helper. Edit one, mirror the other. Since
# this script now reads its SCHEMA_VERSION marker from a co-located references/SCHEMA.md, log-experiment
# ships its own references/SCHEMA.md copy too (a third byte-identical copy alongside design-experiment's
# and run-experiment's) — each skill installs independently, so each needs its own local marker file.
set -euo pipefail

HEADING='## Instance profile (snapshot)'

usage() { echo "usage: aar_profile_snapshot.sh snapshot|check <START.md path>" >&2; exit 1; }
[ $# -eq 2 ] || usage
MODE="$1"; START_PATH="$2"
case "$MODE" in snapshot|check) : ;; *) usage ;; esac
[ -f "$START_PATH" ] || { echo "BLOCK: START.md not found: $START_PATH" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || { echo "BLOCK: python3 is required to resolve the instance profile" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA_PATH="$SCRIPT_DIR/../references/SCHEMA.md"

MODE="$MODE" START_PATH="$START_PATH" HEADING="$HEADING" SCHEMA_PATH="$SCHEMA_PATH" python3 - <<'PY'
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
    ):
        v = gh.get(field)
        if not isinstance(v, str) or not v or not rx.match(v) or not _no_traversal(v):
            block(f"instance profile at {path} has a missing/invalid required field [github].{field}")
        out[field] = v
    bp = gh.get("branch_prefix")
    if not isinstance(bp, str) or bp != "run/":
        block(
            f"instance profile at {path} has [github].branch_prefix={bp!r} but it must equal 'run/' exactly "
            "(matches #129's run/<exp> branch convention)"
        )
    out["branch_prefix"] = bp
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


_SCHEMA_VERSION_RE = re.compile(r"^<!-- SCHEMA_VERSION: ([0-9]+) -->\s*$")


def supported_schema_version():
    # Read from the skill's own co-located references/SCHEMA.md (resolved relative to this script's
    # location, not hardcoded) so a future schema bump only needs a doc edit, never a code edit here.
    schema_path = os.environ["SCHEMA_PATH"]
    try:
        with open(schema_path, "r", encoding="utf-8") as f:
            first_line = f.readline()
    except Exception as e:
        block(f"could not read the SCHEMA_VERSION marker at {schema_path}: {e}")
    m = _SCHEMA_VERSION_RE.match(first_line)
    if not m:
        block(f"SCHEMA_VERSION marker at {schema_path} is missing or unparsable (expected line 1 to read '<!-- SCHEMA_VERSION: N -->')")
    return int(m.group(1))


def resolve_live():
    path, looked = resolve_profile_path()
    if not path:
        block("no instance profile found (looked: " + ", ".join(looked) + ")")
    data, raw = load_profile(path)
    if not isinstance(data, dict):
        block(f"instance profile at {path} does not parse to a table at its root")
    supported = supported_schema_version()
    sv = data.get("schema_version")
    if sv is None:
        block(f"instance profile at {path} is missing required field 'schema_version'")
    if not isinstance(sv, int) or isinstance(sv, bool) or sv != supported:
        block(
            f"instance profile at {path} declares schema_version={sv!r}; this product understands only {supported} "
            "(refuse-unknown-MAJOR)"
        )
    gh = require_github(data, path)
    viewer = read_viewer(data, path)
    digest = hashlib.sha256(raw).hexdigest()
    return {"path": path, "sha256": digest, "schema_version": sv, "github": gh, "viewer": viewer}


# json.dumps only escapes the C0 control range (U+0000-U+001F) per the JSON spec; it leaves DEL (U+007F)
# and the C1 range (U+0080-U+009F) as literal bytes when ensure_ascii=False. TOML basic strings forbid
# literal control characters outright, so a profile path containing one of these (automated-researcher#474)
# made tomllib reject the emitted block even though snapshot itself reported success. \uXXXX-escape them
# post-hoc, the same way JSON already escapes C0.
_EXTRA_CONTROL_RE = re.compile("[\x7f\x80-\x9f]")


def _escape_extra_controls(s):
    return _EXTRA_CONTROL_RE.sub(lambda m: f"\\u{ord(m.group()):04x}", s)


def _toml_str(value):
    # json.dumps's quoting (\" \\ \n \t \r \b \f \uXXXX) is a valid TOML basic string for every value we
    # emit here — needed because the resolved profile PATH is not charset-restricted like the [github] /
    # viewer fields are (those are regex-validated in require_github/read_viewer above), so a path
    # containing a literal '"' or '\' would otherwise break the emitted TOML. ensure_ascii=False keeps
    # non-BMP characters (e.g. emoji) as raw UTF-8 instead of \uD8xx surrogate-pair escapes — TOML \u
    # escapes must be Unicode scalar values, and tomllib rejects a surrogate half on parse. DEL/C1 control
    # characters still need the extra escaping pass above since json.dumps doesn't cover them.
    return _escape_extra_controls(json.dumps(value, ensure_ascii=False))


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
if not isinstance(snap_hash, str) or not _SAFE_HEXDIGEST.match(snap_hash):
    block(f"instance-profile snapshot block in {start_path} is missing/has an invalid 'profile_sha256'")

live = resolve_live()
if live["sha256"] != snap_hash:
    block(
        f"instance-profile snapshot in {start_path} is stale: snapshot profile_sha256={snap_hash} but the "
        f"live profile at {live['path']} hashes to {live['sha256']} — re-run 'aar_profile_snapshot.sh snapshot'"
    )

# The hash check above only catches the LIVE profile changing since the snapshot was taken. It says
# nothing about the BLOCK ITSELF having been hand-edited while profile_sha256 was left intact — so
# re-render the block from the live profile with the SAME render_block() snapshot uses (deterministic)
# and require the START.md block's text to match it exactly. This subsumes tampering with any field
# (including type coercion a bare `!=` comparison would miss, e.g. True == 1) in one check instead of
# enumerating fields by hand, and it also catches a field this script doesn't know to check yet.
expected_block = render_block(live)
actual_block = m.group(0)


def _normalize(text):
    return "\n".join(line.rstrip() for line in text.splitlines())


if _normalize(actual_block) != _normalize(expected_block):
    exp_lines = [line.rstrip() for line in expected_block.splitlines()]
    act_lines = [line.rstrip() for line in actual_block.splitlines()]
    first_diff = next(
        i
        for i in range(max(len(exp_lines), len(act_lines)))
        if (act_lines[i] if i < len(act_lines) else None) != (exp_lines[i] if i < len(exp_lines) else None)
    )
    got = repr(act_lines[first_diff]) if first_diff < len(act_lines) else "<line missing>"
    want = repr(exp_lines[first_diff]) if first_diff < len(exp_lines) else "<line missing>"
    block(
        f"instance-profile snapshot in {start_path} does not match the live profile at line {first_diff + 1}: "
        f"got {got}, expected {want} — re-run 'aar_profile_snapshot.sh snapshot' (or revert the tampering)"
    )

viewer_note = "[recipes.viewer] present" if live["viewer"] is not None else "no [recipes.viewer] (manifest-only is legitimate)"
print(f"OK: instance-profile snapshot in {start_path} is present and matches the live profile ({viewer_note})")
sys.exit(0)
PY
