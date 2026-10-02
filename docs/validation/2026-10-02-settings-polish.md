# Settings polish and persistence validation

## Changes

- Font fallback availability updates immediately when the primary family changes.
- Core diagnostics carry field, detail, source and line through the internal C bridge.
  Legacy formatted diagnostics remain available for logging. Invalid saves retain
  field diagnostics so their controls continue to show the error.
- Restart status compares resolved saved values with the persisted settings used
  at startup, before temporary CLI overrides. Returning to that baseline clears it.
- Settings window reads, writes, resets and file-lock waits use background tasks.
  Core configuration handles remain on MainActor. Saves recheck the revision under
  the lock, and edits/close are guarded while a save is in flight.
- Record reads allocate at most 16 MiB plus one byte before rejecting oversized files.
- Save/restart status shares the Save button row. Editable controls have no focus
  ring; sidebar selection uses text color. Rows have separators and reduced spacing.
- The terminal titlebar default is `macos-titlebar-style = hidden`, preserving the
  frame and rounded corners. Explicit stored titlebar settings continue to apply.
- Native test selections can be repeated through `scripts/build.py native` or
  comma separated through `macos/build.nu`. The result bundle must show actual
  executed tests for every selection. Empty and fully skipped runs fail.

## Completed checks

- Core Debug build: passed.
- Targeted Zig test `structured diagnostics preserve keys and file locations`:
  passed, including allocation checks.
- Native SettingsTests, ConfigTests, FixedWindowSizeTests and WindowRegistryTests:
  89 tests passed, zero skipped. Actual suite counts: 35, 39, 4 and 11.
- After final bridge/layout cleanup, SettingsTests and ConfigTests rerun:
  74 tests passed, zero skipped, both selections verified from xcresult.
- Python script suite: 56 tests passed.
- Scope and typed bridge checks: passed.
- Version consistency: passed (0.4.7, build 37).
- SwiftLint strict for changed Swift sources/tests and `git diff --check`: passed.
- Negative native selection `GhosttyTests/NoSuchSettingsTest`: Xcode reported
  success with zero tests; the managed entrypoint correctly returned exit 1.
  Such a run cannot replace the retained successful result bundle.

## Responsiveness measurement

Debug build on this Mac, 1,000 environment entries, ten evaluations including
formatted display values: median 9.63 ms, maximum 9.97 ms. This is a local sample,
not a release benchmark or a bound for every possible configuration. Parsing stays
on MainActor; disk I/O and lock acquisition are isolated from it.

## Desktop verification completed after unlocking

On 2026-10-02, rebuilt Debug 0.4.8/build 38 at application commit `117c4b052`.
The final complete Settings UI run passed all four tests, with zero failures and
zero skips; the managed entrypoint confirmed four executed tests from xcresult.

- Font choice buttons, bundled preset and fallback families survive restart.
- Invalid values prevent saving; valid values persist across restart. Closing with
  unsaved edits can save, close and reopen the settings window with the saved value.
- Environment entries, duration/limit controls, flags and font/style editors retain
  their values; theme and color controls render correctly.
- Theme selection and Control+Shift+9 shortcut recording work.

Two test-infrastructure issues were found and corrected during verification:

1. After the close confirmation, the test must reactivate the app before sending
   Command+Comma. The initial attempt failed to reopen it; the focused retry and
   final complete run passed with explicit activation.
2. XCTest accepts a method selector without `()`, but xcresult includes `()`.
   The verification script now accepts both exact forms while still rejecting
   absent tests and partial names. All 57 Python tests passed.

No application implementation change was needed for these corrections. Screenshot
inspection confirmed the shared Save/status row, sidebar text-only selection,
row separators, compact layout and no blue focus outline on editable fields.
The earlier programmatic AppKit checks also covered minimum-width layout and
input focus-ring settings across every settings category.

Final result bundle:
`run-1790916938967497000-d68be021ebcb47389e49ee25a2bd1853.xcresult`

Local log: `/tmp/cghostty-0.4.8-ui-final.log`.
Exported screenshots: `/tmp/cghostty-0.4.8-ui-final-attachments/`.
These are local temporary verification artifacts, not release packages.

```sh
PATH="$PWD/.tools/zig-aarch64-macos-0.16.0:$PATH" \
  python3 scripts/build.py native --action test --ui-tests \
  --only-testing GhosttyUITests/GhosttySettingsUITests
```

## Release preparation

The implementation checks above used 0.4.7/build 37 before the metadata bump.
Release metadata is now 0.4.8/build 38, with synchronized Debug, ReleaseLocal and
Release app configurations and updated release notes. Version, project plist,
Swift 6 configuration and whitespace checks passed. A 0.4.8 Debug binary was subsequently built and its version verified for the UI
run above. No ReleaseLocal package was created or installed.
