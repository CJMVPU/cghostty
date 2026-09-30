# Refactoring contracts — 2026-09-30

Baseline: `69731055a339e63af81e2f1c7559fd04f99ef485` (`v0.4.2`, `main`).
Environment: Apple Silicon arm64, macOS 27.0.1, Xcode macOS 27 SDK,
repository-pinned Zig 0.16.0. The starting working tree was clean.
Five changes are committed separately and locally; no push was performed.

## Changes and contracts

1. `222a6323f`: SearchSession owns coalesced UI results. A separate renderer
   channel transfers retained snapshots and selected-match arenas, replacing
   superseded results without waiting for app or renderer queue capacity.
   Shutdown joins the worker before its dependencies are released. The app
   thread clears retired UI state; query/navigation ordering is unchanged.
2. `9cac8346b`: Reusable row transactions retain foreground/background data
   and upload versions until a replacement succeeds. Failures roll back and
   keep a full rebuild pending. Two automatic retries are permitted before
   waiting for another external update. This is bounded retry, not guaranteed
   recovery under persistent allocation failure.
3. `0f745fdb`: NSTextInputClient uses document-relative UTF-16 ranges from
   one immutable snapshot. Proposed substrings are clipped and expanded to
   composed-character boundaries, with actualRange reported. Out-of-document
   QuickLook requests fall back to the selected span. AppKit's single selection
   exposes the first rectangular span; accessibility retains all spans. Caret
   offsets are bounded by marked-text length; NSNotFound and document-history
   indices cannot move the IME/dictation anchor.
   Legacy viewport cell offsets and pixel geometry have separate names and
   contracts. Without a document-to-pixel map, characterIndex returns NSNotFound.
4. `d3e294e23`: Shared content/view identity excludes selection. Accessibility
   composes selection endpoints separately. Search, regex links, hover, render
   holds and image geometry use content/view keys; page addresses and serials
   are sampled under the terminal mutex. Selection-only render dirty state no
   longer forces viewport searches to restart. Existing mutation counters keep
   their names and continue to invalidate content despite consumed dirty bits.
5. This commit: C/Zig/Swift use named compositor flags with unchanged UInt32
   storage and bit values. WindowFrameTransaction names slot ownership:
   acquired, partial submission, final feedback, released. Aborted partial work
   drains before recycling; final feedback owns retirement even if it precedes
   presentation. The clear, pane and final GPU queue order is unchanged.

CAMetalDisplayLink and preferredFrameLatency remain as selected in the
2026-09-28 renderer validation. No presentation clock experiment was run.

## Checks actually run

| Stage | Outcome |
| --- | --- |
| Item 1 targeted Zig tests | 157/157 passed |
| Item 2 targeted Zig tests | 82/82 passed |
| Item 3 targeted Zig tests | 86/86 passed |
| Item 4 targeted Zig tests | 184/184 passed |
| Item 5 targeted Zig tests | 86/86 passed |
| Final combined Zig regressions | 226/226 passed, all 72 build steps succeeded |
| Embedded core Debug build | Passed after each of the five items |
| Native app/test target Debug build | Passed through the documented Nushell entry point |
| Native selected regressions | 33 functions / 56 expanded cases passed, no test skips |
| Pure Swift contracts | 8 tests in 3 suites passed; the partial-submission test exercised 3 arguments |
| Python scripts | 51 total, 49 passed, 2 skipped (fish prerequisite) |
| Whole-repository SwiftLint strict/no-cache | Passed, zero violations |
| Zig formatting, build.zig/build.zig.zon/src/pkg | Passed |
| Scope and native config bridge | Passed |
| Typed native bridge boundary | Passed, 134 UI/feature files |
| Swift 6 build settings | Passed, 9 configurations (configuration check) |
| Versions | Passed, Zig/dependencies/app/release notes |
| Localizations | Passed, 170 command strings / 3 languages / 510 translations |
| git diff --check | Passed |

Some Zig test logs include a `failed command` diagnostic alongside resource
metrics. In these runs the final build summaries report all steps/tests passed,
and each wrapper exited zero. The summaries and exit codes were checked.

The headless Swift runner uses the checked-in helper sources, checked-in
regression tests and actual C header. Its temporary SwiftPM module is compiled
with MainActor default isolation, complete strict concurrency, warnings as
errors, and macOS 27 deployment. It is a helper/ABI test, not a native app build.
Run it with:

```sh
python3 scripts/check-native-contracts.py
```

The final combined core command (with the pinned Zig directory in PATH) was:

```sh
python3 scripts/build.py test \
  -Dtest-filter=SearchSession -Dtest-filter=RenderSession \
  -Dtest-filter=terminal.search -Dtest-filter='search results' \
  -Dtest-filter='row transaction' -Dtest-filter='cell rebuild' \
  -Dtest-filter=Contents -Dtest-filter=accessibility \
  -Dtest-filter='input document' -Dtest-filter='content view identity' \
  -Dtest-filter=LinkHitCache -Dtest-filter='link cache' \
  -Dtest-filter=RenderHold -Dtest-filter=renderer.image \
  -Dtest-filter='compositor result' -Dtest-filter=terminal.render --summary all
```

## Native validation after tool approval

The user approved installation after the initial checks. Homebrew's official
`homebrew/core` nushell formula installed version 0.116.0; no automatic
Homebrew update or other formula installation was requested. Native validation
then used the documented entry point, with the archive checked against current
core source inputs:

```sh
python3 scripts/build.py native --configuration Debug --action test --skip-core \
  --only-testing 'GhosttyTests/SurfaceBridgeTests/nativeTextInputUsesDocumentUTF16RangesAndSafeCompositionAnchor()'
```

The first native build found an existing test still using the renamed
TextSnapshot.range property. It was corrected to viewportCellRange, and a
direct NSTextInputClient bridge test was added. Both changes and the composition
anchor boundary regression are folded into the dedicated third commit.

InputTextTests (4 functions), the direct native text input test (1 function),
and the 20 selectors listed below all passed: 33 functions / 56 expanded cases
in total. Function selectors must include Swift Testing's parentheses and
argument labels. One initial selector omitted parentheses and selected zero
functions; that run was detected, rerun correctly and excluded from the count.

| Native selector | Functions | Expanded cases |
| --- | --- | --- |
| `CompositorResultTests` | 1 | 1 |
| `WindowFrameTransactionTests` | 3 | 5 |
| `SurfaceViewAppKitTests` | 4 | 11 |
| `AccessibilityTextTests` | 4 | 4 |
| `SurfaceBridgeTests/selectionSnapshotOutlivesCoreMutationAndView()` | 1 | 1 |
| `SurfaceBridgeTests/accessibilitySnapshotKeepsTextAndUTF16SelectionTogether()` | 1 | 1 |
| `SurfaceBridgeTests/searchRefreshesFromPTYChangesAndAfterVisibilityRestoration(delayedStartup:)` | 1 | 2 |
| `SurfaceBridgeTests/repeatedKeyAndPreeditBridgeReachPTY()` | 1 | 1 |
| `SurfaceBridgeTests/stateCallbacksReachOnlyTheirTargetAndPreserveQueueOrder()` | 1 | 1 |
| `PresentationStateTests/activeSearchReleasesWithSurfaceAfterReplacingLongQueries()` | 1 | 1 |
| `PresentationStateTests/renderSessionReleasesAfterQueuedFontAndDisplayChanges()` | 1 | 1 |
| `PresentationStateTests/typedSearchBridgeClearsAndEndsSearch(query:)` | 1 | 3 |
| `WindowCompositorTests/panesShareClockCacheAndMoveWithoutLosingSession(blending:latency:)` | 1 | 6 |
| `WindowCompositorTests/closeReleasesSessionEvenWhileLayerRemainsRetained()` | 1 | 1 |
| `WindowCompositorTests/contentUpdatesCoalesceUntilWindowClockResumes()` | 1 | 1 |
| `WindowCompositorTests/membershipAndCloseDoNotWaitForFramePreparation()` | 1 | 1 |
| `WindowCompositorTests/sharedTextureSnapshotPreservesAlphaAndOutlivesSession()` | 1 | 1 |
| `WindowCompositorTests/animationDeadlinesKeepWorkingWithoutNewOutput(animation:)` | 1 | 2 |
| `WindowCompositorTests/finalCompositionAnimatesWithoutRepaintingContent(animation:blending:)` | 1 | 6 |
| `WindowCompositorTests/missedDeadlineDoesNotCreateMoreVisualWork()` | 1 | 1 |

Native tests used the separate Debug app and managed result bundles under
`$TMPDIR/cghostty-tests-b569378685f8/ManagedTestResults`. The build wrapper retains
only its configured recent result bundles. It did not terminate or replace the
user's running `/Applications/cghostty.app`; the original process was confirmed
still running after the tests.

The Metal cases actually ran, including all three blending modes and both
latency values, pane movement/close, held-clock output/search bursts, independent
snapshot ownership, membership while preparing, cursor/Kitty animation deadlines,
and composition without content repaint. Performance probes were excluded.

## Not run and remaining acceptance

The full Zig suite, full native suite, Release/ReleaseLocal native builds,
desktop UI test target and foreground latency benchmarks were not run. The
combined core suite covers affected modules and render dirty/delta ownership;
native runs cover the selected integration cases above.

AppKit methods and preedit were exercised directly, but manual IME/dead-key,
real dictation and system QuickLook interactions remain unverified. Allocation
failure and partial row rollback were injected in headless Zig tests; real GPU
encoder/completion failure and persistent memory pressure were not induced.
Frame transaction abort branches were tested by the pure helper tests. Passing
functional Metal tests are not a physical latency measurement, and no performance
improvement or regression is inferred from them.
