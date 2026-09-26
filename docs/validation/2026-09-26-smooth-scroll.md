# Terminal smooth scrolling — 2026-09-26

## Behavior

`smooth-scroll = true` is the default and is included in the generated bilingual configuration template. Set it to `false` to retain integral scrolling. Configuration follows the app's existing restart-to-apply behavior.

- Scrollback: precision input retains fractional row offsets and follows the existing macOS pixel deltas and momentum. Discrete wheel input animates toward the integral viewport over 100 ms.
- TUI: alternate-screen IND, SU, SD, IL and DL operations record their actual rectangles and row displacement. Up to four disjoint regions can move independently, leaving status lines and adjacent splits fixed.
- Repeated input and direction reversals rebase onto the last submitted content frame. Key events themselves do not manufacture a scroll animation.
- The terminal model and mouse protocol remain in integral cells. Text selection and link lookup invert the displayed transform; outgoing scrollback rows resolve against the complete history. An outgoing alternate-screen row that no longer exists is not selectable. Wheel events continue to target the pane even at these outgoing edges.
- Explicit jumps, geometry changes, screen switches, complete erases, overlapping/overflowed scroll journals and page-sized jumps invalidate the row correspondence and refresh normally. Redraws without scroll commands are not inferred to be scrolling.
- Reduced motion uses the normal renderer. Kitty images layered above text also use the normal renderer to preserve their stacking order. Wallpaper remains stationary underneath scrolling text.

## Implementation and cost

`terminal/ScrollState.zig` is a bounded, allocation-free journal copied as part of `RenderState`, including synchronized-output captures. The renderer consumes the metadata belonging to the displayed snapshot, not newer live IO state. This initial scrolling change did not optimize `RenderHold`; the subsequent [mode 2026 optimization](2026-09-26-mode2026-incremental.md) now hands off incremental row deltas while preserving this journal's frame boundary.

`renderer/ScrollMotion.zig` owns presentation offsets. `renderer/ScrollHit.zig` independently synchronizes the last submitted coordinate transform with input handling, including IO scrolls newer than that frame.

Metal renders cursor-free content to a cached private texture, composites only explicit scroll rectangles, and draws the cursor separately. Old outgoing rows therefore do not carry a cursor ghost. Animation-only frames reuse shaped/uploaded cells. Existing VSync and timer scheduling also drives scroll animation; stationary fractional offsets do not keep an animation timer active.

Up to three full-size BGRA8 content textures are allocated lazily per visible terminal, in addition to existing presentation targets. The upper-bound payload is `width × height × 4 × 3` bytes (about 30.4 MiB at 2144 × 1238). Metal allocation overhead and in-flight resources can increase instantaneous usage. Hidden surfaces release the content cache. This is a memory/GPU-bandwidth tradeoff, not a claim of zero-cost animation or a mode 2026 performance improvement.

## Validation

Core tests cover the journal, overflow, exact terminal region recording, snapshot ownership, continuous reversal, disjoint and overlapping regions, precision offsets, page jumps, resize invalidation and input coordinates. Existing configuration-template and synchronized-output tests are included.

`GhosttyScrollUITests` runs with Metal validation enabled:

1. A synchronized alternate-screen fixture repeatedly scrolls a colored region. Screenshots must show intermediate positions smaller than a cell while a green status row stays at the same pixels.
2. Synthetic wheel input scrolls actual terminal history and a real `/opt/homebrew/bin/nvim` process with `mouse=a`. The editor's viewport must change while its status bar stays fixed. Each process must emit its own scroll frames and have no unhealthy GPU completion in its renderer trace.

Both UI scenarios passed after the three-texture cache change. Initial test failures were fixture issues: RGB thresholds were too strict for the screen color space, and a Neovim wheel delta was below one cell. The fixture now uses color dominance and a larger input delta.

This validates synthetic input on this macOS arm64 host. Physical mouse/trackpad feel, arbitrary Neovim plugin redraw strategies, background images and Kitty-image fallbacks have not all been manually exercised.

The scrolling tests below originally ran on 0.3.1. The combined scrolling and incremental mode 2026 changes are included in 0.3.2 / build 22; see the subsequent validation for current results.

### Final results

- Core: **201/201 passed**, using filters `scroll `, `template`, `render hold`, `SmoothCursor`, and `CursorMotion`.
- Scroll UI: **2/2 passed** on the final source, including a separate scroll trace from real Neovim.
- Cursor UI regression: **4/4 passed** — cell cache/blink, VSync, no VSync, and wide-character/shape continuity.
- `swiftlint lint --strict --no-cache macos/GhosttyUITests/GhosttyScrollUITests.swift`: passed.
- `scripts/check-scope.py` and `git diff --check`: passed.
- `nu macos/build.nu --configuration ReleaseLocal`: passed. Local bundle: `macos/build/ReleaseLocal/cghostty.app`.

Full commands used the pinned Zig 0.16.0 toolchain and Nushell 0.115.1, with `ZIG_GLOBAL_CACHE_DIR=/private/tmp/cghostty-zig-cache`. Native tests were run through `macos/build.nu --configuration ReleaseLocal --action test --ui-tests --only-testing GhosttyUITests/<test-class>`.
