#!/usr/bin/env python3
from feature_docs import CHECKLIST_PATH, read_tracker, render_checklist


def main():
    rows = read_tracker()
    CHECKLIST_PATH.write_text(render_checklist(rows))
    print(f"wrote {CHECKLIST_PATH}")
    print(f"tracker_rows={len(rows)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
