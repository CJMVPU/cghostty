# Follow-up correctness and optimization validation

Baseline: `26a1434a94b2e734e982c1b491d598330f9583e3`, cghostty 0.4.3 / build 33.
Apple Silicon, macOS 27, Xcode macOS 27 SDK, pinned Zig 0.16.0.
Each implemented item has a separate local commit. No push or app replacement.

## Frame retries

External worker/search updates replenish a three-attempt budget (initial attempt
plus two retries). Retained failed requests do not replenish it. Preparation and
drawing consume the same budget under the update gate, and failed diagnostic
readback does not request another window frame. Early update failures retain a
full rebuild requirement even if dirty bits were consumed. The display clock,
presentation timing and GPU queue order are unchanged.

Checks:
- Debug Zig: 81/81 tests, 72/72 build steps, exit 0. Filters: `cell rebuild`,
  `row transaction`, `Contents`.
- Allocation failure tests call actual RenderState.beginUpdate, Preedit.clone
  and Contents.resize with a failing allocator; each exhausts three attempts,
  refuses a fourth, retains published background/version data, and recovers
  when a new external request arrives. Row transaction tests retain partial-row
  rollback coverage. These are component fault tests, not GPU fault injection.
- Debug core: 108/108 build steps, exit 0.
- Native Debug via `scripts/build.py native --action test --skip-core`:
  `GhosttyTests/WindowCompositorTests/contentUpdatesCoalesceUntilWindowClockResumes()`
  passed, 1 function/1 case, no skips; native app/test targets compiled.
- `git diff --check` passed.

Real GPU allocation/encoder failure and sustained system memory pressure were
not induced. The native regression is a normal-path scheduling check.
