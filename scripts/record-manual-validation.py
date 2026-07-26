#!/usr/bin/env python3
import argparse
from datetime import date

from feature_docs import (
    CHECKLIST_PATH,
    EXPECTED_COLUMNS,
    TRACKER_PATH,
    read_tracker,
    render_checklist,
    write_tracker,
)
from feature_docs_validation import validate_checklist, validate_tracker


RESULT_STATUSES = {
    "pass": "Manual validation passed",
    "fail": "Manual validation failed",
    "blocked": "Manual validation blocked",
    "reset-pending": (
        "Partial automated evidence passed; manual UI validation still pending. "
        "Validate manually using the listed steps."
    ),
}


def append_note(existing, note):
    existing = (existing or "").strip()
    note = (note or "").strip()
    if not note:
        return existing
    if not existing or existing in {"None", "Not needed"}:
        return note
    return f"{existing} {note}"


def parse_args():
    parser = argparse.ArgumentParser(
        description=(
            "Record one manual validation result in docs/feature-status.csv and "
            "regenerate docs/manual-validation-checklist.md."
        )
    )
    parser.add_argument("--id", required=True, help="Story ID, for example US-001")
    parser.add_argument(
        "--result",
        required=True,
        choices=sorted(RESULT_STATUSES),
        help="Manual validation outcome to record",
    )
    parser.add_argument(
        "--notes",
        default="",
        help="Evidence, observed behavior, or reproduction details",
    )
    parser.add_argument(
        "--fix-status",
        default=None,
        help="Optional replacement value for the Fix status column",
    )
    parser.add_argument(
        "--retest-status",
        default=None,
        help="Optional replacement value for the Retest status column",
    )
    parser.add_argument(
        "--date",
        default=date.today().isoformat(),
        help="Validation date to include in generated status text",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Validate the requested update without writing files",
    )
    return parser.parse_args()


def update_row(row, args):
    dated_prefix = f"{args.date}: "
    notes = args.notes.strip()

    if args.result == "pass":
        row["Manual validation status"] = f"{RESULT_STATUSES[args.result]} on {args.date}."
        row["Verification status"] = append_note(
            row["Verification status"],
            f"Manual validation passed on {args.date}.",
        )
        row["Retest status"] = args.retest_status or append_note(
            row["Retest status"],
            f"Manual user-behavior retest passed on {args.date}.",
        )
        if notes:
            row["Test evidence"] = append_note(row["Test evidence"], dated_prefix + notes)
        if args.fix_status:
            row["Fix status"] = args.fix_status
        return

    if args.result == "fail":
        if not notes:
            raise ValueError("--notes is required when --result fail")
        row["Manual validation status"] = f"{RESULT_STATUSES[args.result]} on {args.date}."
        row["Verification status"] = append_note(
            row["Verification status"],
            f"Manual validation failed on {args.date}.",
        )
        row["Errors found"] = append_note(row["Errors found"], dated_prefix + notes)
        row["Fix status"] = args.fix_status or "Manual validation failure needs fix."
        row["Retest status"] = args.retest_status or "Retest pending after fix."
        return

    if args.result == "blocked":
        if not notes:
            raise ValueError("--notes is required when --result blocked")
        row["Manual validation status"] = (
            f"{RESULT_STATUSES[args.result]} on {args.date}: {notes}"
        )
        row["Verification status"] = append_note(
            row["Verification status"],
            f"Manual validation blocked on {args.date}.",
        )
        row["Errors found"] = append_note(row["Errors found"], dated_prefix + notes)
        row["Retest status"] = args.retest_status or "Manual retest blocked."
        if args.fix_status:
            row["Fix status"] = args.fix_status
        return

    if args.result == "reset-pending":
        row["Manual validation status"] = RESULT_STATUSES[args.result]
        row["Retest status"] = args.retest_status or append_note(
            row["Retest status"],
            f"Manual validation reset to pending on {args.date}.",
        )
        if notes:
            row["Errors found"] = append_note(row["Errors found"], dated_prefix + notes)
        if args.fix_status:
            row["Fix status"] = args.fix_status
        return

    raise ValueError(f"unsupported result: {args.result}")


def main():
    args = parse_args()
    rows = read_tracker()
    matches = [row for row in rows if row["ID"] == args.id]
    if not matches:
        raise SystemExit(f"unknown story ID: {args.id}")

    update_row(matches[0], args)

    validate_tracker(rows)
    rendered_checklist = render_checklist(rows)
    if args.dry_run:
        print(f"validated dry-run update for {args.id}")
        print(f"would update {TRACKER_PATH}")
        print(f"would regenerate {CHECKLIST_PATH}")
        return 0

    write_tracker(rows)
    CHECKLIST_PATH.write_text(rendered_checklist)
    validate_checklist(rows)

    print(f"updated {args.id} in {TRACKER_PATH}")
    print(f"regenerated {CHECKLIST_PATH}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
