#!/usr/bin/env python3
import sys
from feature_docs import read_tracker
from feature_docs_validation import validate_checklist, validate_tracker


def fail(message):
    print(f"feature docs validation failed: {message}", file=sys.stderr)
    return 1


def main():
    try:
        rows = read_tracker()
        validate_tracker(rows)
        manual_required, automation_only = validate_checklist(rows)
    except ValueError as error:
        return fail(str(error))

    print("feature docs validation passed")
    print(f"tracker_rows={len(rows)}")
    print(f"manual_required={manual_required}")
    print(f"automation_only={automation_only}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
