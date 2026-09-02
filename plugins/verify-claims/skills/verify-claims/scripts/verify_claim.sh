#!/bin/bash
# verify_claim.sh — adversarial verification of load-bearing claims by an INDEPENDENT model.
#
# Why: the most dangerous failure of agent-run research isn't a crash — it's a clean pipeline
# producing a confidently-wrong number because a load-bearing claim (the baseline's identity,
# which file holds the original results, whether an artifact exists) was wrong. An agent cannot
# reliably catch its own wrong claims; a reader from a DIFFERENT model family with access to
# only the primary records can. Calibrated on three real incidents: 3/3 caught, 0 false alarms.
#
# Why --exp (automated-researcher#817): the HAND-assembled evidence dir was mechanical waste in the
# design gate. The verifier sees ONLY that dir, so any path the designer forgot to copy came back
# UNKNOWN *by construction* — not a records finding, a packing mistake — and the only fix was
# reassemble + rerun (~2-3 min, ~$1-2 each; a transcript read found the retry in 3 of 3 recent
# designs, and none of the reruns turned up a new contradiction). --exp removes the cause instead of
# the symptom: the packet is built BY CODE from the experiment dir plus every path the claims file
# actually cites, and the facts a script can settle — existence, sha256, line counts, git ancestry —
# are resolved deterministically and written into the packet as MECHANICAL_FACTS.md before the model
# sees anything. Claims the author marked with `check:` directives are settled by that code and never
# reach the verifier at all; the model spends its pass on the SEMANTIC provenance claims, which are
# the ones it is actually better than a script at.
#
# Usage:
#   verify_claim.sh <claims-file> <evidence-dir> [out-file]          # hand-assembled packet
#   verify_claim.sh --exp <experiment-dir> <claims-file> [out-file]  # packet assembled by code
#   claims-file:  numbered claims (markdown); keep each claim atomic and record-checkable
#   evidence-dir: directory of primary records (the verifier sees ONLY this)
#   out-file:     verdict destination (default: <claims-file>.verdict.md)
#
# `check:` directives (--exp only) — an OPT-IN, per-claim declaration that a claim is settled by code.
# Indent them under the numbered claim they belong to; each is evaluated deterministically, and a
# claim whose directives ALL pass is emitted as CONFIRM without ever being sent to the verifier:
#   check: exists <path>
#   check: sha256 <path> <64-hex>
#   check: rows   <path> <n>        # line count (alias: lines)
#   check: commit <path>@<sha>      # path present at <sha> AND <sha> is an ancestor of HEAD
# A failing directive is a DISPUTE (a cited path that does not resolve fails loudly, on purpose — a
# gate must fail closed). A directive the ENVIRONMENT cannot evaluate (e.g. `commit` outside a git
# repo) resolves nothing: that claim goes to the verifier with a note. Paths cited WITHOUT a
# directive are still resolved, copied into the packet, and reported in MECHANICAL_FACTS.md — they
# just don't auto-settle their claim, because only the author knows whether the sentence asserts more
# than the mechanical fact does.
#
# Verdicts: per-claim CONFIRM / DISPUTE / UNKNOWN with file citations. Treat DISPUTE as a
# blocker and UNKNOWN as "your records are too thin to support this claim".
#
# Verifier: OpenAI Codex CLI by default (`codex exec --sandbox read-only` — mechanically unable
# to write; needs unprivileged user namespaces for bubblewrap. If bwrap errors on your kernel,
# either enable userns or override VERIFIER_CMD). Any CLI model runner works via VERIFIER_CMD —
# it receives the prompt on stdin, must run with cwd=$EVIDENCE, and write its final answer to $OUT.
#
# Env: VERIFY_CLAIM_MAX_BYTES (default 2097152) — files larger than this go into the packet as a
#      head+tail excerpt (text) or as facts only (binary), so one huge rollout log can't blow up the
#      packet. VERIFY_CLAIM_KEEP_EVIDENCE=1 keeps the generated packet dir for inspection.
set -euo pipefail

EXP=""
if [ "${1:-}" = "--exp" ]; then
  EXP=${2:?usage: verify_claim.sh --exp <experiment-dir> <claims-file> [out-file]}
  shift 2
fi
CLAIMS=${1:?usage: verify_claim.sh [--exp <experiment-dir>] <claims-file> [evidence-dir] [out-file]}
[ -s "$CLAIMS" ] || { echo "BLOCKED: claims file missing/empty: $CLAIMS" >&2; exit 1; }

run_verifier() {   # $1=claims-file  $2=evidence-dir  $3=destination  $4=run-log path  $5=prompt preamble
  local claims_file=$1 evidence=$2 dest=$3 runlog=$4 preamble=$5
  local prompt out_tmp verifier
  prompt="You are an ADVERSARIAL VERIFIER. Below are numbered claims about a past experiment.
Your job is to try to REFUTE each claim using ONLY the files in the current directory (the
primary records). Read whatever files you need (grep/head as needed; some logs are large).
${preamble}
Rules:
- Use ONLY these records. No outside knowledge about what 'should' be true, no guessing.
- For EVERY claim give exactly one verdict:
  CONFIRM  — the records affirmatively support it (cite the decisive file + quote the line)
  DISPUTE  — the records contradict it (cite the decisive file + quote the contradicting line)
  UNKNOWN  — these records cannot settle it (state precisely what evidence is missing)
- UNKNOWN is a respectable answer. Do NOT stretch to CONFIRM: a claim that is merely
  consistent with the records but not evidenced by them is UNKNOWN, not CONFIRM.
- A claim is DISPUTED if any part of it is contradicted, even if other parts hold.
- Keep each claim's ORIGINAL number in your output; the numbering may have gaps.

Output format (exactly):
CLAIM <n>: <CONFIRM|DISPUTE|UNKNOWN>
  evidence: <file>: \"<short quote>\"
  reasoning: <1-2 sentences>
...
SUMMARY: confirm=<n> dispute=<n> unknown=<n>

THE CLAIMS:
$(cat "$claims_file")"

  # stale-output guard: write to a temp file, atomic-mv only on success — never reuse a prior output.
  out_tmp="$(mktemp "${TMPDIR:-/tmp}/verify.XXXXXX.md")"
  # OUT_TMP/EVIDENCE stay SHELL-GLOBAL: a caller-supplied VERIFIER_CMD is documented to reference them.
  OUT_TMP="$out_tmp"; EVIDENCE="$evidence"
  verifier=${VERIFIER_CMD:-"codex exec --sandbox read-only --skip-git-repo-check --cd \"$evidence\" -o \"$out_tmp\""}
  echo "[verify_claim] evidence=$evidence claims=$claims_file" >&2
  if ! eval "$verifier" <<< "$prompt" >"$runlog" 2>&1; then
    echo "BLOCKED: verifier run failed — last lines of $runlog:" >&2
    tail -5 "$runlog" >&2; rm -f "$out_tmp"; return 1; fi
  [ -s "$out_tmp" ] || { echo "BLOCKED: verifier produced no verdict (stale $dest NOT reused)" >&2; rm -f "$out_tmp"; return 1; }
  mv "$out_tmp" "$dest"
}

# ---------------------------------------------------------------- legacy: hand-assembled packet
if [ -z "$EXP" ]; then
  EVIDENCE=${2:?need evidence dir}
  OUT=${3:-${CLAIMS}.verdict.md}
  [ -d "$EVIDENCE" ] || { echo "BLOCKED: evidence dir missing: $EVIDENCE" >&2; exit 1; }
  run_verifier "$CLAIMS" "$EVIDENCE" "$OUT" "$OUT.run.log" ""
  echo "[verify_claim] verdict -> $OUT" >&2
  grep -E "^CLAIM|^SUMMARY" "$OUT" || true
  exit 0
fi

# ---------------------------------------------------------------- --exp: packet assembled by code
OUT=${2:-${CLAIMS}.verdict.md}
[ -d "$EXP" ] || { echo "BLOCKED: experiment dir missing: $EXP" >&2; exit 1; }
[ -s "$EXP/DESIGN.md" ] || { echo "BLOCKED: no DESIGN.md in experiment dir: $EXP" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/verify_claim.XXXXXX")"
cleanup() { [ "${VERIFY_CLAIM_KEEP_EVIDENCE:-0}" = 1 ] || rm -rf "$WORK"; }
trap cleanup EXIT

VC_EXP="$EXP" VC_CLAIMS="$CLAIMS" VC_WORK="$WORK" \
VC_MAX_BYTES="${VERIFY_CLAIM_MAX_BYTES:-2097152}" python3 - <<'PY'
import hashlib
import os
import re
import shutil
import subprocess
import sys

EXP = os.path.abspath(os.environ["VC_EXP"])
CLAIMS = os.environ["VC_CLAIMS"]
WORK = os.environ["VC_WORK"]
MAX_BYTES = int(os.environ["VC_MAX_BYTES"])

PACKET = os.path.join(WORK, "packet")
os.makedirs(PACKET, exist_ok=True)


def git(*args, cwd=EXP):
    try:
        r = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)
    except OSError:
        return None
    return r.stdout.strip() if r.returncode == 0 else None


ROOT = git("rev-parse", "--show-toplevel")
HEAD = git("rev-parse", "HEAD") if ROOT else None

# ---- parse the claims file into (number, lines) blocks, keeping any preamble ------------------
raw = open(CLAIMS, encoding="utf-8", errors="replace").read().splitlines()
CLAIM_START = re.compile(r"^\s*(\d+)[.)]\s")
CHECK = re.compile(r"^\s*check:\s*(\S+)\s+(.*?)\s*$", re.IGNORECASE)

preamble, claims, cur = [], [], None
for line in raw:
    m = CLAIM_START.match(line)
    if m:
        cur = {"n": int(m.group(1)), "lines": [line], "checks": []}
        claims.append(cur)
    elif cur is None:
        preamble.append(line)
    else:
        cur["lines"].append(line)
for c in claims:
    body = []
    for line in c["lines"]:
        m = CHECK.match(line)
        if m:
            c["checks"].append((m.group(1).lower(), m.group(2)))
        else:
            body.append(line)
    c["body"] = body
    c["text"] = "\n".join(c["lines"])

# ---- extract + resolve every cited path -------------------------------------------------------
PATH_RE = re.compile(r"(?<![\w/@])((?:[\w.~+-]+/)+[\w.~+-]+)(?:@([0-9a-fA-F]{7,40}))?")
URL_RE = re.compile(r"\w+://\S+")
EXT_RE = re.compile(r"\.[A-Za-z0-9]{1,8}$")
SEARCH_BASES = [b for b in (EXP, os.path.dirname(EXP), ROOT, os.getcwd()) if b]


def looks_like_a_path(p):
    """Filter prose that merely contains a slash ("and/or", "24k/53k") out of the citation set."""
    return p.count("/") >= 2 or EXT_RE.search(p.rsplit("/", 1)[-1]) is not None


def resolve(p):
    """Return (abspath or None, list of locations searched)."""
    p = p.rstrip(".,;:!?")
    if os.path.isabs(p):
        return (p if os.path.exists(p) else None), [p]
    tried = []
    for base in SEARCH_BASES:
        cand = os.path.normpath(os.path.join(base, p))
        if cand in tried:
            continue
        tried.append(cand)
        if os.path.exists(cand):
            return cand, tried
    return None, tried


cited = {}      # cited-string -> {"abs":…, "tried":[…], "commits":set()}
for text in ["\n".join(preamble)] + [c["text"] for c in claims]:
    text = URL_RE.sub(" ", text)     # a URL is not a local record; don't chase its path segments
    for m in PATH_RE.finditer(text):
        p = m.group(1).rstrip(".,;:!?")
        if not p or p.endswith("/") or not looks_like_a_path(p):
            continue
        ent = cited.setdefault(p, {"commits": set()})
        if "abs" not in ent:
            ent["abs"], ent["tried"] = resolve(p)
        if m.group(2):
            ent["commits"].add(m.group(2))

# DESIGN.md is always in the packet, cited or not — it is the record the claims are about.
cited.setdefault("DESIGN.md", {"commits": set(), "abs": os.path.join(EXP, "DESIGN.md"),
                               "tried": [os.path.join(EXP, "DESIGN.md")]})

# ---- copy into the packet + compute the mechanical facts --------------------------------------
def packet_rel(p):
    rel = os.path.normpath(p.lstrip("/") if os.path.isabs(p) else p)
    if os.path.isabs(p):
        rel = os.path.join("abs", rel)
    if rel.startswith(".."):
        rel = os.path.join("cited", os.path.basename(rel))
    return rel


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def is_text(path):
    with open(path, "rb") as fh:
        return b"\0" not in fh.read(8192)


def line_count(path):
    n = 0
    with open(path, "rb") as fh:
        last = b"\n"
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            n += chunk.count(b"\n")
            last = chunk[-1:]
        if last not in (b"\n", b""):
            n += 1
    return n


facts, manifest = [], []
for p in sorted(cited):
    ent = cited[p]
    ap = ent.get("abs")
    facts.append(f"### `{p}`")
    if not ap:
        facts.append("- resolved: **NO** — the claims file cites this path but nothing exists at it.")
        for t in ent.get("tried", []):
            facts.append(f"  - searched: `{t}`")
        facts.append("")
        continue
    rel = packet_rel(p)
    ent["packet_rel"] = rel
    dest = os.path.join(PACKET, rel)
    os.makedirs(os.path.dirname(dest) or PACKET, exist_ok=True)
    facts.append(f"- resolved: YES -> `{ap}`")
    if os.path.isdir(ap):
        listing = sorted(
            os.path.relpath(os.path.join(dp, f), ap)
            for dp, _, fs in os.walk(ap) for f in fs
        )[:500]
        with open(dest + ".listing.txt", "w", encoding="utf-8") as fh:
            fh.write("\n".join(listing) + "\n")
        facts.append(f"- kind: directory, {len(listing)} file(s) listed")
        manifest.append(f"- `{rel}.listing.txt` (directory listing of `{p}`)")
    else:
        size = os.path.getsize(ap)
        facts.append(f"- bytes: {size}")
        facts.append(f"- sha256: `{sha256_of(ap)}`")
        text = is_text(ap)
        if text:
            ent["lines"] = line_count(ap)
            facts.append(f"- lines: {ent['lines']}")
        if size <= MAX_BYTES:
            shutil.copyfile(ap, dest)
            manifest.append(f"- `{rel}` (full copy of `{p}`)")
        elif text:
            with open(ap, encoding="utf-8", errors="replace") as fh:
                head = [next(fh, "") for _ in range(200)]
            tail = subprocess.run(["tail", "-n", "100", ap], capture_output=True, text=True).stdout
            with open(dest, "w", encoding="utf-8") as fh:
                fh.write("".join(head))
                fh.write(f"\n... [verify_claim] EXCERPT: {size} bytes > {MAX_BYTES}; "
                         f"first 200 and last 100 lines only. sha256/line count in MECHANICAL_FACTS.md ...\n\n")
                fh.write(tail)
            facts.append(f"- packet copy: EXCERPT ONLY (first 200 + last 100 lines of {ent['lines']})")
            manifest.append(f"- `{rel}` (head+tail excerpt of `{p}`; full sha256/line count in MECHANICAL_FACTS.md)")
        else:
            facts.append(f"- packet copy: NONE (binary, {size} bytes > {MAX_BYTES}); facts above are the record")
    if ROOT:
        tracked = git("ls-files", "--error-unmatch", "--", ap, cwd=ROOT)
        facts.append(f"- git: {'tracked' if tracked is not None else 'NOT tracked'} in `{ROOT}`")
    for sha in sorted(ent["commits"]):
        if not ROOT:
            facts.append(f"- `@{sha}`: NOT EVALUATED (no git repo at or above the experiment dir)")
            continue
        relroot = os.path.relpath(ap, ROOT)
        present = subprocess.run(["git", "cat-file", "-e", f"{sha}:{relroot}"],
                                 cwd=ROOT, capture_output=True).returncode == 0
        anc = subprocess.run(["git", "merge-base", "--is-ancestor", sha, "HEAD"],
                             cwd=ROOT, capture_output=True).returncode == 0 if HEAD else False
        facts.append(f"- `@{sha}`: path present at that commit = {'YES' if present else 'NO'}; "
                     f"commit is an ancestor of HEAD = {'YES' if anc else 'NO'}")
    facts.append("")

# ---- evaluate the opt-in `check:` directives --------------------------------------------------
def eval_check(kind, arg):
    """-> (True|False|None, explanation). None = the environment could not evaluate it."""
    parts = arg.split()
    if kind == "exists" and len(parts) == 1:
        ap, tried = resolve(parts[0])
        return (ap is not None), (f"`{parts[0]}` -> `{ap}`" if ap else
                                  f"`{parts[0]}` resolves to nothing (searched {len(tried)} location(s))")
    if kind == "sha256" and len(parts) == 2:
        ap, _ = resolve(parts[0])
        if ap is None or os.path.isdir(ap):
            return False, f"`{parts[0]}` resolves to no readable file"
        got = sha256_of(ap)
        return got.lower() == parts[1].lower(), f"`{parts[0]}` sha256={got} (claimed {parts[1]})"
    if kind in ("rows", "lines") and len(parts) == 2:
        ap, _ = resolve(parts[0])
        if ap is None or os.path.isdir(ap):
            return False, f"`{parts[0]}` resolves to no readable file"
        got = line_count(ap)
        return str(got) == parts[1], f"`{parts[0]}` lines={got} (claimed {parts[1]})"
    if kind == "commit" and len(parts) == 1 and "@" in parts[0]:
        p, sha = parts[0].rsplit("@", 1)
        if not ROOT:
            return None, f"`{parts[0]}`: no git repo at or above the experiment dir"
        ap, _ = resolve(p)
        relroot = os.path.relpath(ap, ROOT) if ap else p
        present = subprocess.run(["git", "cat-file", "-e", f"{sha}:{relroot}"],
                                 cwd=ROOT, capture_output=True).returncode == 0
        anc = subprocess.run(["git", "merge-base", "--is-ancestor", sha, "HEAD"],
                             cwd=ROOT, capture_output=True).returncode == 0
        return (present and anc), f"`{p}` present at {sha}={present}; {sha} ancestor of HEAD={anc}"
    return None, f"unrecognized directive `check: {kind} {arg}`"


mech_lines, residual = [], []
for c in claims:
    if not c["checks"]:
        residual.append(c)
        continue
    results = [(k, a, *eval_check(k, a)) for k, a in c["checks"]]
    if any(r[2] is None for r in results):
        c["note"] = ("    [verify_claim] a `check:` directive could not be evaluated mechanically: "
                     + "; ".join(r[3] for r in results if r[2] is None))
        residual.append(c)
        continue
    ok = all(r[2] for r in results)
    mech_lines.append(f"CLAIM {c['n']}: {'CONFIRM' if ok else 'DISPUTE'}")
    mech_lines.append("  evidence: MECHANICAL_FACTS.md: \"" + "; ".join(r[3] for r in results).replace('"', "'") + "\"")
    mech_lines.append("  reasoning: resolved deterministically by verify_claim.sh --exp "
                      f"({len(results)} check directive(s), {'all passed' if ok else 'at least one failed'}); "
                      "no model judgment involved.")

# ---- write the packet's derived files + this script's own hand-off files ----------------------
with open(os.path.join(PACKET, "MECHANICAL_FACTS.md"), "w", encoding="utf-8") as fh:
    fh.write("# MECHANICAL_FACTS.md — resolved by code, not by a model\n\n"
             "Generated by `verify_claim.sh --exp`. Every fact below was computed deterministically from\n"
             "the filesystem and git at gate time. Treat it as a primary record: it is exactly as\n"
             "authoritative as the files it describes, and it is the answer to \"does this path exist / what\n"
             "is its hash / how many rows / did that commit land\" — do NOT answer UNKNOWN on a question this\n"
             "file already settles.\n\n"
             f"- experiment dir: `{EXP}`\n"
             f"- repo root: `{ROOT or '(not a git repo)'}`\n"
             f"- HEAD: `{HEAD or '-'}`\n\n"
             "## Paths cited by the claims file\n\n" + "\n".join(facts) + "\n")
manifest.insert(0, "- `MECHANICAL_FACTS.md` (existence / sha256 / line counts / git ancestry, computed by code)")

with open(os.path.join(WORK, "packet_manifest.md"), "w", encoding="utf-8") as fh:
    fh.write("\n".join(manifest) + "\n")
with open(os.path.join(WORK, "mechanical.md"), "w", encoding="utf-8") as fh:
    fh.write("\n".join(mech_lines) + ("\n" if mech_lines else ""))
with open(os.path.join(WORK, "residual_claims.md"), "w", encoding="utf-8") as fh:
    if not claims:
        # No numbered claims to split on — send the file through unchanged rather than dropping it.
        fh.write("\n".join(raw).rstrip() + "\n")
    elif residual:
        if preamble:
            fh.write("\n".join(preamble).strip() + "\n\n")
        for c in residual:
            fh.write("\n".join(c["body"]).rstrip() + "\n")
            if c.get("note"):
                fh.write(c["note"] + "\n")

unresolved = [p for p in sorted(cited) if not cited[p].get("abs")]
print(f"[verify_claim] packet: {len(manifest)} file(s); "
      f"{len(mech_lines) // 3} claim(s) settled mechanically; {len(residual)} to the verifier; "
      f"{len(unresolved)} cited path(s) unresolved", file=sys.stderr)
for p in unresolved:
    print(f"[verify_claim] WARN cited path does not resolve: {p}", file=sys.stderr)
if not claims:
    print("[verify_claim] WARN no numbered claims found; sending the whole file to the verifier", file=sys.stderr)
PY

PACKET="$WORK/packet"
VERIFIER_OUT="$WORK/verifier.md"
if [ -s "$WORK/residual_claims.md" ]; then
  run_verifier "$WORK/residual_claims.md" "$PACKET" "$VERIFIER_OUT" "$OUT.run.log" "
The packet also contains MECHANICAL_FACTS.md — file existence, sha256 hashes, line counts and git
ancestry already resolved DETERMINISTICALLY by the script that built this packet. It is a primary
record: never answer UNKNOWN on something it already settles, and if a claim contradicts it, that is
a DISPUTE with MECHANICAL_FACTS.md as the decisive citation. Claims settled entirely by code were
already answered and are not in the list below, so the numbering has gaps — keep the numbers given.
"
else
  : > "$VERIFIER_OUT"
  echo "[verify_claim] every claim settled mechanically — verifier not run" >&2
fi

{
  echo "# verify_claim verdict — $CLAIMS"
  echo
  echo "Experiment: \`$EXP\` · packet assembled by \`verify_claim.sh --exp\` (automated-researcher#817)."
  echo
  echo "## Evidence packet (built by code — this is what the verifier could see)"
  echo
  cat "$WORK/packet_manifest.md"
  echo
  if [ -s "$WORK/mechanical.md" ]; then
    echo "## Mechanically resolved (deterministic — no model)"
    echo
    cat "$WORK/mechanical.md"
    echo
  fi
  if [ -s "$VERIFIER_OUT" ]; then
    echo "## Verifier verdicts (independent model family, semantic claims only)"
    echo
    cat "$VERIFIER_OUT"
    echo
  fi
} > "$OUT.assembled"

# Combined SUMMARY over BOTH halves — the line downstream consumers read.
CONFIRM=$(grep -cE "^CLAIM [0-9]+: CONFIRM" "$OUT.assembled" || true)
DISPUTE=$(grep -cE "^CLAIM [0-9]+: DISPUTE" "$OUT.assembled" || true)
UNKNOWN=$(grep -cE "^CLAIM [0-9]+: UNKNOWN" "$OUT.assembled" || true)
{ cat "$OUT.assembled"; echo "SUMMARY: confirm=$CONFIRM dispute=$DISPUTE unknown=$UNKNOWN"; } > "$OUT"
rm -f "$OUT.assembled"
[ "${VERIFY_CLAIM_KEEP_EVIDENCE:-0}" = 1 ] && echo "[verify_claim] packet kept at $PACKET" >&2 || true

echo "[verify_claim] verdict -> $OUT" >&2
grep -E "^CLAIM|^SUMMARY" "$OUT" || true
