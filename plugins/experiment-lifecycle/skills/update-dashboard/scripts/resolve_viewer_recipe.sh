#!/usr/bin/env bash
# resolve_viewer_recipe.sh
#
# Resolve the instance's typed [recipes.viewer] pointer LIVE from the aar-profile instance profile
# (schema v1, [recipes.<name>] — see plugins/experiment-lifecycle/skills/*/references/SCHEMA.md). Fails
# CLOSED with a clear BLOCK message on stderr and a non-zero exit — never guesses a repo, host, or
# worktree. On success, prints resolved fields as KEY=VALUE lines on stdout, each value restricted to a
# conservative safe charset (see the validators below) — READ these lines (e.g. one `grep '^KEY='` /
# `cut` at a time), never `eval` or `source` this output: a value's charset is restricted to prevent
# shell-metacharacter injection, but this script does not shell-quote for you.
#
# Unlike run-experiment's close-time publish leg, which reads ONLY the frozen START.md snapshot taken at
# design time (#153's role split), update-dashboard is invoked post-close, live, ad hoc, possibly long
# after close — so it resolves [recipes.viewer] LIVE itself, the same live-resolving role update-site
# already plays for [recipes.visualization_preview]/[recipes.visualization_publish] (#484). It never
# reads or requires [recipes.visualization_preview] or [recipes.visualization_publish].
#
# [recipes.viewer].git_ref (or, for kind=uri, .sha256) is the recipe REVISION this prints — the caller
# records it in its output so a rebuild under a newer viewer recipe than the one active at the
# experiment's original close is visible, not silent (compare against the experiment's own START.md
# snapshot `[recipes.viewer]` block, when present, to detect drift).
#
# Discovery order (identical to every other aar-profile reader in this product):
#   1. $AAR_PROFILE                                             (explicit override; test seam)
#   2. ${XDG_CONFIG_HOME:-~/.config}/experiment-lifecycle/aar-profile.{toml,json}   (.toml wins)
set -euo pipefail

for a in "$@"; do
  echo "BLOCK: unknown argument: $a (usage: resolve_viewer_recipe.sh)" >&2; exit 1
done

command -v python3 >/dev/null 2>&1 || { echo "BLOCK: python3 is required to resolve the instance profile" >&2; exit 1; }

python3 - <<'PY'
import os
import sys

try:
    import tomllib
except Exception:
    tomllib = None
import json

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

def load_profile(path):
    try:
        if path.endswith(".toml"):
            if tomllib is None:
                block("profile is TOML but this python3 has no tomllib (need Python >= 3.11)")
            with open(path, "rb") as f:
                return tomllib.load(f)
        with open(path) as f:
            return json.load(f)
    except SystemExit:
        raise
    except Exception as e:
        block(f"instance profile at {path} could not be parsed: {e}")

path, looked = resolve_profile_path()
if not path:
    block("no instance profile found (looked: " + ", ".join(looked) + ")")

data = load_profile(path)
if not isinstance(data, dict):
    block(f"instance profile at {path} does not parse to a table at its root")

sv = data.get("schema_version")
if sv is None:
    block(f"instance profile at {path} is missing required field 'schema_version'")
if sv != 1:
    block(f"instance profile at {path} declares schema_version={sv!r}; this product understands only 1 (refuse-unknown-MAJOR)")

import re
# Each restricted to a conservative charset that EXCLUDES every shell metacharacter (no eval/source
# safety net is assumed downstream — see the header note). Segment-level checks (below) additionally
# reject a bare ".." path-traversal segment, which the charset alone would not catch.
_SEG = r"[A-Za-z0-9._-]+"
_SAFE_OWNER_REPO = re.compile(rf"^{_SEG}/{_SEG}$")           # exactly one '/'; non-empty on both sides
_SAFE_REL_PATH = re.compile(rf"^{_SEG}(?:/{_SEG})*$")         # no leading '/', no empty segments
_SAFE_SHA = re.compile(r"^[0-9a-fA-F]{7,64}$")
_SAFE_HEXDIGEST = re.compile(r"^[0-9a-fA-F]{64}$")
_SAFE_URI = re.compile(rf"^(?:r2|s3|https)://{_SEG}(?:/{_SEG})*$")   # same safe charset, no query/fragment

def _no_traversal(v):
    return ".." not in v.split("/")

def resolve_recipe(name):
    recipes = data.get("recipes")
    if recipes is not None and not isinstance(recipes, dict):
        block(f"recipes must be a table in the instance profile at {path}")
    table = (recipes or {}).get(name)
    if table is None:
        block(f"recipes.{name} is not configured in the instance profile at {path}")
    if not isinstance(table, dict):
        block(f"recipes.{name} must be a table in the instance profile")
    kind = table.get("kind")
    if kind not in ("repo", "uri"):
        block(f"recipes.{name}.kind must be 'repo' or 'uri' (got: {kind!r})")
    out = {"KIND": kind}
    if kind == "repo":
        for field, rx in (("repo", _SAFE_OWNER_REPO), ("path", _SAFE_REL_PATH), ("git_ref", _SAFE_SHA)):
            v = table.get(field)
            if not isinstance(v, str) or not v:
                block(f"recipes.{name} is missing required field '{field}' for kind=repo")
            if not rx.match(v) or not _no_traversal(v):
                block(f"recipes.{name}.{field} has an invalid value")
            out[field.upper()] = v
    else:
        v = table.get("uri")
        if not isinstance(v, str) or not _SAFE_URI.match(v) or not _no_traversal(v):
            block(f"recipes.{name}.uri is missing, has an unsupported scheme (must be r2://, s3://, or https://), or contains characters outside the safe charset")
        out["URI"] = v
        d = table.get("sha256")
        if not isinstance(d, str) or not _SAFE_HEXDIGEST.match(d):
            block(f"recipes.{name} is missing required field 'sha256' for kind=uri")
        out["SHA256"] = d
    return out

viewer = resolve_recipe("viewer")

for k, v in viewer.items():
    print(f"VIEWER_{k}={v}")
PY
