# Incremental synchronized output — 2026-09-26

## Ownership and frame boundaries

Previously, every transition into mode 2026 set `terminal.flags.dirty.clear` before and after `RenderHold.capture`. This copied all visible cells into an independent snapshot, made the captured render state fully dirty, and forced another full update when live rendering resumed.

`RenderHold` and the GUI renderer now form one coordinated consumer of terminal dirty bits:

- `capture` runs at the same input boundary, but accumulates only changed rows into one pending delta. Metadata, cursor state and the scroll journal describe the completed frame at that boundary.
- `RenderState.applyDelta` transfers owned row storage to the renderer. Clean rows retain their displayed cells and shaped cell data. GPU upload policy is unchanged. Displaced storage is reused for future captures.
- Mode reset retains the pending delta. The GUI merges it before applying newer live changes. Reset/set in the same PTY read therefore preserves the last completed frame even when the next frame is already partially written.
- `syncLive` updates the spare buffer's cheap metadata after live rendering consumes dirty bits. Clean scratch rows are not a second complete screen and must never be used as visible content without merging.
- Pending style runs for a rewritten row replace older runs. Coalescing many input frames cannot accumulate an unbounded style queue. Style expansion remains on the renderer thread.
- OSC8 links are resolved under the terminal lock against current page pins before the source pages can be removed. Snapshot image pixels remain owned/shared by their existing image generations; Kitty placement capture is unchanged.
- Allocation failures force a full retry. Periodic render-state reclamation occurs only when live content is available, after consuming any pending delta.

Two buffers acquire complete geometry during initial warm-up. Full invalidation, viewport movement, resizing, screen changes and actual full-screen modifications still require complete work; ordinary sparse updates do not. This does not make arbitrarily large TUI redraws free.

## Performance comparison

ReleaseFast, 120 columns × 40 rows, styled text including Chinese and emoji, 2,000 captures/handoffs per sample. Two warm-up runs followed by five measured runs per mode; values are medians. The paired modes use the same capture/handoff path, with the baseline explicitly forcing a full capture as the old policy did.

| Workload | Forced full capture | Incremental capture | Rows copied per 2,000 captures |
| --- | ---: | ---: | ---: |
| Unchanged viewport | 4.530 ms | 0.512 ms | 80,000 → 0 |
| Repeated single-row write | 4.095 ms | 0.582 ms | 80,000 → 2,001 |

The extra row in the second workload is the initial cursor relocation. The measured loop includes capture, row ownership handoff and deferred style completion. It excludes GPU submission, application execution and live rendering after release. These are roughly 8.9× and 7.0× reductions in this CPU microbenchmark, **not end-to-end Neovim/Claude speedup claims**. The principal regression assertion is the bounded dirty-row count, not wall-clock timing.

Reproduce after building with `-Demit-bench=true -Doptimize=ReleaseFast`:

```sh
zig-out/bin/ghostty-bench +screen-clone --mode=hold-reuse --data=/private/tmp/cghostty-six3-text.bin --terminal-cols=120 --terminal-rows=40
zig-out/bin/ghostty-bench +screen-clone --mode=hold-incremental --data=/private/tmp/cghostty-six3-text.bin --terminal-cols=120 --terminal-rows=40
zig-out/bin/ghostty-bench +screen-clone --mode=hold-partial-full --data=/private/tmp/cghostty-six3-text.bin --terminal-cols=120 --terminal-rows=40
zig-out/bin/ghostty-bench +screen-clone --mode=hold-partial --data=/private/tmp/cghostty-six3-text.bin --terminal-cols=120 --terminal-rows=40
```

The fixture generator is recorded in [the earlier capture-storage validation](2026-09-24-render-search-reuse.md). Raw samples are retained locally in `/private/tmp/cghostty-mode2026-bench.json`.

## Regression coverage

Core tests compare incremental cells, styles, page pins and node generations against fresh full rebuilds over 120 mixed operations, interleaving live updates, coalesced captures, scrolling, inserts/deletes, alternate-screen switches and resizing. Additional cases cover sparse/clean captures, owned Chinese and combining-character data, 1,000 coalesced styled frames, OSC8/palette changes consumed by live rendering, images, timeout/reset, and allocation failure after an accumulated capture.

The desktop test `GhosttyScrollUITests.testSynchronizedBoundariesNeverShowIncompleteRows` writes reset/set in the same PTY write, then leaves a deliberately green incomplete row pending. Sixteen Metal screenshots must display both completed color rows and never the green intermediate row. Existing region-scroll, actual Neovim mouse-scroll and cursor tests cover interaction with the animation changes.

Validation commands use the pinned Zig 0.16.0 and Nushell 0.115.1 with `ZIG_GLOBAL_CACHE_DIR=/private/tmp/cghostty-zig-cache`. Release metadata is 0.3.2 / build 22.

## Final results

- Final core source: **231/231 passed**, filters `render hold`, `terminal.render`, `synchronized`, `scroll `, `SmoothCursor`, and `CursorMotion`.
- `GhosttyScrollUITests`: **3/3 passed**, including incomplete-row exclusion, region motion, scrollback and actual Neovim.
- Cursor interaction regressions: **2/2 passed**, wide cells/shape continuity and cell-cache refresh/blink transitions.
- Metal validation was enabled in all five desktop scenarios. The synchronized/scroll tests also checked GPU completion health in per-surface traces.
- ReleaseLocal **0.3.2 / build 22** built successfully at `macos/build/ReleaseLocal/cghostty.app`. The bundle's three version fields and the core archive/source fingerprint passed verification.
- Scope checks, Zig formatting, SwiftLint for the new desktop tests, release-version checks and `git diff --check` passed.
- This is targeted validation, not a run of the entire repository test suite. Full-screen Kitty rendering and physical device scroll feel were not newly profiled here.

Local logs: `/private/tmp/cghostty-mode2026-core-final.log`, `/private/tmp/cghostty-mode2026-ui.log`, `/private/tmp/cghostty-mode2026-cursor-wide.log`, `/private/tmp/cghostty-mode2026-cursor-cache.log`, and `/private/tmp/cghostty-mode2026-build.log`.
