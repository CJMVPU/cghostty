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
