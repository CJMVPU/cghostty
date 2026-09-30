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
