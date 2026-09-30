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

## UTF-16 preedit anchors

Preedit records each rendered scalar's source UTF-16 offset and the original
length, including ignored zero-width scalars. The caret helper uses the same
range/suffix clipping and wide-cell metadata as rendering. Half-surrogate
requests clamp to the scalar start; hidden prefixes clamp to the visible start.
The internal C API asks core for an already scaled point. Swift no longer
multiplies UTF-16 units by cell width. Invalid/unknown offsets keep the ordinary
IME point. This preserves the current preedit renderer's zero-width handling;
it does not introduce a new Unicode shaping policy.

Checks:
- Debug Zig `preedit`, `cell rebuild`: 77/77 tests, 72/72 build steps, exit 0.
  Covers Chinese, emoji/split surrogate, combining source offsets, invalid
  offsets and the exact renderer right-edge clipping helper.
- Pure Swift contracts: 8/8 tests, all three suites, exit 0.
- Debug core: 108/108 steps, exit 0.
- Native Debug: `SurfaceBridgeTests/compositionCaretUsesRenderedWidthAndSurrogateBoundaries()`
  and `nativeTextInputUsesDocumentUTF16RangesAndSafeCompositionAnchor()` each
  passed (2 functions/2 cases total, no skips). The first directly checks the
  core bridge at both 1x and 2x scale; the second checks AppKit substring,
  QuickLook fallback and unknown-range composition behavior.
- Focused SwiftLint strict/no-cache, scope/config bridge and diff check passed.

No system IME, real dictation or physical presentation-latency benchmark was run.
