"""audit_data.py — DETERMINISTIC full-pool data audit + stratified high-risk sampler.

Layer 1 of the data-audit (the cheap, exact, full-pool checks); layer 2 is the cross-family
SEMANTIC audit of the SAMPLE this produces (`audit_experiment.sh --data`). Built 2026-06-16 after a
truncated-CoT-replay incident (a generated replay structurally froze clean while ~18% of rows were
truncated mid-`<think>`, and a 2-sample smoke saw only short easy rows).

Do NOT spend the LLM on what a regex does better — this script owns: counts, schema consistency,
exact duplicates, empty/blank rows, (CoT) finish_reason + closed-think + non-empty-answer, length
distribution (char-proxy — no tokenizer needed, runs anywhere), near-cap rows, source balance,
label/arm balance. The LLM (layer 2) reads the SAMPLE for semantics a script can't see (confounds,
leakage, off-distribution, mislabeling, "does this match the design intent").

Usage:
  python3 audit_data.py DATA.jsonl --out data_audit.json --sample data_audit_sample.jsonl \
      [--cot] [--require-finish-reason] [--source-field source] [--label-field arm] [--text-field assistant] \
      [--cap-chars 24000] [--sample-k 6]
Exit 2 if any HARD invariant fails (open-think rows in --cot mode, empties, schema drift) — a BLOCK.
The stratified sample deliberately includes the RISKY strata, not just random rows.

IMPORTANT — auditing an added/edited subset within a larger unchanged base (ablations, add-back
waves, targeted edits): ALWAYS pass --label-field pointing at whatever column distinguishes the
subset (e.g. an arm/added-vs-base flag). Without it, the per-source/per-label strata and the evenly-
spaced random pass are the only things pulling non-extreme rows into the sample, and on a small
minority inside a much larger majority they can miss the minority entirely — you can end up auditing
a "clean" sample that is 100% base rows and 0% added rows. --label-field guarantees per-label
coverage regardless of how small the minority is.
"""
import argparse, hashlib, json, statistics, sys


def load(path):
    rows = []
    for i, line in enumerate(open(path)):
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except Exception as e:
            rows.append({"__parse_error__": str(e), "__raw__": line[:200], "__idx__": i})
    return rows


def assistant_text(r, field):
    if field and field in r:
        return r[field] if isinstance(r[field], str) else json.dumps(r[field])
    # try common shapes
    for k in ("assistant", "response", "completion", "output", "text"):
        if isinstance(r.get(k), str):
            return r[k]
    msgs = r.get("messages")
    if isinstance(msgs, list) and msgs:
        last = msgs[-1]
        if isinstance(last, dict) and isinstance(last.get("content"), str):
            return last["content"]
    return ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("data")
    ap.add_argument("--out", default="data_audit.json")
    ap.add_argument("--sample", default="data_audit_sample.jsonl")
    ap.add_argument("--cot", action="store_true", help="CoT invariants: finish_reason==stop when present, closed </think>, non-empty answer")
    ap.add_argument("--require-finish-reason", action="store_true", help="In --cot mode, hard-fail rows missing finish_reason")
    ap.add_argument("--source-field", default="source")
    ap.add_argument("--label-field", default=None, help="arm/label field for balance + per-arm sampling — "
                     "always pass this when auditing an added/edited subset within a larger unchanged base, "
                     "or the default sample can oversample the unchanged majority and miss the subset entirely")
    ap.add_argument("--text-field", default=None)
    ap.add_argument("--cap-chars", type=int, default=24000, help="length cap (char proxy); 'near-cap' = >95%% of cap")
    ap.add_argument("--sample-k", type=int, default=6, help="rows per stratum")
    a = ap.parse_args()

    rows = load(a.data)
    n = len(rows)
    rep = {"file": a.data, "n_rows": n, "HARD_FAILS": [], "warnings": []}
    if n == 0:
        rep["HARD_FAILS"].append("empty file (0 rows)")
        json.dump(rep, open(a.out, "w"), indent=2)
        print("DATA AUDIT: HARD FAIL — 0 rows", flush=True)
        sys.exit(2)

    parse_errs = [i for i, r in enumerate(rows) if "__parse_error__" in r]
    keys = [tuple(sorted(r.keys())) for r in rows if "__parse_error__" not in r]
    schema_variants = {}
    for k in keys:
        schema_variants[k] = schema_variants.get(k, 0) + 1
    texts = [assistant_text(r, a.text_field) for r in rows]
    lens = [len(t) for t in texts]
    empties = [i for i, t in enumerate(texts) if not t.strip()]
    hashes = {}
    for i, r in enumerate(rows):
        h = hashlib.sha1(json.dumps(r, sort_keys=True).encode()).hexdigest()
        hashes.setdefault(h, []).append(i)
    dups = {h: idxs for h, idxs in hashes.items() if len(idxs) > 1}
    near_cap = [i for i, L in enumerate(lens) if L > 0.95 * a.cap_chars]

    rep["parse_errors"] = len(parse_errs)
    rep["schema_variants"] = {str(k): v for k, v in schema_variants.items()}
    rep["empty_text_rows"] = len(empties)
    rep["exact_duplicate_groups"] = len(dups)
    rep["exact_duplicate_rows"] = sum(len(v) for v in dups.values())
    rep["char_len"] = {"min": min(lens), "median": int(statistics.median(lens)), "p95": int(sorted(lens)[int(0.95 * (n - 1))]), "max": max(lens)} if lens else {}
    rep["near_cap_rows"] = len(near_cap)

    # source / label balance
    def balance(field):
        c = {}
        for r in rows:
            c[str(r.get(field))] = c.get(str(r.get(field)), 0) + 1
        return c
    rep["source_balance"] = balance(a.source_field)
    if a.label_field:
        rep["label_balance"] = balance(a.label_field)
    else:
        rep["warnings"].append(
            "no --label-field set: if this file has an added/edited minority subset inside a larger "
            "unchanged base (ablation, add-back wave, targeted edit), the default sample can miss it "
            "entirely — pass --label-field pointing at whatever column distinguishes the subset"
        )

    open_think = []
    if a.cot:
        missing_finish, finish_not_stop, open_th, empty_ans = [], [], [], []
        for i, (r, t) in enumerate(zip(rows, texts)):
            fr = r.get("finish_reason")
            if fr is None:
                if a.require_finish_reason:
                    missing_finish.append(i)
            elif fr != "stop":
                finish_not_stop.append(i)
            if "<think>" in t and "</think>" not in t:
                open_th.append(i)
            after = t.split("</think>")[-1].strip() if "</think>" in t else t.strip()
            if not after:
                empty_ans.append(i)
        open_think = open_th
        rep["cot"] = {"finish_reason_missing": len(missing_finish),
                      "finish_reason_not_stop": len(finish_not_stop),
                      "open_think_truncated": len(open_th),
                      "empty_answer": len(empty_ans),
                      "by_source_open_think": {s: sum(1 for i in open_th if str(rows[i].get(a.source_field)) == s) for s in rep["source_balance"]}}
        if missing_finish:
            rep["HARD_FAILS"].append(f"{len(missing_finish)} rows missing finish_reason")
        if finish_not_stop:
            rep["HARD_FAILS"].append(f"{len(finish_not_stop)} rows finish_reason!=stop")
        if open_th:
            rep["HARD_FAILS"].append(f"{len(open_th)} rows open-`<think>` (truncated mid-CoT)")
        if empty_ans:
            rep["HARD_FAILS"].append(f"{len(empty_ans)} rows empty answer after think")

    if empties:
        rep["HARD_FAILS"].append(f"{len(empties)} empty-text rows")
    if parse_errs:
        rep["HARD_FAILS"].append(f"{len(parse_errs)} unparseable rows")
    if len(schema_variants) > 1:
        rep["warnings"].append(f"{len(schema_variants)} distinct key-schemas (drift?)")
    if dups:
        rep["warnings"].append(f"{rep['exact_duplicate_rows']} exact-duplicate rows in {len(dups)} groups")

    # ---- stratified HIGH-RISK sample (not just random) ----
    order = sorted(range(n), key=lambda i: lens[i])
    cap = max(40, a.sample_k * 8)

    def group_by(field):
        g = {}
        for i, r in enumerate(rows):
            g.setdefault(str(r.get(field)), []).append(i)
        return g

    def fair_share_budget(n_groups, remaining):
        """Cap a coverage pass's budget at half the remaining cap, EXCEPT never below `n_groups` —
        that floor is what preserves the "every distinct value represented whenever value-count <=
        cap" guarantee. Only the proportional leftover-fill portion (beyond one-per-group) is what
        gets capped; the one-per-group claim always gets however much budget it needs, up to `cap`."""
        return min(remaining, max(n_groups, cap // 2))

    def allocate_coverage(groups, budget, picks, kind):
        """Spend at most `budget` new picks covering every group: minimum 1 per group (deterministic
        group order), then proportional fill of any leftover budget favoring larger groups. Never adds
        more than `budget` rows, so callers compose without ever exceeding the overall sample cap."""
        keys = sorted(groups)
        added = []
        if not keys or budget <= 0:
            if keys:
                rep["warnings"].append(
                    f"{len(keys)} distinct {kind} values but 0 sample slots remain (cap={cap}): "
                    f"{kind} coverage is PARTIAL"
                )
            return added
        covered = keys[:budget]
        if len(keys) > budget:
            rep["warnings"].append(
                f"{len(keys)} distinct {kind} values exceed the {budget}-row sample budget (cap={cap}): "
                f"only {budget} {kind} values are represented in the sample — coverage is PARTIAL"
            )
        remaining = budget
        for k in covered:
            if remaining <= 0:
                break
            row = next((i for i in groups[k] if i not in picks and i not in added), None)
            if row is None:
                continue
            added.append(row); remaining -= 1
        if remaining > 0:
            fill_order = sorted(covered, key=lambda k: (-len(groups[k]), k))
            progress = True
            while remaining > 0 and progress:
                progress = False
                for k in fill_order:
                    if remaining <= 0:
                        break
                    row = next((i for i in groups[k] if i not in picks and i not in added), None)
                    if row is None:
                        continue
                    added.append(row); remaining -= 1; progress = True
        return added

    # Every stage below only spends whatever budget remains, so the sample never exceeds `cap`
    # regardless of source/label cardinality. Per-label coverage goes FIRST — that's the guarantee
    # --label-field exists to make (every distinct label represented whenever label-count <= cap), so
    # its one-per-group claim always gets first call on the budget. But its PROPORTIONAL LEFTOVER FILL
    # (beyond that one-per-group minimum) is capped via fair_share_budget so a single majority-class
    # group can't silently absorb the whole cap and starve the risk strata below (the incident this
    # fixes: a large unsplit group kept the label pass's round-robin fill going until `remaining` hit
    # 0, so `picks` was already at `cap` before the risk-strata loop ran a single iteration).
    picks = set()
    if a.label_field:
        label_groups = group_by(a.label_field)
        label_budget = fair_share_budget(len(label_groups), cap - len(picks))
        picks.update(allocate_coverage(label_groups, label_budget, picks, "label"))
    risk_strata = [
        ("shortest", order[: a.sample_k]), ("longest", order[-a.sample_k:]),
        ("near_cap", near_cap[: a.sample_k]), ("open_think", open_think[: a.sample_k]),
        ("parse_err", parse_errs[: a.sample_k]), ("empty", empties[: a.sample_k]),
    ]
    for name, stratum in risk_strata:
        for i in stratum:
            if len(picks) >= cap:
                break
            picks.add(i)
        if stratum and not any(i in picks for i in stratum):
            rep["warnings"].append(
                f"{len(stratum)} candidate {name} rows exist but 0 made it into the sample "
                f"(cap={cap} already spent by earlier strata): {name} risk-stratum coverage is PARTIAL"
            )
    # Unlike the label pass above, this one is NOT gated behind `if a.label_field` — `--source-field`
    # defaults to "source" and this pass runs on every invocation. So capping its leftover fill via
    # fair_share_budget changes sampling composition (occasionally count too, when the spread pass's
    # fixed-step candidate list can't backfill the gap) even when --label-field is never passed. That's
    # deliberate — issue #570 asked for the same cap here "if cheap", independent of --label-field — not
    # a violation of the "no behavior change without --label-field" guarantee, which only ever covered
    # the separately-gated label pass.
    source_groups = group_by(a.source_field)
    source_budget = fair_share_budget(len(source_groups), cap - len(picks))
    picks.update(allocate_coverage(source_groups, source_budget, picks, "source"))
    step = max(1, n // a.sample_k)
    spread = [i for i in range(0, n, step) if i not in picks]
    picks.update(spread[: max(0, cap - len(picks))])
    picks = sorted(picks)

    with open(a.sample, "w") as f:
        for i in picks:
            row = dict(rows[i]); row["__audit_idx__"] = i; row["__audit_char_len__"] = lens[i]
            f.write(json.dumps(row) + "\n")
    rep["sample_file"] = a.sample
    rep["sample_n"] = len(picks)
    rep["sample_strata"] = "per_label|shortest|longest|near_cap|open_think|parse_err|empty|per_source|spread"

    json.dump(rep, open(a.out, "w"), indent=2)
    status = "HARD FAIL" if rep["HARD_FAILS"] else "ok"
    print(f"DATA AUDIT [{status}] n={n} | {rep['HARD_FAILS'] or 'no hard fails'} | warnings={rep['warnings']} | sample={len(picks)} -> {a.sample}", flush=True)
    sys.exit(2 if rep["HARD_FAILS"] else 0)


if __name__ == "__main__":
    main()
