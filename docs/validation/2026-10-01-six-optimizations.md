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

## 3. Background replacement recovery

Replace the unused background-change flag with failed-load state. Startup and
explicit config application retain failure state; identical paths retry on the
next config application, not on each frame. A failed replacement keeps the old
image, a successful replacement clears failure, and removal unloads it.

Validation: new native Debug damaged-PNG/repaired-same-path/removal test passed
(one function), with actual red/green snapshot pixels. Early fixture runs
failed because AppKit's setColor produced transparent PNG pixels; explicit RGBA
fixture bytes corrected this. Temporary diagnostic renderer edits were removed.
Core compilation, strict SwiftLint, Zig formatting and diff checks passed.

## 4. Bounded GPU snapshot readback

Pass the destination pixel limit through the internal snapshot bridge. Render
into a private full-resolution texture, then scale on the GPU into the shared
readback target in the same submission. Full-size callers retain their existing
path. CPU readback now contains only the requested pixels; the full GPU render
and synchronous snapshot completion still exist.

Validation: 71/71 targeted Zig tests, three native blending cases checking
bounded dimensions, aspect ratio, color, alpha, presentation revision and
post-close ownership, and the existing full-snapshot lifetime test passed.
Core/Metal compilation, strict SwiftLint without cache, formatting and diff
checks passed. The test CLI uses one selector at a time; both functions were
verified in separate runs. No frame-time or end-to-end speedup is claimed.

## 5. Accessibility document and metadata caching

Cache sparse emitted row spans with the content identity, independently of
viewport and selection. Metadata updates binary-search the relevant rows and
inspect cells only for partial row ranges. Text-changing updates replace the
index atomically after successful allocation. Swift keeps the same String,
NSString and line-start array while updating ranges/revisions; input queries
also reuse the NSString. Deferred whitespace and UTF-16 semantics are retained.

Validation: 81/81 targeted Zig tests passed, including indexed-versus-full
capture comparisons over wide/combining text, blank/soft-wrapped rows, reversed
rectangles and viewport moves; allocation failures, resize, history pruning,
alternate-screen changes and reset were checked. The native test performed 40
selection adjustments without increasing full-text capture count and verified
NSString identity, input ranges and line lookups; reset added exactly one
capture. All four AccessibilityTextTests passed. Core/native compilation,
strict SwiftLint, scope, formatting and diff checks passed.

The index costs memory proportional to emitted row spans. Content changes still
require full capture; a selection spanning the whole history visits its rows.
No wall-clock speedup is claimed. Initial Swift initializer compilation errors
and one rejected stale-core reuse were corrected before the successful runs.
