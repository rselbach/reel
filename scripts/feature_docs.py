import csv
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TRACKER_PATH = ROOT / "docs" / "feature-status.csv"
CHECKLIST_PATH = ROOT / "docs" / "manual-validation-checklist.md"

EXPECTED_COLUMNS = [
    "ID",
    "Feature",
    "User story",
    "Expected behavior based on code",
    "Code evidence",
    "Verification status",
    "Test evidence",
    "Errors found",
    "Fix status",
    "Retest status",
    "Manual validation steps",
    "Manual validation status",
]

AUTOMATION_ONLY_STATUS = "Not required beyond recorded automated evidence"
GENERATED_DATE = "2026-06-21"
UI_AUTOMATION_NOTE = (
    "a bounded System Events probe on 2026-06-21 returned "
    "`UI elements enabled = false`"
)


def clean(value):
    return " ".join((value or "").replace("\r\n", "\n").replace("\r", "\n").split())


def split_steps(value):
    raw = (value or "").strip()
    if not raw:
        return ["No manual steps recorded in the canonical tracker."]

    parts = [
        part.strip()
        for part in raw.replace("\r\n", "\n").replace("\r", "\n").split(";")
        if part.strip()
    ]
    return parts or [clean(raw)]


def read_tracker():
    if not TRACKER_PATH.exists():
        raise ValueError(f"missing {TRACKER_PATH.relative_to(ROOT)}")

    with TRACKER_PATH.open(newline="") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames != EXPECTED_COLUMNS:
            raise ValueError(
                "unexpected CSV columns: "
                + ", ".join(reader.fieldnames or [])
            )
        rows = list(reader)

    if not rows:
        raise ValueError("feature tracker has no user-story rows")

    return rows


def write_tracker(rows):
    TRACKER_PATH.parent.mkdir(parents=True, exist_ok=True)
    with TRACKER_PATH.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=EXPECTED_COLUMNS)
        writer.writeheader()
        writer.writerows(rows)


def manual_required_rows(rows):
    return [
        row
        for row in rows
        if row["Manual validation status"] != AUTOMATION_ONLY_STATUS
    ]


def automation_only_rows(rows):
    return [
        row
        for row in rows
        if row["Manual validation status"] == AUTOMATION_ONLY_STATUS
    ]


def render_checklist(rows):
    manual_required = manual_required_rows(rows)
    automation_only = automation_only_rows(rows)

    lines = [
        "# Reel Manual Validation Checklist",
        "",
        "Source of truth: `docs/feature-status.csv`.",
        "",
        (
            f"Generated from the canonical tracker on {GENERATED_DATE}. "
            "This checklist is a companion artifact for executing the remaining "
            "manual validation pass; update the CSV after validation."
        ),
        "",
        (
            "Environment note: a bounded System Events probe on 2026-06-21 "
            "returned `UI elements enabled = false`, so this environment cannot "
            "inspect the menu bar, permission prompts, device pickers, or recording UI."
        ),
        "",
        f"Manual validation required: {len(manual_required)} stories.",
        f"No further manual validation required: {len(automation_only)} stories.",
        "",
        "## Recommended Order",
        "",
        "1. Permissions and device-dependent setup.",
        "2. Recording start, countdown, active recording, stop, and termination flows.",
        "3. Post-recording preview, trim, export, reveal, and delete flows.",
        "4. Settings, hotkeys, launch at login, updates, and menu/about affordances.",
        "5. Release packaging checks that are already covered by automation.",
        "",
        "# Manual Validation Required",
        "",
    ]

    for row in manual_required:
        lines.extend(
            [
                f"## {row['ID']} - {clean(row['Feature'])}",
                "",
                f"User story: {clean(row['User story'])}",
                "",
                (
                    "Expected behavior: "
                    f"{clean(row['Expected behavior based on code'])}"
                ),
                "",
                "Manual steps:",
                "",
            ]
        )
        for index, step in enumerate(split_steps(row["Manual validation steps"]), 1):
            lines.append(f"{index}. {clean(step)}")

        lines.extend(
            [
                "",
                f"Current status: {clean(row['Manual validation status'])}",
                "",
                "Result: [ ] Pass  [ ] Fail  [ ] Blocked",
                "",
                "Notes:",
                "",
            ]
        )

    lines.extend(["# No Further Manual Validation Required", ""])
    for row in automation_only:
        lines.extend(
            [
                f"## {row['ID']} - {clean(row['Feature'])}",
                "",
                f"User story: {clean(row['User story'])}",
                "",
                f"Automated evidence: {clean(row['Test evidence'])}",
                "",
                f"Current status: {clean(row['Manual validation status'])}",
                "",
            ]
        )

    return "\n".join(lines).rstrip() + "\n"
