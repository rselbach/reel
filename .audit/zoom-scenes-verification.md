# Zoom scenes verification

Date: 2026-09-02

## Full test suite

Command: `just test`

Result: exit 0. The final test summary was:

```text
Test Suite 'ZoomSceneTests' passed at 2026-09-02 19:42:16.654.
    Executed 18 tests, with 0 failures (0 unexpected) in 0.747 (0.748) seconds
Test Suite 'ReelPackageTests.xctest' passed at 2026-09-02 19:42:16.654.
    Executed 181 tests, with 0 failures (0 unexpected) in 1.766 (1.777) seconds
Test Suite 'All tests' passed at 2026-09-02 19:42:16.654.
    Executed 181 tests, with 0 failures (0 unexpected) in 1.766 (1.777) seconds
```

The zoom tests include deterministic pixel sampling before, inside, and after a
scene in both source-quality and 720p MP4 output.

## Production build

Command: `just build`

Result: exit 0. The final build summary was:

```text
swift build -c release
Building for production...
[3/4] Compiling Reel AboutView.swift
[4/5] Linking Reel
Build complete! (9.71s)
```

## Static checks

Strict Swift formatting passed for every zoom-related source and test file.
`git diff --check` also passed.

## Packaged UI check

The helper launched an unsigned disposable bundle for run
`20260902T234100Z-resize`, then a second bundle signed with the configured
Developer ID Application identity for run
`20260902T234500Z-resize-signed`. Signature validation and the helper's doctor
check passed. Computer Use still timed out while reading the signed app by its
full bundle path, bundle ID, and display name, so no UI action was attempted.
The helper stopped only the recorded processes and preserved both diagnostic
sets at:

```text
.build/verification-evidence/reel/20260902T234100Z-resize
.build/verification-evidence/reel/20260902T234500Z-resize-signed
```
