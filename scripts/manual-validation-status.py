#!/usr/bin/env python3
import argparse
from collections import Counter

from feature_docs import AUTOMATION_ONLY_STATUS, clean, read_tracker, split_steps


PENDING_MARKER = "manual ui validation still pending"


def status_bucket(status):
    if status == AUTOMATION_ONLY_STATUS:
        return "automation_only"
    lowered = status.lower()
    if lowered.startswith("manual validation passed"):
        return "passed"
    if lowered.startswith("manual validation failed"):
        return "failed"
    if lowered.startswith("manual validation blocked"):
        return "blocked"
    if PENDING_MARKER in lowered:
        return "pending"
    return "other"


def parse_args():
    parser = argparse.ArgumentParser(
        description="Summarize manual validation progress from docs/feature-status.csv."
    )
    parser.add_argument(
        "--pending",
        action="store_true",
        help="List pending manual validation stories.",
    )
    parser.add_argument(
        "--failed",
        action="store_true",
        help="List failed manual validation stories.",
    )
    parser.add_argument(
        "--blocked",
        action="store_true",
        help="List blocked manual validation stories.",
    )
    parser.add_argument(
        "--steps",
        action="store_true",
        help="Include manual steps when listing stories.",
    )
    return parser.parse_args()


def print_rows(rows, include_steps):
    for row in rows:
        print(f"{row['ID']}: {row['Feature']}")
        print(f"  story: {clean(row['User story'])}")
        print(f"  status: {clean(row['Manual validation status'])}")
        if include_steps:
            print("  steps:")
            for index, step in enumerate(split_steps(row["Manual validation steps"]), 1):
                print(f"    {index}. {clean(step)}")


def main():
    args = parse_args()
    rows = read_tracker()
    buckets = Counter(status_bucket(row["Manual validation status"]) for row in rows)

    print(f"total={len(rows)}")
    for bucket in [
        "pending",
        "passed",
        "failed",
        "blocked",
        "automation_only",
        "other",
    ]:
        print(f"{bucket}={buckets[bucket]}")

    filters = []
    if args.pending:
        filters.append("pending")
    if args.failed:
        filters.append("failed")
    if args.blocked:
        filters.append("blocked")

    if filters:
        selected = [
            row
            for row in rows
            if status_bucket(row["Manual validation status"]) in filters
        ]
        print("")
        print_rows(selected, args.steps)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
