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

## Empty input-selection queries (measured, bounded change)

Dataset: 80x24 terminal, 10,000 or 30,000 repetitions of `row abc 中🙂 é` plus
newline, 128 MiB history allowance; retained rows 10,001/30,001. Real Terminal
printing handles grapheme storage growth. One warmup capture and five timed
captures; ReleaseFast test module and build options, testing allocator. No GUI,
PTY contention, Swift conversion or presentation latency is measured. The
capture interval includes serialization while holding an uncontended local
terminal mutex. Its duration therefore approximates core lock-held work, not
contended lock wait time.

| History | Copied text bytes/query | Median | Min–max |
| --- | --- | --- | --- |
| 10,000 lines | 199,999 | 1.543 ms | 1.527–1.705 ms |
| 30,000 lines | 599,999 | 4.261 ms | 3.967–4.369 ms |

The ordinary no-selection input query now uses existing Surface.hasSelection
and returns NSNotFound before requesting text. Native counters confirmed 100
queries made zero captures, then a real selection returned the correct UTF-16
range. Text copied on this path is zero. A separate 10,000-iteration headless
mutex/selection predicate sample was ~5 ns/query; this is **not** end-to-end
NSTextInputClient time and excludes C/Swift overhead. Selected-text queries,
accessibility clients and substring requests still use full immutable snapshots.
No incremental history cache or extra ownership layer was added.

Reproduce the two independent headless probes:

```sh
python3 scripts/build.py test -Doptimize=ReleaseFast -Dtest-optimize=ReleaseFast \
  -Dtest-filter='optimization probe' --summary all
```

Tests normally remain Debug. `-Doptimize` alone does not change the test module;
`-Dtest-optimize` makes this choice explicit. Debug skips timing-only probes.
The earlier Screen.testWriteString fixture hit its finite grapheme storage and
was replaced with real Terminal printing; no measurements from that failure or
the initial Debug-skipped run are included.

Checks: ReleaseFast probes completed, 72/72 selected tests/build steps (including
import/ABI tests), exit 0; Debug core 108/108 steps; native Debug
`SurfaceBridgeTests/inputWithoutSelectionDoesNotSerializeHistory()` passed,
1 function/1 case, no skips; focused SwiftLint and diff check passed.

## Selection invalidation (measured, bounded change)

120x60 viewport with 59 rows of mixed text; 500 changes alternating a one-cell
selection between two columns of row 2. Five batches of 100, measuring selection
update plus RenderState.update in ReleaseFast with the same testing allocator
and build flags as above. No renderer shaping, Metal uploads, GUI dragging or
physical presentation is included. Dirty-row counts are actual RenderState
outputs, not an assumed GPU speedup.

| Run | Dirty rows/query | Core median | Min–max |
| --- | --- | --- | --- |
| Before | 60 | 1.374 microseconds | 1.328–1.541 microseconds |
| After | 1 | 0.265 microseconds | 0.264–0.341 microseconds |

The absolute core time saved is small (~1.1 microseconds in this fixture).
The main payoff is restricting downstream cell rebuild work to one changed row
rather than 60. No GPU upload or total-frame speedup is claimed. Selection-only
flags no longer clear/rebuild raw text/style rows. New/old selection bounds are
compared per row, including rows left by a moved/cleared rectangle. Other screen
flags, resize, viewport changes and content mutation keep their prior behavior.

Checks:
- Debug related regressions: 111 passed / 1 timing-only probe skipped, 72/72
  steps, exit 0. The new test includes a failing allocator, retained text-buffer
  identity/search highlights, repeated identical selection, rectangle movement,
  clear and subsequent content update.
- ReleaseFast probes: 72/72 tests and steps, exit 0; both probes retained in source.
- Debug core: 108/108 steps, exit 0.
- Native selection-only repaint: real red selection pixels appeared in an
  independently read back Metal snapshot; 1 function/1 case passed, no skips.

## Final checks and limitations

- Combined Debug regressions across the prior five refactors and these changes:
  232 passed / 1 timing-only probe skipped, 72/72 steps, exit 0. The existing
  prepended-history search fixture took ~2 minutes generating/checking pages;
  process sampling showed active work rather than a blocked lock. It completed
  normally, and no process was terminated.
- Final native accessibility snapshot: 1 function/1 case passed.
- Final native search visibility/startup refresh: 1 function/2 cases passed.
- Final native composition-only cursor/scroll animation: 1 function/6 cases
  passed across native/linear/linear-corrected blending. No GPU skips.
- Across this follow-up, selected native checks passed: 8 functions/14 expanded
  cases, plus the two scales explicitly checked inside the caret test.
- Whole-repository SwiftLint strict/no-cache, Zig formatting, scope/config bridge,
  app/dependency versions, Swift 6 settings and diff checks passed.
- Python: 51 tests, 49 passed, 2 skipped for the missing fish prerequisite.

The desktop execution service briefly disconnected and recovered. Sources and
running jobs were checked after reconnect; completed work was not duplicated.
The user's original /Applications/cghostty.app process, PID 7018, remained alive.
No push, tag, release, deployment or running-app replacement was performed.
The observed remote main is 377ee70431be4276df7e3578d45ce84a7ccce8c1; this report
claims only that this task did not push, not that nobody else changed the remote.

Full Zig/native suites, Release native builds, UI test target, system IME,
dictation, real GPU fault injection/system memory pressure, contended terminal
lock measurements and foreground presentation-latency benchmarks were not run.
CAMetalDisplayLink, current latency settings and GPU submission order remain.
