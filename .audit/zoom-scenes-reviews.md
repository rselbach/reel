# Zoom scenes independent reviews

## Architecture judge

Three independent designs were compared before implementation.

| Criterion | Shared evaluator | Unified render plan | Custom playback container |
| --- | ---: | ---: | ---: |
| Exact interaction and edge-pinned crop | 5 | 4 | 3 |
| Source-time correctness through cuts | 5 | 2 | 4 |
| Preview and export consistency | 5 | 2 | 3 |
| Overlap ambiguity prevention | 5 | 4 | 4 |
| Small interface and reader load | 4 | 2 | 2 |
| Testability and feasibility | 4 | 2 | 2 |
| Total | 28 | 16 | 18 |

The shared evaluator was selected. The judge required zoom-only edits to count
as meaningful, direct source-time loading for the focal editor, source-time
preview evaluation, compacted export-time scheduling, and pixel-level fixtures.

## No-comments review

The reviewer found no MUST KILL comments, no correctness or style suppressions,
and no zoom-feature comments needing deletion. The existing `cursorTimeline`
documentation in `PostRecordingView.swift` was excluded as unrelated work.

## Final implementation review

The final pass kept the existing Delete-key behavior for selected clips while
adding the same behavior for selected zoom scenes. It also removed exact-frame
tolerance from the static image generator so arbitrary scene midpoints use the
nearest decodable frame.
