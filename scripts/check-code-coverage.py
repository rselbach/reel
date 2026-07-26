#!/usr/bin/env python3
import argparse
import json
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOT = ROOT / "Sources"
DEFAULT_MINIMUM = 13.0


def parse_args():
    parser = argparse.ArgumentParser(
        description="Check aggregate executable-source line coverage."
    )
    parser.add_argument(
        "--minimum",
        type=float,
        default=DEFAULT_MINIMUM,
        help=f"minimum source line coverage percentage (default: {DEFAULT_MINIMUM})",
    )
    parser.add_argument(
        "--coverage-json",
        type=Path,
        help="LLVM coverage JSON; defaults to SwiftPM's most recent report",
    )
    return parser.parse_args()


def default_coverage_path():
    result = subprocess.run(
        ["swift", "test", "--show-codecov-path"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    return Path(result.stdout.strip())


def source_line_totals(coverage_path):
    with coverage_path.open() as handle:
        report = json.load(handle)

    count = 0
    covered = 0
    for data in report.get("data", []):
        for file_report in data.get("files", []):
            filename = Path(file_report["filename"]).resolve()
            if not filename.is_relative_to(SOURCE_ROOT):
                continue
            lines = file_report["summary"]["lines"]
            count += int(lines["count"])
            covered += int(lines["covered"])

    if count <= 0:
        raise ValueError("coverage report contains no executable source lines")
    return count, covered


def main():
    args = parse_args()
    if not 0 <= args.minimum <= 100:
        print("coverage check failed: --minimum must be between 0 and 100", file=sys.stderr)
        return 2

    try:
        coverage_path = args.coverage_json or default_coverage_path()
        count, covered = source_line_totals(coverage_path)
    except (OSError, KeyError, ValueError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        print(f"coverage check failed: {error}", file=sys.stderr)
        return 2

    percentage = covered / count * 100
    print(
        f"source_line_coverage={percentage:.2f}% "
        f"({covered}/{count}); minimum={args.minimum:.2f}%"
    )
    if percentage < args.minimum:
        print("coverage check failed: source line coverage is below the minimum", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
