# Six follow-up optimizations

Baseline: `3e1bf6d4b`, cghostty 0.4.4. Each item is validated and committed separately.

## 1. Window frame traversal

Compute one sorted membership snapshot per frame and reuse its IDs for trace
selection and pane encoding. Non-frame trace-owner lookups use a minimum rather
than a complete sort. Only enabled tracing creates trace-owner wrappers.
Membership-token filtering, cross-window ownership and slot retention remain.

Validation: native Debug `panesShareClockCacheAndMoveWithoutLosingSession`
passed all six blending/latency cases; strict SwiftLint and diff checks passed.
This verifies rendering/lifetime behavior, not a measured frame-time speedup.
The first selector omitted parameter labels and executed zero tests; it is not
counted. The corrected `(blending:latency:)` selector ran one function / six
cases successfully.

## 2. Font configuration invalidation

A complete SharedGridSet key comparison balances the temporary reference and
skips publishing an unchanged grid. Cell-size/padding propagation remains.
Renderer config updates recreate the shaper and clear its cache only when the
ordered feature strings change; real grid changes retain cache invalidation.

Validation: 113/113 targeted Zig tests (font feature comparison and Key), native
Debug blendReloadAndResizeKeepActualTargetsAndSnapshotOwnership (one case),
core rebuild, Zig formatting and diff checks passed. No timing gain is claimed.
