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
