"""assert_join_complete.py — fail-closed join-completeness assertion for aggregator/figure stacks.

The shipped form of this skill's own "an all-null/all-zero join result is a bug signal, never a
finding" rule (#349), which existed only as prose: every aggregator re-derived the assertion by hand,
or didn't. Built 2026-08-15 after automated-researcher#731 (close retro for
`depv1-negemo-manufacture-2`): a dose-figure builder joined `figures/dose.csv` against
`figures/subject_grid.csv` on the SUBJECT name (`manu200-d40-s4`) while that grid keys on
`(arm, seed)` — `subject` holds `manu200-d40` and the seed is a separate column — so the join matched
nothing, all four canonical judged cells came out BLANK, and rows sourced from a different file
populated normally. The figure looked plausible and was wrong; the cross-family close audit caught it,
not the pipeline.

The invariant: a row FLAGGED as judged must actually carry a number. Call this before writing the
table/figure — it raises `JoinIncompleteError` rather than letting a blank-celled artifact ship.

    from assert_join_complete import assert_join_complete
    assert_join_complete(rows, "judged", ["mean"],
                         group_field="battery", per_group_fields=["interval"])

TWO TIERS, and the split is the whole point (the #731 near-miss). `value_fields` are required on
EVERY judged row — that is the tier that catches the incident above, where an entire cell went blank.
`per_group_fields` are required only WITHIN a group that already demonstrates the field: if any judged
row in a battery carries it, every judged row in that battery must; a battery where no judged row
carries it is legitimately without it. #731's first hand-rolled version of this assertion demanded an
interval on every judged row and mis-fired on legitimately interval-free coherence rows — the
invariant is per-battery, and it is easy to get wrong twice. Put `mean` in `value_fields` and
`interval` in `per_group_fields`; do NOT put a whole-table-derivable field in `per_group_fields`,
because a field no row carries is vacuously satisfied there (that is exactly why the always-required
tier exists).

Fail-closed everywhere it can't tell: an empty table, a row missing the flag field, an unrecognized
flag token, and a non-numeric/blank value on a judged row are all violations, not skips. A run where
NOTHING is judged is legitimate and passes — a per-battery spend tripwire (#728) skipping a collapsed
battery is exactly that shape.

Usage (CLI, for a CSV an aggregator already wrote):
  python3 assert_join_complete.py TABLE.csv --flag-field judged --value-field mean \
      [--value-field n] [--group-field battery] [--per-group-field interval] [--max-report 10]
Prints one `OK: ...` line and exits 0, or a `BLOCKED: ...` report and exits 1. Exit 2 is a usage
error (bad flags, unreadable file, a `--per-group-field` with no `--group-field`).
"""

import argparse
import csv
import math
import sys

# Flag tokens a CSV/JSON aggregator actually emits. Anything else is a violation, never a silent
# "not judged" — an unrecognized token means the column is not what the caller thinks it is, which is
# the same broken-join class this helper exists to catch.
_TRUE_TOKENS = {"true", "t", "yes", "y", "1"}
_FALSE_TOKENS = {"false", "f", "no", "n", "0", ""}

# Cap on how many offending rows the error message enumerates. The count is always exact; the
# enumeration is for the human reading the traceback, and a fully-blank join would otherwise print
# every row in the table.
DEFAULT_MAX_REPORT = 10


class JoinIncompleteError(Exception):
    """A row flagged as judged did not carry the numbers that flag promises."""


def _is_truthy_flag(value, row_index, flag_field):
    if value is None:
        return False
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return bool(value)
    token = str(value).strip().lower()
    if token in _TRUE_TOKENS:
        return True
    if token in _FALSE_TOKENS:
        return False
    raise JoinIncompleteError(
        f"row {row_index}: {flag_field}={value!r} is not a recognized true/false token — "
        f"the flag column is not what this assertion was pointed at"
    )


def _is_numeric(value):
    """True only for a real, finite number — a blank cell from a missed join is not one."""
    if value is None or isinstance(value, bool):
        return False
    if isinstance(value, (int, float)):
        return math.isfinite(value)
    try:
        return math.isfinite(float(str(value).strip()))
    except (TypeError, ValueError):
        return False


def assert_join_complete(
    rows,
    flag_field,
    value_fields,
    group_field=None,
    per_group_fields=(),
    max_report=DEFAULT_MAX_REPORT,
):
    """Raise `JoinIncompleteError` unless every judged row carries the numbers it claims.

    rows            — sequence of mappings (a `csv.DictReader` result works directly).
    flag_field      — the column marking a row as judged.
    value_fields    — columns required to be numeric on EVERY judged row.
    group_field     — the per-group key (e.g. `battery`); required if `per_group_fields` is used.
    per_group_fields— columns required within a group only when some judged row in that group has one.
    max_report      — how many offending rows to enumerate in the message (the count stays exact).
    """
    rows = list(rows)
    value_fields = list(value_fields)
    per_group_fields = list(per_group_fields)
    if not value_fields and not per_group_fields:
        raise ValueError("assert_join_complete: no value_fields or per_group_fields to check")
    if per_group_fields and not group_field:
        raise ValueError("assert_join_complete: per_group_fields requires group_field")
    if not rows:
        raise JoinIncompleteError(
            "the table is empty — an aggregation that produced no rows at all is a join/filter bug "
            "signal, not a finding"
        )

    judged = []
    for index, row in enumerate(rows):
        try:
            has_flag = flag_field in row
        except TypeError:  # not a mapping at all
            raise JoinIncompleteError(f"row {index}: expected a mapping, got {type(row).__name__}")
        if not has_flag:
            raise JoinIncompleteError(
                f"row {index}: no {flag_field!r} column — the rows are not the shape this assertion "
                f"was pointed at (a broken join often changes the shape too)"
            )
        if _is_truthy_flag(row[flag_field], index, flag_field):
            judged.append((index, row))

    # Nothing judged is legitimate (a spend tripwire may have skipped every battery, #728) — there is
    # no promise to check. Only a judged row makes a promise.
    if not judged:
        return

    # Derive each per-group field's requirement FROM THE DATA: a group where some judged row carries
    # the field promises it for all of that group's judged rows; a group where none do doesn't.
    required_in_group = {}
    for index, row in judged:
        key = row.get(group_field) if group_field else None
        bucket = required_in_group.setdefault(key, set())
        for field in per_group_fields:
            if _is_numeric(row.get(field)):
                bucket.add(field)

    violations = []
    for index, row in judged:
        key = row.get(group_field) if group_field else None
        expected = value_fields + [f for f in per_group_fields if f in required_in_group.get(key, ())]
        for field in expected:
            if not _is_numeric(row.get(field)):
                violations.append((index, key, field, row.get(field)))

    if violations:
        shown = violations[:max_report]
        detail = "; ".join(
            f"row {i}"
            + (f" [{group_field}={k!r}]" if group_field else "")
            + f" {f}={v!r}"
            for i, k, f, v in shown
        )
        elided = len(violations) - len(shown)
        raise JoinIncompleteError(
            f"{len(violations)} blank/non-numeric value(s) across {len(judged)} row(s) flagged "
            f"{flag_field}: {detail}" + (f"; +{elided} more" if elided else "")
            + " — a cell marked judged with no number means the join missed, not that the number "
            "vanished. Re-derive the join key against a hand-inspected row before trusting this table."
        )


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Assert every judged row in a CSV carries the numbers its flag promises."
    )
    parser.add_argument("table", help="path to the CSV the aggregator is about to write/ship")
    parser.add_argument("--flag-field", required=True, help="column marking a row as judged")
    parser.add_argument(
        "--value-field", action="append", default=[], dest="value_fields",
        help="column required to be numeric on EVERY judged row (repeatable)",
    )
    parser.add_argument("--group-field", default=None, help="per-group key, e.g. battery")
    parser.add_argument(
        "--per-group-field", action="append", default=[], dest="per_group_fields",
        help="column required only within a group that already demonstrates it (repeatable)",
    )
    parser.add_argument("--max-report", type=int, default=DEFAULT_MAX_REPORT)
    args = parser.parse_args(argv)

    if not args.value_fields and not args.per_group_fields:
        parser.error("pass at least one --value-field or --per-group-field")
    if args.per_group_fields and not args.group_field:
        parser.error("--per-group-field requires --group-field")

    try:
        with open(args.table, newline="", encoding="utf-8") as handle:
            rows = list(csv.DictReader(handle))
    except OSError as exc:
        print(f"BLOCKED: cannot read {args.table}: {exc}", file=sys.stderr)
        return 2

    try:
        assert_join_complete(
            rows,
            args.flag_field,
            args.value_fields,
            group_field=args.group_field,
            per_group_fields=args.per_group_fields,
            max_report=args.max_report,
        )
    except ValueError as exc:  # usage-shaped: nothing to check / per-group without group
        print(f"BLOCKED: {exc}", file=sys.stderr)
        return 2
    except JoinIncompleteError as exc:
        print(f"BLOCKED: {args.table}: {exc}", file=sys.stderr)
        return 1
    print(f"OK: {args.table}: every {args.flag_field} row carries its values ({len(rows)} row(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
