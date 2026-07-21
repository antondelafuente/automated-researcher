#!/usr/bin/env bash
# resolve_visualization_recipe.sh [--publish]
#
# Resolve the instance's typed visualization recipe pointer(s) from the aar-profile instance profile
# (schema v1, [recipes.<name>] — see plugins/experiment-lifecycle/skills/*/references/SCHEMA.md).
# Fails CLOSED with a clear BLOCK message on stderr and a non-zero exit — never guesses a repo, host,
# port, or worktree. On success, prints resolved fields as KEY=VALUE lines on stdout, each value
# restricted to a conservative safe charset (see the validators below) — READ these lines (e.g. one
# `grep '^KEY='` / `cut` at a time), never `eval` or `source` this output: the charset excludes most
# shell metacharacters but deliberately still permits '&' (needed for multi-param query strings), so
# it does NOT by itself make source/eval of this output safe (#585 P1) — the actual safeguard against
# injection is this prohibition on sourcing/eval, not the charset; this script does not shell-quote for you.
#
# Default (preview) mode resolves ONLY [recipes.visualization_preview] — the local iteration recipe
# (preview claim commands, stable local worktree/URL, page-style pattern). It never reads
# [recipes.visualization_publish] or [recipes.viewer] at all.
#
# --publish ALSO resolves [recipes.visualization_publish] — this skill's OWN editorial publish-destination
# recipe (#369): the editorial site's repo, its gated landing path, and the assemble/render/bundle/gallery
# commands. This is deliberately a SEPARATE, independently-typed profile entry from [recipes.viewer] —
# run-experiment's close-time publish leg (#347) reads [recipes.viewer] for the operational dashboard, a
# different destination on instances where the two diverge; this resolver never reads or requires
# [recipes.viewer] at all, in either mode. This is the mechanical enforcement of the explicit-publish
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
if not isinstance(data, dict):
    block(f"instance profile at {path} does not parse to a table at its root")

sv = data.get("schema_version")
if sv is None:
    block(f"instance profile at {path} is missing required field 'schema_version'")
# type(sv) is int (not just sv == 1) so Python's numeric equality can't sneak a bool/float schema_version
# past this gate: True == 1 and 1.0 == 1 are both true in Python, and neither is the integer 1 the schema
# declares (#368 finding 3).
if type(sv) is not int or sv != 1:
    block(f"instance profile at {path} declares schema_version={sv!r}; this product understands only 1 (refuse-unknown-MAJOR)")

import re
# owner/repo names are restricted to GitHub's own charset (never assumed = research_repo) — narrow by
# construction, not a defensive narrowing.
_SEG = r"[A-Za-z0-9._-]+"
_SAFE_OWNER_REPO = re.compile(rf"^{_SEG}/{_SEG}$")           # exactly one '/'; non-empty on both sides
_SAFE_SHA = re.compile(r"^[0-9a-fA-F]{7,64}$")
_SAFE_HEXDIGEST = re.compile(r"^[0-9a-fA-F]{64}$")
_SCHEME_RE = re.compile(r"^(?:r2|s3|https)://")
# A repo-relative path, or the authority+path+query+fragment tail of a URI, is validated by DENYING
# shell metacharacters/whitespace/control bytes rather than by an ALLOW-list of a few characters — the
# prior allow-list (alnum + '.', '_', '-' only) rejected ordinary things the schema's own
# repo-relative-path/supported-scheme semantics permit, like a URI query string or fragment (#368
# finding 1). '&' is deliberately NOT excluded despite being a shell metacharacter (backgrounding/&&) —
# it is how a query string joins more than one parameter, and excluding it would just reintroduce this
# same finding for any URI with 2+ query params. Excluded here: backtick/$/;/|/</>/(){} and quote/
# backslash characters — these reduce, but by keeping '&' in-band do NOT eliminate, shell-metacharacter
# risk for a future caller who sources/evals this output despite the header note (a value ending
# '&id' would still run 'id' as a new command under source/eval, #585 P1); the actual safeguard
# against that is the header's prohibition on sourcing/eval, not this charset. Everything else (?, #,
# %, :, =, &, ,, +, ~, @, !, ^, *, [, ]) is left in-band.
_UNSAFE_CHARS = re.compile(r'[`$;|<>(){}\\\'"\s\x00-\x1f\x7f]')

def _no_traversal_path(v):
    # A repo-relative path has no query/fragment syntax of its own, so '..' is checked across the
    # ENTIRE value, never stripped on '?'/'#' first — stripping here (as the URI check below does)
    # would let a traversal segment hide after one, e.g. 'recipes/x?/../../secret' (#585 P0).
    return ".." not in v.split("/")

def _no_traversal_uri(v):
    # '..' is only a traversal segment in the URI's path portion; strip any query/fragment first so a
    # query value that happens to contain '..' (e.g. a version range) isn't mistaken for one.
    path_part = v.split("?", 1)[0].split("#", 1)[0]
    return ".." not in path_part.split("/")

def _valid_rel_path(v):
    if not isinstance(v, str) or not v or v.startswith("/") or _UNSAFE_CHARS.search(v):
        return False
    if any(not seg for seg in v.split("/")):
        return False
    return _no_traversal_path(v)

def _valid_uri(v):
    if not isinstance(v, str) or not v:
        return False
    m = _SCHEME_RE.match(v)
    if not m:
        return False
    rest = v[m.end():]
    # rest must not start with '/', '?', or '#' — otherwise the authority component is empty, i.e. the
    # URI names no host/bucket at all (e.g. 'https://?query=yes' passed here before, #585 P0).
    if not rest or rest.startswith(("/", "?", "#")) or _UNSAFE_CHARS.search(rest):
        return False
    return _no_traversal_uri(v)

_REPO_ONLY_FIELDS = ("repo", "path", "git_ref")
_URI_ONLY_FIELDS = ("uri", "sha256")

def resolve_recipe(name, required):
    recipes = data.get("recipes")
    if recipes is not None and not isinstance(recipes, dict):
        block(f"recipes must be a table in the instance profile at {path}")
    table = (recipes or {}).get(name)
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
        stray = [f for f in _URI_ONLY_FIELDS if f in table]
        if stray:
            block(f"recipes.{name} has kind='repo' but also sets {stray} (kind=uri-only field(s)); a kind/field mismatch must fail closed")
        for field, validate in (("repo", _SAFE_OWNER_REPO.match), ("path", _valid_rel_path), ("git_ref", _SAFE_SHA.match)):
            v = table.get(field)
            if not isinstance(v, str) or not v:
                block(f"recipes.{name} is missing required field '{field}' for kind=repo")
            if not validate(v):
                block(f"recipes.{name}.{field} has an invalid value")
            out[field.upper()] = v
    else:
        stray = [f for f in _REPO_ONLY_FIELDS if f in table]
        if stray:
            block(f"recipes.{name} has kind='uri' but also sets {stray} (kind=repo-only field(s)); a kind/field mismatch must fail closed")
        v = table.get("uri")
        if not _valid_uri(v):
            block(f"recipes.{name}.uri is missing, has an unsupported scheme (must be r2://, s3://, or https://), or contains an unsafe character")
        out["URI"] = v
        d = table.get("sha256")
        if not isinstance(d, str) or not _SAFE_HEXDIGEST.match(d):
            block(f"recipes.{name} is missing required field 'sha256' for kind=uri")
        out["SHA256"] = d
    return out

# Resolve + validate everything BEFORE printing anything, so a failed --publish request (e.g. an
# incomplete [recipes.visualization_publish]) never leaks partial preview fields to stdout on a non-zero exit.
preview = resolve_recipe("visualization_preview", required=True)
publish = resolve_recipe("visualization_publish", required=True) if os.environ.get("PUBLISH") == "1" else None

for k, v in preview.items():
    print(f"VISUALIZATION_PREVIEW_{k}={v}")
if publish is not None:
    for k, v in publish.items():
        print(f"VISUALIZATION_PUBLISH_{k}={v}")
PY
