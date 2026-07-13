# Reel Manual Validation Runbook

Source of truth: `docs/feature-status.csv`.

Use this runbook for the remaining manual UI/device/permission validation pass. The checklist in `docs/manual-validation-checklist.md` is generated from the CSV and is only a companion view.

## Before Testing

1. Start from a clean worktree or intentionally note any local changes.
2. Build the app bundle:
   ```bash
   just build-app
   ```
3. Verify the tracker and checklist agree:
   ```bash
   just validate-docs
   ```
4. Review current manual status:
   ```bash
   just manual-status
   just manual-status --pending --steps
   ```

## Testing One Story

1. Pick the next pending story from:
   ```bash
   just manual-status --pending --steps
   ```
2. Execute the listed manual steps against `.build/Reel.app`.
3. Record the outcome in the canonical CSV.

For a pass:
```bash
just record-manual US-001 pass "Observed the menu-bar item and no main app window."
```

For a failure:
```bash
just record-manual US-001 fail "Expected only a menu-bar item, but a main app window opened on launch."
```

For an external blocker:
```bash
just record-manual US-002 blocked "Need a macOS account where Screen Recording permission can be reset."
```

For a dry run before writing:
```bash
just record-manual-dry-run US-001 pass "Observed expected behavior."
```

Each write updates `docs/feature-status.csv` and regenerates `docs/manual-validation-checklist.md`.

## After Recording Results

Run:
```bash
just validate-docs
just manual-status
```

If a story failed, fix the logistical or UX issue in code, then run the relevant automated checks and manually retest the same story. Record the post-fix retest with `just record-manual`.

## Recommended Manual Order

1. Permissions and launch state: `US-001`, `US-002`, `US-003`, `US-029`.
2. Source selection and recording lifecycle: `US-004` through `US-013`.
3. Preview and export flows: `US-014`, `US-015`, `US-016`.
4. Settings and persistence: `US-017`, `US-018`, `US-020` through `US-024`, `US-030`.
5. About, update, and provenance affordances: `US-025`, `US-026`, `US-031`.
6. Camera overlay drag behavior: `US-028`.

## Exit Criteria

The active QA goal is complete only when:

1. `just manual-status` reports no pending, failed, blocked, or other manual statuses.
2. Every failed logistical or UX behavior has been fixed.
3. Every fixed behavior has been retested and recorded in `docs/feature-status.csv`.
4. `just validate-docs` passes.
5. The automated suite and package checks pass:
   ```bash
   swift test
   swift build
   just build-app
   just dmg
   hdiutil verify .build/Reel.dmg
   ```
