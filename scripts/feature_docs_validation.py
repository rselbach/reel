import re

from feature_docs import (
    CHECKLIST_PATH,
    EXPECTED_COLUMNS,
    ROOT,
    automation_only_rows,
    manual_required_rows,
    render_checklist,
)


def validate_tracker(rows):
    ids = [row["ID"] for row in rows]
    expected_ids = [f"US-{index:03d}" for index in range(1, len(rows) + 1)]
    if ids != expected_ids:
        raise ValueError("story IDs must be contiguous and ordered from US-001")

    duplicates = sorted({story_id for story_id in ids if ids.count(story_id) > 1})
    if duplicates:
        raise ValueError(f"duplicate story IDs: {', '.join(duplicates)}")

    missing_required = []
    for row in rows:
        for column in EXPECTED_COLUMNS:
            if not row[column].strip():
                missing_required.append(f"{row['ID']}:{column}")
    if missing_required:
        raise ValueError("blank required fields: " + ", ".join(missing_required))

    missing_manual_steps = [
        row["ID"] for row in rows if not row["Manual validation steps"].strip()
    ]
    if missing_manual_steps:
        raise ValueError(
            "stories missing manual validation steps: "
            + ", ".join(missing_manual_steps)
        )

    missing_evidence_paths = []
    for row in rows:
        for evidence in row["Code evidence"].split(";"):
            path_text = evidence.strip().split(maxsplit=1)[0]
            matches = list(ROOT.glob(path_text))
            if not matches:
                missing_evidence_paths.append(f"{row['ID']}:{path_text}")
    if missing_evidence_paths:
        raise ValueError(
            "code evidence references missing paths: "
            + ", ".join(missing_evidence_paths)
        )


def validate_checklist(rows):
    if not CHECKLIST_PATH.exists():
        raise ValueError(f"missing {CHECKLIST_PATH.relative_to(ROOT)}")

    checklist = CHECKLIST_PATH.read_text()
    ids = re.findall(r"^## (US-\d{3}) - ", checklist, flags=re.MULTILINE)
    tracker_ids = [row["ID"] for row in rows]

    missing = sorted(set(tracker_ids) - set(ids))
    extra = sorted(set(ids) - set(tracker_ids))
    duplicates = sorted({story_id for story_id in ids if ids.count(story_id) > 1})

    if missing:
        raise ValueError("checklist missing story IDs: " + ", ".join(missing))
    if extra:
        raise ValueError("checklist has unknown story IDs: " + ", ".join(extra))
    if duplicates:
        raise ValueError("checklist has duplicate story IDs: " + ", ".join(duplicates))
    if len(ids) != len(rows):
        raise ValueError(
            f"checklist story count {len(ids)} does not match tracker count {len(rows)}"
        )

    manual_required = manual_required_rows(rows)
    automation_only = automation_only_rows(rows)

    expected_manual_line = f"Manual validation required: {len(manual_required)} stories."
    expected_automation_line = (
        f"No further manual validation required: {len(automation_only)} stories."
    )
    if expected_manual_line not in checklist:
        raise ValueError("checklist manual-validation-required count is stale")
    if expected_automation_line not in checklist:
        raise ValueError("checklist automation-only count is stale")

    for row in rows:
        heading = f"## {row['ID']} - {row['Feature']}"
        if heading not in checklist:
            raise ValueError(f"checklist missing heading: {heading}")

    if checklist != render_checklist(rows):
        raise ValueError(
            "checklist content is stale; run `just generate-checklist`"
        )

    return len(manual_required), len(automation_only)
