# Native test and render-target simplification

Baseline: 4eba4807750c627f5fb6dc10e96b944042a7eda4, cghostty 0.4.3/build 33.
No intervening local changes were present. Each item is committed separately.

## Shared wait and timeout diagnostics

NativeTestWait evaluates the original predicate before enforcing the deadline
and sleeping. Surface bridge waits retain 5 seconds/10 ms; compositor waits
retain 10 seconds/5 ms. All 45 compositor predicate bodies were compared with
the baseline and are unchanged. Predicate errors and task cancellation propagate.
A timeout reports stage, caller file/line and lazily collected state: applicable
text-ready flags, bounded output suffixes, grid/exited/revision/view state,
compositor idle, pane count and submission/completion/presentation statistics.
No production source, renderer timing or test expectation changed.

Checks (Debug native, each selector invoked separately through build.py/Nushell):
- NativeTestWaitTests: 5 functions/5 cases passed (timeout contents and lazy
  diagnostics, readiness before deadline, later readiness, predicate errors,
  cancellation).
- SurfaceBridgeTests/nativeTextInputUsesDocumentUTF16RangesAndSafeCompositionAnchor:
  1 function/1 case passed.
- SurfaceBridgeTests/selectionOnlyUpdateRepaintsNativeHighlight:
  1 function/1 case passed, actual Metal readback.
- WindowCompositorTests/finalCompositionAnimatesWithoutRepaintingContent:
  1 function/6 cases passed across cursor/scroll and all three blend modes.
- SwiftLint strict/no-cache and git diff check passed.

The first batched command repeated --only-testing, but Nushell accepts one
selector and ran only the last (animation). The helper/text/frame tests were
then run separately and verified in their own logs; no assumed runs are counted.
These passing runs do not resolve the previously recorded intermittent
cursor/native timeout. No timeout was extended and no UI latency benchmark ran.

## Explicit draw targets

Removed the per-slot undefined-texture Target, initTarget/surfaceSize wrappers,
placeholder resize/deinit and temporary target replacement/restoration. Each
caller passes the actual window or snapshot target directly into encoding.
Per-slot upload_size/upload_config_modified stamps preserve the previous
foreground invalidation on dimension/config changes. Snapshot allocation and
owned-texture release, Metal retention/residency and queue order are unchanged.
The borrowed target is no longer stored in the mutable CompositorPane context.

Checks:
- Debug core: 108/108 steps passed.
- Debug CellUpload/RowUpload: 76/76 tests, 72/72 steps passed.
- Native panesShareClockCacheAndMoveWithoutLosingSession: 1 function/6 cases
  passed (three blending modes x two latency settings; includes resize, actual
  pixel readback, snapshots, pane movement and surviving-window behavior).
- Native sharedTextureSnapshotPreservesAlphaAndOutlivesSession: 1/1 passed.
- New native blendReloadAndResizeKeepActualTargetsAndSnapshotOwnership: 1/1
  passed; live linear/linear-corrected/native config changes, an intervening
  resize, actual red-pixel readback, snapshot dimensions, and unchanged display
  revision during snapshot creation.
- SwiftLint, Zig formatting, scope/config bridge and diff checks passed.

No throughput/latency improvement is claimed; this reduces target ownership
states and removes a placeholder lifecycle. GPU faults were not injected.

## Test-only compositor state

Audit confirmed Pane.initialized is read only by the CGHOSTTY_TESTING readback
path, and encodingLock coordinates that readback with the serial window worker.
Both fields and their production-frame operations are now guarded by the same
testing condition. Production no longer publishes test initialization state.
Membership tokens/filtering, requested/active compositor gates, slot semaphores,
GPU feedback, in-flight waits and retirement/drain paths remain in production.

Checks:
- Production-branch Debug native build passed, with no CGHOSTTY_TESTING define,
  in /tmp/cghostty-simplification-production. This bundle was not launched or
  installed. This is a production-condition compile, not a Release build.
- Testing-branch Debug native checks passed, each selector separately:
  panesShareClockCacheAndMoveWithoutLosingSession: 6 expanded cases;
  closeReleasesSessionEvenWhileLayerRemainsRetained: 1 case;
  sharedTextureSnapshotPreservesAlphaAndOutlivesSession: 1 case;
  membershipAndCloseDoNotWaitForFramePreparation: 1 case;
  blendReloadAndResizeKeepActualTargetsAndSnapshotOwnership: 1 case;
  finalCompositionAnimatesWithoutRepaintingContent: 6 expanded cases.
- An initially mistyped handoff selector executed zero tests and is excluded
  from counts. The correct selector above was run and passed.
- Whole-repository SwiftLint strict/no-cache, scope/config bridge, Swift 6
  settings (9 configurations), app/dependency versions and diff checks passed.

Across the three items, 13 unique native functions / 23 expanded cases passed;
reruns are not added to that total. No GPU capability skips occurred. Core
validation was targeted (108 build steps, 76 upload tests), not the full Zig
suite. Full native/Release/UI suites, system IME, real GPU fault injection,
foreground latency and throughput benchmarks were not run. The prior isolated
cursor/native timeout remains unexplained; this work improves diagnostics and
passing reruns do not prove it fixed. No timing or speedup claim is made.
No push, tag, release, deployment or running-app replacement was performed.
