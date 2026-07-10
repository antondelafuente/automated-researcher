#!/usr/bin/env bash
# resolve_visualization_recipe.sh [--publish]
#
# Resolve the instance's typed visualization recipe pointer(s) from the aar-profile instance profile
# (schema v1, [recipes.<name>] — see plugins/experiment-lifecycle/skills/*/references/SCHEMA.md).
# Fails CLOSED with a clear BLOCK message on stderr and a non-zero exit — never guesses a repo, host,
# port, or worktree. On success, prints resolved fields as shell-parseable KEY=VALUE lines on stdout.
#
# Default (preview) mode resolves ONLY [recipes.visualization_preview] — the local iteration recipe
# (preview claim commands, stable local worktree/URL, page-style pattern). It never reads
# [recipes.viewer] at all.
#
# --publish ALSO resolves [recipes.viewer] — the existing publish-destination recipe already read by
# run-experiment's close-time publish leg (#347): the viewer repo, its gated landing path, and the
# assemble/render/bundle/gallery commands. This is the mechanical enforcement of the explicit-publish
# boundary: the publish fields are a SEPARATE, independently-typed profile entry, resolved only when
# explicitly asked for — not a filtered view over one document.
#
# Discovery order (identical to every other aar-profile reader in this product):
#   1. $AAR_PROFILE                                             (explicit override; test seam)
#   2. ${XDG_CONFIG_HOME:-~/.config}/experiment-lifecycle/aar-profile.{toml,json}   (.toml wins)
set -euo pipefail

PUBLISH=0
for a in "$@"; do
  case "$a" in
    --publish) PUBLISH=1 ;;
    *) echo "BLOCK: unknown argument: $a (usage: resolve_visualization_recipe.sh [--publish])" >&2; exit 1 ;;
  esac
done

command -v python3 >/dev/null 2>&1 || { echo "BLOCK: python3 is required to resolve the instance profile" >&2; exit 1; }

PUBLISH="$PUBLISH" python3 - <<'PY'
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

sv = data.get("schema_version")
if sv is None:
    block(f"instance profile at {path} is missing required field 'schema_version'")
if sv != 1:
    block(f"instance profile at {path} declares schema_version={sv!r}; this product understands only 1 (refuse-unknown-MAJOR)")

import re
_SAFE_REF = re.compile(r"^[A-Za-z0-9._/-]+$")
_SAFE_SHA = re.compile(r"^[0-9a-fA-F]{7,64}$")
_SAFE_HEXDIGEST = re.compile(r"^[0-9a-fA-F]{64}$")
_SAFE_URI = re.compile(r"^(r2|s3|https)://\S+$")

def resolve_recipe(name, required):
    recipes = data.get("recipes") or {}
    table = recipes.get(name)
    if not required and table is None:
        return None
    if table is None:
        block(f"recipes.{name} is not configured in the instance profile at {path}")
    if not isinstance(table, dict):
        block(f"recipes.{name} must be a table in the instance profile")
    kind = table.get("kind")
    if kind not in ("repo", "uri"):
        block(f"recipes.{name}.kind must be 'repo' or 'uri' (got: {kind!r})")
    out = {"KIND": kind}
    if kind == "repo":
        for field, rx, label in (("repo", _SAFE_REF, "repo"), ("path", _SAFE_REF, "path"), ("git_ref", _SAFE_SHA, "git_ref")):
            v = table.get(field)
            if not isinstance(v, str) or not v:
                block(f"recipes.{name} is missing required field '{field}' for kind=repo")
            if not rx.match(v) or ".." in v.split("/"):
                block(f"recipes.{name}.{field} has an invalid value")
            out[field.upper()] = v
    else:
        v = table.get("uri")
        if not isinstance(v, str) or not _SAFE_URI.match(v):
            block(f"recipes.{name}.uri is missing or has an unsupported scheme (must be r2://, s3://, or https://)")
        out["URI"] = v
        d = table.get("sha256")
        if not isinstance(d, str) or not _SAFE_HEXDIGEST.match(d):
            block(f"recipes.{name} is missing required field 'sha256' for kind=uri")
        out["SHA256"] = d
    return out

# Resolve + validate everything BEFORE printing anything, so a failed --publish request (e.g. an
# incomplete [recipes.viewer]) never leaks partial preview fields to stdout on a non-zero exit.
preview = resolve_recipe("visualization_preview", required=True)
viewer = resolve_recipe("viewer", required=True) if os.environ.get("PUBLISH") == "1" else None

for k, v in preview.items():
    print(f"VISUALIZATION_PREVIEW_{k}={v}")
if viewer is not None:
    for k, v in viewer.items():
        print(f"VIEWER_{k}={v}")
PY
