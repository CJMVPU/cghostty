//! The primary terminal emulation structure. This represents a single
//! "terminal" containing a grid of characters and exposes various operations
//! on that grid. This also maintains the scrollback buffer.
const Terminal = @This();

const std = @import("std");
const build_options = @import("terminal_options");
const assert = @import("../quirks.zig").inlineAssert;
const tripwire = @import("../tripwire.zig");
const Allocator = std.mem.Allocator;
const simd = @import("../simd/main.zig");
const unicode = @import("../unicode/main.zig");
const uucode = @import("uucode");

const ansi = @import("ansi.zig");
const modespkg = @import("modes.zig");
const charsets = @import("charsets.zig");
const csi = @import("csi.zig");
const hyperlink = @import("hyperlink.zig");
const kitty = @import("kitty.zig");
const osc = @import("osc.zig");
const sgr = @import("sgr.zig");
const Tabstops = @import("Tabstops.zig");
const color = @import("color.zig");
const mouse = @import("mouse.zig");
const Stream = @import("stream_terminal.zig").Stream;

const size = @import("size.zig");
const pagepkg = @import("page.zig");
const style = @import("style.zig");
const PageList = @import("PageList.zig");
const Screen = @import("Screen.zig");
const ScreenSet = @import("ScreenSet.zig");
const Page = pagepkg.Page;
const Cell = pagepkg.Cell;
const Row = pagepkg.Row;

const log = std.log.scoped(.terminal);

/// Default tabstop interval
const TABSTOP_INTERVAL = 8;

/// Conservative text mutation epoch; never cleared by the renderer.
accessibility_revision: u64 = 0,

scroll_state: @import("ScrollState.zig") = .{},

/// The set of screens behind this terminal (e.g. primary vs alternate).
screens: ScreenSet,

/// Whether we're currently writing to the status line (DECSASD and DECSSDT).
/// We don't support a status line currently so we just black hole this
/// data so that it doesn't mess up our main display.
status_display: ansi.StatusDisplay = .main,

/// Where the tabstops are.
tabstops: Tabstops,

/// The size of the terminal.
rows: size.CellCountInt,
cols: size.CellCountInt,

/// The size of the screen in pixels. This is used for pty events and images
width_px: u32 = 0,
height_px: u32 = 0,

/// The current scrolling region.
scrolling_region: ScrollingRegion,

/// The last reported pwd, if any.
pwd: std.ArrayList(u8),

/// The title of the terminal as set by escape sequences (e.g. OSC 0/2).
title: std.ArrayList(u8),

/// The color state for this terminal.
colors: Colors,

/// The previous printed character. This is used for the repeat previous
/// char CSI (ESC [ <n> b).
previous_char: ?u21 = null,

/// The modes that this terminal currently has active.
modes: modespkg.ModeState = .{},

/// Terminal-level cursor state.
cursor: Cursor = .{},

/// The most recently set mouse shape for the terminal.
mouse_shape: mouse.Shape = .text,

/// Kitty drag and drop protocol (OSC 72) state. Allocated when a client
/// registers to accept drops (t=a) and freed when it unregisters (t=A),
/// so a terminal that never runs a drag and drop aware program pays
/// nothing for it. Non-null means a client currently accepts drops.
kitty_dnd: ?*kitty.dnd.State = null,

/// These are just a packed set of flags we may set on the terminal.
flags: packed struct {
    // This supports a Kitty extension where programs using semantic
    // prompts (OSC133) can annotate their new prompts with `redraw=0` to
    // disable clearing the prompt on resize.
    shell_redraws_prompt: osc.semantic_prompt.Redraw = .true,

    // This is set via ESC[4;2m. Any other modify key mode just sets
    // this to false and we act in mode 1 by default.
    modify_other_keys_2: bool = false,

    /// The mouse event mode and format. These are set to the last
    /// set mode in modes. You can't get the right event/format to use
    /// based on modes alone because modes don't show you what order
    /// this was called so we have to track it separately.
    mouse_event: mouse.Event = .none,
    mouse_format: mouse.Format = .x10,

    /// Set via the XTSHIFTESCAPE sequence. If true (XTSHIFTESCAPE = 1)
    /// then we want to capture the shift key for the mouse protocol
    /// if the configuration allows it.
    mouse_shift_capture: enum(u2) { null, false, true } = .null,

    /// True if the window is focused.
    focused: bool = true,

    /// True if the terminal view may be visible. Unknown visibility is
    /// represented as visible so callers behave conservatively.
    visible: bool = true,

    /// Whether a resize may pull rows out of scrollback back into the
    /// active area. This should be false if the pty keeps its own screen
    /// buffer without scrollback (e.g. Windows ConPTY) so that we stay in
    /// sync with it. See PageList.Resize for details. This is configuration
    /// rather than terminal state so it is preserved across a full reset.
    resize_pull_scrollback: bool = true,

    /// True if the terminal is in a password entry mode. This is set
    /// to true based on termios state. This is set
    /// to true based on termios state.
    password_input: bool = false,

    /// True if the terminal should perform selection scrolling.
    selection_scroll: bool = false,

    /// Dirty flag used only by the search thread. The renderer is expected
    /// to set this to true if the viewport was dirty as it was rendering.
    /// This is used by the search thread to more efficiently re-search the
    /// viewport and active area.
    ///
    /// Since the renderer is going to inspect the viewport/active area ANYWAYS,
    /// this lets our search thread do less work and hold the lock less time,
    /// resulting in more throughput for everything.
    search_viewport_dirty: bool = false,

    /// Dirty flags for the renderer.
    dirty: Dirty = .{},
} = .{},

/// The various color configurations a terminal maintains and that can
/// be set dynamically via OSC, with defaults usually coming from a
/// configuration.
pub const Colors = struct {
    background: color.DynamicRGB,
    foreground: color.DynamicRGB,
    cursor: color.DynamicRGB,
    palette: color.DynamicPalette,

    pub const default: Colors = .{
        .background = .unset,
        .foreground = .unset,
        .cursor = .unset,
        .palette = .default,
    };
};

/// Returns the current color for an xterm OSC color target.
///
/// Unsupported dynamic and special colors return null. The cursor color
/// follows xterm-style reporting and falls back to the foreground color when
/// no explicit cursor color is set.
pub fn colorForXterm(self: *const Terminal, target: osc.color.Target) ?color.RGB {
    return switch (target) {
        .palette => |i| self.colors.palette.current[i],
        .dynamic => |dynamic| switch (dynamic) {
            .foreground => self.colors.foreground.get(),
            .background => self.colors.background.get(),
            .cursor => self.colors.cursor.get() orelse
                self.colors.foreground.get(),
            .pointer_foreground,
            .pointer_background,
            .tektronix_foreground,
            .tektronix_background,
            .highlight_background,
            .tektronix_cursor,
            .highlight_foreground,
            => null,
        },
        .special => null,
    };
}

/// Returns the current color for a Kitty color protocol key.
///
/// Only palette, foreground, background, and cursor colors are backed by
/// Terminal state. Unsupported keys, or supported dynamic colors without a
/// value, return null.
pub fn colorForKitty(self: *const Terminal, key: kitty.color.Kind) ?color.RGB {
    return switch (key) {
        .palette => |palette| self.colors.palette.current[palette],
        .special => |special| switch (special) {
            .foreground => self.colors.foreground.get(),
            .background => self.colors.background.get(),
            .cursor => self.colors.cursor.get(),
            else => null,
        },
    };
}

/// This is a set of dirty flags the renderer can use to determine
/// what parts of the screen need to be redrawn. It is up to the renderer
/// to clear these flags.
///
/// This only contains dirty flags for terminal state, not for the screen
/// state. The screen state has its own dirty flags.
pub const Dirty = packed struct {
    /// Set when the color palette is modified in any way.
    palette: bool = false,

    /// Set when the reverse colors mode is modified.
    reverse_colors: bool = false,

    /// Screen clear of some kind. This can be due to a screen change,
    /// erase display, etc.
    clear: bool = false,

    /// Set when the pre-edit is modified.
    preedit: bool = false,
};

/// Scrolling region is the area of the screen designated where scrolling
/// occurs. When scrolling the screen, only this viewport is scrolled.
pub const ScrollingRegion = struct {
    // Top and bottom of the scroll region (0-indexed)
    // Precondition: top < bottom
    top: size.CellCountInt,
    bottom: size.CellCountInt,

    // Left/right scroll regions.
    // Precondition: right > left
    // Precondition: right <= cols - 1
    left: size.CellCountInt,
    right: size.CellCountInt,
};

/// Terminal-level cursor state shared by all screens.
pub const Cursor = struct {
    /// Whether the current cursor appearance follows the configured defaults.
    is_default: bool = true,

    /// Configured style restored by DECSCUSR default and RIS.
    default_style: Screen.CursorStyle = .block,

    /// Configured blink restored by DECSCUSR default and RIS. Null selects
    /// the terminal emulator default, which is blinking.
    default_blink: ?bool = false,
};

pub const Options = struct {
    cols: size.CellCountInt,
    rows: size.CellCountInt,

    /// The maximum size of scrollback in bytes. Null is unlimited and zero
    /// disables scrollback.
    max_scrollback_bytes: ?usize = 10_000,

    /// The maximum number of physical scrollback rows, excluding the active
    /// area. Null is unlimited. The effective limit permits at least one
    /// standard page and only complete historical pages are pruned.
    max_scrollback_lines: ?usize = null,

    colors: Colors = .default,

    /// The default mode state. When the terminal gets a reset, it
    /// will revert back to this state.
    default_modes: modespkg.ModePacked = .{},

    /// Cursor state restored by DECSCUSR default and RIS.
    default_cursor_style: Screen.CursorStyle = .block,
    default_cursor_blink: ?bool = false,

    /// The total storage limit for Kitty images in bytes. Has no effect
    /// if kitty images are disabled at build-time.
    kitty_image_storage_limit: usize = 320 * 1000 * 1000,

    /// The limits for what medium types are allowed for Kitty image loading.
    /// Has no effect if kitty images are disabled otherwise. For example,
    // if no `sys.decode_png` hook is specified, png formats are disabled
    // no matter what.
    kitty_image_loading_limits: kitty.graphics.LoadingImage.Limits = .direct,
};

/// Initialize a new terminal.
pub fn init(
    io_impl: std.Io,
    alloc: Allocator,
    opts: Options,
) !Terminal {
    const cols = opts.cols;
    const rows = opts.rows;

    var screen_set: ScreenSet = try .init(io_impl, alloc, .{
        .cols = cols,
        .rows = rows,
        .max_scrollback_bytes = opts.max_scrollback_bytes,
        .max_scrollback_lines = opts.max_scrollback_lines,
        .kitty_image_storage_limit = opts.kitty_image_storage_limit,
        .kitty_image_loading_limits = opts.kitty_image_loading_limits,
    });
    errdefer screen_set.deinit(alloc);

    var result: Terminal = .{
        .cols = cols,
        .rows = rows,
        .screens = screen_set,
        .tabstops = try .init(alloc, cols, TABSTOP_INTERVAL),
        .scrolling_region = .{
            .top = 0,
            .bottom = rows - 1,
            .left = 0,
            .right = cols - 1,
        },
        .pwd = .empty,
        .title = .empty,
        .colors = opts.colors,
        .modes = .{
            .values = opts.default_modes,
            .default = opts.default_modes,
        },
        .cursor = .{
            .default_style = opts.default_cursor_style,
            .default_blink = opts.default_cursor_blink,
        },
    };
    result.setCursorStyle(.default);
    return result;
}

pub fn deinit(self: *Terminal, alloc: Allocator) void {
    self.tabstops.deinit(alloc);
    self.screens.deinit(alloc);
    self.colors.palette.deinit(alloc);
    self.pwd.deinit(alloc);
    self.title.deinit(alloc);
    if (self.kitty_dnd) |dnd| dnd.destroy(alloc);
    self.* = undefined;
}

/// Return a terminal.Stream that can process VT streams and update this
/// terminal state. The streams will only process read-only data that
/// modifies terminal state.
///
/// Sequences that query or otherwise require output will be ignored.
/// If you want to handle side effects, use `vtHandler` and set the
/// effects field yourself, then initialize a stream.
///
/// This must be deinitialized by the caller.
///
/// Important: this creates a new stream each time with fresh parser state.
/// If you need to persist parser state across multiple writes (e.g.
/// for handling escape sequences split across write boundaries), you
/// must store and reuse the returned stream.
pub fn vtStream(self: *Terminal) Stream {
    return Stream.init(.{
        .allocator = self.gpa(),
        .handler = self.vtHandler(),
    });
}

/// This is the handler-side only for vtStream.
pub fn vtHandler(self: *Terminal) Stream.Handler {
    return .init(self);
}

/// Change the cursor's current shape and blink behavior.
///
/// The terminal parser uses this for DECSCUSR (`CSI Ps SP q`), but the behavior
/// is general: `.default` selects the configured defaults, while any other
/// value selects a concrete appearance until it is changed again or reset.
pub fn setCursorStyle(self: *Terminal, value: ansi.CursorStyle) void {
    // Remember whether future configuration changes should update the visible
    // cursor. An explicit appearance must remain in effect until the program
    // selects the default again.
    self.cursor.is_default = value == .default;

    // Convert the request into the concrete values used by the renderer and
    // terminal mode state. A null default blink means the emulator default.
    self.modes.set(.cursor_blinking, switch (value) {
        .default => self.cursor.default_blink orelse true,
        .steady_block, .steady_bar, .steady_underline => false,
        .blinking_block, .blinking_bar, .blinking_underline => true,
    });
    self.screens.active.cursor.cursor_style = switch (value) {
        .default => self.cursor.default_style,
        .blinking_block, .steady_block => .block,
        .blinking_bar, .steady_bar => .bar,
        .blinking_underline, .steady_underline => .underline,
    };
}

/// Change the default cursor shape.
///
/// If the cursor currently follows its defaults, the visible shape changes
/// immediately. Otherwise the new shape is saved for the next reset or default
/// selection, such as DECSCUSR `CSI 0 SP q`.
pub fn setDefaultCursorStyle(
    self: *Terminal,
    configured_style: Screen.CursorStyle,
) void {
    // Always retain the new default, even while an explicit appearance is
    // active, so a later reset or default request can restore it.
    self.cursor.default_style = configured_style;

    // Do not overwrite an appearance explicitly selected by the program.
    if (self.cursor.is_default) self.setCursorStyle(.default);
}

/// Change the default cursor blink behavior.
///
/// Null selects the terminal emulator default (blinking). Like the default
/// shape, this is applied immediately only when the cursor currently follows
/// its defaults; otherwise it is saved for the next reset or default selection.
pub fn setDefaultCursorBlink(self: *Terminal, blink: ?bool) void {
    // Keep the configured value separate from the currently resolved mode so
    // null can continue to mean "use the emulator default."
    self.cursor.default_blink = blink;

    // Do not overwrite blink behavior explicitly selected by the program.
    if (self.cursor.is_default) self.setCursorStyle(.default);
}

/// The I/O implementation we should use for this terminal.
pub fn io(self: *Terminal) std.Io {
    return self.screens.active.io;
}

/// The general allocator we should use for this terminal.
pub fn gpa(self: *Terminal) Allocator {
    return self.screens.active.alloc;
}

/// Change the primary screen's maximum scrollback allocation in bytes.
///
/// Null removes the byte limit and zero disables scrollback. Disabling
/// scrollback also immediately erases retained history and changes future
/// scrolling to use the no-scrollback path. The alternate screen is
/// intentionally unaffected because it never retains scrollback.
pub fn setScrollbackMaxBytes(self: *Terminal, max: ?usize) void {
    self.accessibility_revision +%= 1;
    const primary = self.screens.get(.primary).?;
    primary.pages.setMaxBytes(max);
    primary.no_scrollback = max == 0;

    if (primary.no_scrollback) primary.eraseHistory(null);
}

/// Change the primary screen's maximum number of physical scrollback lines.
///
/// Null removes the line limit. The alternate screen is intentionally
/// unaffected because it never retains scrollback.
pub fn setScrollbackMaxLines(self: *Terminal, max: ?usize) void {
    self.accessibility_revision +%= 1;
    const primary = self.screens.get(.primary).?;
    primary.pages.setMaxLines(max);
}

/// Print UTF-8 encoded string to the terminal.
pub fn printString(self: *Terminal, str: []const u8) !void {
    self.accessibility_revision +%= 1;
    const view = try std.unicode.Utf8View.init(str);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        switch (cp) {
            '\n' => {
                self.carriageReturn();
                try self.linefeed();
            },

            else => try self.print(cp),
        }
    }
}

/// Print the previous printed character a repeated amount of times.
pub fn printRepeat(self: *Terminal, count_req: usize) !void {
    self.accessibility_revision +%= 1;
    const c = self.previous_char orelse return;
    var remaining = @max(count_req, 1);

    // Print the repeated codepoint in slices so that eligible runs
    // take the batched printSlice fast path. printSlice is semantically
    // identical to calling print per codepoint: ineligible characters
    // or terminal states (insert mode, grapheme clustering, hyperlinks,
    // etc.) fall back to the per-codepoint print() path internally.
    //
    // The buffer is filled with a runtime-bounded loop rather than
    // `= @splat(c)`: a comptime-known 4096-element splat gets fully
    // unrolled into ~33KB of consecutive stores (LLVM won't re-roll
    // or vectorize it, see quirks_memset.zig), and it would fill the
    // whole buffer even for the typical small repeat counts.
    var buf: [4096]u32 = undefined;
    for (buf[0..@min(remaining, buf.len)]) |*cp| cp.* = c;
    while (remaining > 0) {
        const n = @min(remaining, buf.len);
        try self.printSlice(buf[0..n]);
        remaining -= n;
    }
}

/// Print multiple codepoints to the terminal at once. This is
/// semantically identical to calling `print` for each codepoint in
/// order, but is much faster because it can batch cell writes and
/// hoist per-codepoint checks out of the hot loop.
///
/// The codepoints must all be printable: it is illegal for any
/// codepoint in this slice to be a C0 control character. Therefore,
/// this should only be called as a result of a proper VT parser
/// (like our own).
///
/// This is optimized for the common case: ASCII, soft-wrap, etc.
/// Sequences of codepoints that require special handling (e.g. wide characters,
/// grapheme clustering) are handled correctly but fall back to the
/// slower per-codepoint path. They're less common and this is optimized
/// for the aforementioned cases.
pub fn printSlice(self: *Terminal, cps: []const u32) !void {
    self.accessibility_revision +%= 1;
    // Check if we can do the fast path up front. If we can't
    // we need to go back to scalar `print`.
    const fast = fast: {
        // Only the main display is supported.
        if (self.status_display != .main) break :fast false;

        // Modes that require per-codepoint handling in print().
        // Wraparound is required (its the default) so that our
        // row-fill logic below can assume soft-wrap semantics. Insert
        // mode shifts cells per print.
        if (self.modes.get(.insert)) break :fast false;
        if (!self.modes.get(.wraparound)) break :fast false;

        // Single shifts require per-codepoint charset handling.
        const screen: *Screen = self.screens.active;
        if (screen.charset.single_shift != null) break :fast false;

        // Hyperlinks require per-cell map bookkeeping.
        if (screen.cursor.hyperlink_id != 0) break :fast false;

        break :fast true;
    };
    if (!fast) {
        for (cps) |cp| try self.print(@intCast(cp));
        return;
    }

    const grapheme_cluster = self.modes.get(.grapheme_cluster);

    // When grapheme clustering is enabled and a left margin is set,
    // print() consults the cell left of the margin after wrapping,
    // which we can't reason about here. Restrict the fast path to
    // the [0x10, 0xFF] range in that case (those never cluster).
    const charset = self.screens.active.charset;
    const allow_unicode = switch (charset.charsets.get(charset.gl)) {
        .utf8, .ascii => !grapheme_cluster or self.scrolling_region.left == 0,
        // print() handles Unicode width and clustering before charset mapping.
        else => false,
    };

    var i: usize = 0;
    while (i < cps.len) {
        // Try the fast-path print first. This will return the number of
        // codepoints it consumed.
        const consumed = try self.printSliceFast(
            cps[i..],
            grapheme_cluster,
            allow_unicode,
        );
        if (consumed > 0) {
            i += consumed;
            continue;
        }

        // Consuming zero bytes means that the fast path can't handle
        // the next codepoint or the terminal is in a state we can't
        // fast-path. Fall back to the slow cp-by-cp print then try
        // fast paths again.
        try self.print(@intCast(cps[i]));
        i += 1;
    }
}

/// Attempt to print a prefix of `cps` using a batched fast path that
/// writes cells directly. Returns the number of codepoints consumed.
/// A return value of zero means the caller must print the first
/// codepoint via the normal `print` path.
///
/// The fast path handles runs of narrow (width 1) and wide (width 2)
/// codepoints being written to simple cells. Everything else (zero
/// width codepoints, grapheme cluster continuations, complex cells,
/// etc.) is rejected so `print` can handle it with full generality.
fn printSliceFast(
    self: *Terminal,
    cps: []const u32,
    grapheme_cluster: bool,
    allow_unicode: bool,
) !usize {
    const screen: *Screen = self.screens.active;

    // Codepoints in [0x10, 0xFF] are always narrow (width 1, matching
    // the c <= 0xFF fast path in print) and can never interact with
    // grapheme clustering (which requires a codepoint > 0xFF).
    //
    // Codepoints above 0xFF are batchable if their width is 1 or 2
    // (excluding zero-width characters such as combining marks, ZWJ,
    // and variation selectors) and, when grapheme clustering (mode
    // 2027) is enabled, if they are a grapheme break from the
    // previously printed codepoint (so print would never attach them
    // to the previous cell).

    // Codepoints in [0x10, 0xFF] are always narrow: print()
    // hardcodes width 1 for c <= 0xFF (no width table lookup).
    // They also can never interact with grapheme clustering,
    // which print() only performs for c > 0xFF, so they're
    // immediately eligible for the narrow fill with no further
    // checks.
    const cp0 = cps[0];
    if (cp0 <= 0xFF) {
        // C0 control characters (0x00-0x0F) aren't printable. The
        // stream never sends these (they're routed to execute), but
        // printSlice is a public API so defer to print() for safety.
        if (cp0 < 0x10) return 0;
        return self.printSliceFill(
            .narrow,
            cps,
            grapheme_cluster,
            allow_unicode,
        );
    }

    if (!allow_unicode) return 0;
    {
        // The Kitty graphics placeholder requires row bookkeeping.
        if (cp0 == kitty.graphics.unicode.placeholder) return 0;
    }

    // The first codepoint requires care when grapheme clustering is
    // enabled: print() may attach it to the previous *cell* instead
    // of writing a new one. Take the first codepoint only when we can
    // determine — computing exactly what print() would — that it
    // starts a new cluster. At column zero with no pending wrap,
    // print() skips clustering entirely. Otherwise resolve the
    // previous cell the way print() does and check for a break.
    //
    // Note the pending-wrap rejection: print() may attach to the
    // pending cell *instead of wrapping*, which we can't model here.
    if (grapheme_cluster and screen.cursor.x != 0) gate: {
        if (screen.cursor.pending_wrap) return 0;

        // Resolve the content cell to our left exactly like print():
        // if the immediate left cell is a wide spacer tail, the
        // content lives one further left. (A spacer tail can never
        // be at column zero — its wide half would have to be in the
        // previous row — so the second cursorCellLeft is in bounds.)
        const immediate = screen.cursorCellLeft(1);
        const prev: *Cell = switch (immediate.wide) {
            .spacer_tail => screen.cursorCellLeft(2),
            else => immediate,
        };

        // An empty previous cell is necessarily a grapheme break.
        if (prev.codepoint() == 0) break :gate;

        // Grapheme data on the previous cell requires the full
        // cluster state machine replay; only print() can do that.
        if (prev.hasGrapheme()) return 0;

        // A simple single-codepoint previous cell: print() would run
        // exactly this break check from the default state.
        var state: uucode.grapheme.BreakState = .{};
        if (!unicode.graphemeBreak(
            prev.content.codepoint.data,
            @intCast(cp0),
            &state,
        )) return 0;
    } else if (grapheme_cluster) {
        if (screen.cursor.pending_wrap) return 0;
    }

    // The width lookup is a runtime value while printSliceFill is
    // specialized at comptime by width class, so this switch selects
    // between the two instantiations rather than passing the width
    // through as an argument.
    return switch (unicode.table.get(@intCast(cp0)).width) {
        1 => self.printSliceFill(
            .narrow,
            cps,
            grapheme_cluster,
            allow_unicode,
        ),
        2 => self.printSliceFill(
            .wide,
            cps,
            grapheme_cluster,
            allow_unicode,
        ),
        else => 0,
    };
}

/// The width class of a printSlice batch. Each batch contains only
/// codepoints of a single width class because they fill cells
/// differently: wide codepoints occupy a (wide, spacer_tail) cell
/// pair while narrow codepoints occupy a single cell.
const PrintSliceWidth = enum(u1) {
    narrow,
    wide,

    /// The number of cells each codepoint of this width class occupies.
    fn cellsPerCp(comptime self: PrintSliceWidth) usize {
        return switch (self) {
            .narrow => 1,
            .wide => 2,
        };
    }
};

/// Whether a codepoint above 0xFF is eligible for the batched print
/// fast path with the given width class.
inline fn printSliceEligible(cp: u32, comptime width: PrintSliceWidth) bool {
    assert(cp > 0xFF);
    {
        if (cp == kitty.graphics.unicode.placeholder) return false;
    }

    return unicode.table.get(@intCast(cp)).width == comptime @as(u2, switch (width) {
        .narrow => 1,
        .wide => 2,
    });
}

/// Store narrow cells using a template with zeroed codepoint bits.
/// If a charset table is provided, all input codepoints must fit in a byte.
///
/// The unmapped loop is manually vectorized: Zig 0.16 (LLVM 21) no longer
/// auto-vectorizes it as Zig 0.15 (LLVM 20) did.
inline fn printSliceStoreRun(
    cells: [*]Cell,
    cps: [*]const u32,
    from: usize,
    to: usize,
    template_bits: u64,
    charset_table: ?[]const u16,
) void {
    // The bit position of the `content` field within the packed
    // Cell. A codepoint occupies the low bits of `content`, so
    // shifting a codepoint left by this amount places it exactly
    // where `.content = .{ .codepoint = .{ .data = cp } }` would.
    const cp_shift = @bitOffsetOf(Cell, "content");

    // Since codepoints are OR'd into the content field rather than
    // assigned, any nonzero content bits in the template would
    // corrupt the stored codepoints.
    const content_mask: u64 = comptime mask: {
        const bits = @bitSizeOf(@FieldType(Cell, "content"));
        break :mask ((1 << bits) - 1) << cp_shift;
    };
    assert(template_bits & content_mask == 0);

    if (charset_table) |table| {
        for (from..to) |idx| {
            cells[idx] = @bitCast(template_bits | (@as(u64, table[cps[idx]]) << cp_shift));
        }
        return;
    }

    var idx = from;

    // Vectorized bulk of the run.
    if (simd.lanes(u64)) |lanes| {
        // u64 due to backing integer of Cell
        const V = @Vector(lanes, u64);

        // The template and shift amount are loop-invariant, so
        // broadcast them to every lane once up front.
        const template: V = @splat(template_bits);
        const shift: @Vector(
            lanes,
            std.math.Log2Int(u64),
        ) = @splat(cp_shift);

        while (idx + lanes <= to) : (idx += lanes) {
            // Load `lanes` decoded codepoints...
            const narrow: @Vector(lanes, u32) = cps[idx..][0..lanes].*;

            // ...widen each u32 lane to the u64 cell size...
            const wide: V = @intCast(narrow);

            // ...shift each codepoint into the content field's bit
            // position and merge with the template, producing
            // `lanes` finished cells (coerced from vector to array
            // so they can be bitcast for the store below)...
            const bits: [lanes]u64 = template | (wide << shift);

            // ...and store them contiguously. Cell is a packed
            // struct(u64) so an array of u64 bit patterns has
            // identical layout to an array of cells.
            cells[idx..][0..lanes].* = @bitCast(bits);
        }
    }

    // Scalar tail: the final `< lanes` cells of the run, or the
    // entire run on targets without SIMD. Note `idx` carries over
    // from the vector loop above. This is the same computation as
    // the vector body, one cell at a time.
    while (idx < to) : (idx += 1) {
        cells[idx] = @bitCast(template_bits | (@as(u64, cps[idx]) << cp_shift));
    }
}

/// The row-filling portion of the printSlice fast path, specialized by
/// width class. The first codepoint must already be validated by the
/// caller (printSliceFast).
fn printSliceFill(
    self: *Terminal,
    comptime width: PrintSliceWidth,
    cps: []const u32,
    grapheme_cluster: bool,
    allow_unicode: bool,
) !usize {
    const screen: *Screen = self.screens.active;
    const charset_table: ?[]const u16 = switch (screen.charset.charsets.get(screen.charset.gl)) {
        .utf8, .ascii => null,
        else => |set| charsets.table(set),
    };
    assert(charset_table == null or !allow_unicode);

    // Our fast path can only handle "simple" cells. A simple cell is
    // a codepoint cell (no grapheme data or bg-color tag), narrow, and
    // not a hyperlink. The mask covers every field that must match
    // the expected value (see printSliceCheckExpected) exactly.
    const SimpleMask = pagepkg.Mask(Cell, &.{
        "content_tag",
        "style_id",
        "wide",
        "hyperlink",
    }, 4);

    // The bit offset of the codepoint content within a Cell, used to
    // construct cell values from a template without field assignments.
    const cp_shift = @bitOffsetOf(Cell, "content");

    // Determine the run of codepoints in the same width class that we
    // can batch. For codepoints after the first, the previous codepoint
    // in the run is always written as a fresh, single-codepoint cell,
    // so the grapheme break check against it is exact.
    const run_len: usize = run: {
        var idx: usize = 1;

        // Vectorized scan for the narrow class: codepoints in
        // [0x10, 0xFF] are always eligible with no further checks
        // and dominate real-world input, so scan for the first
        // codepoint outside that range several lanes at a time.
        // Anything else (including eligible unicode) proceeds via
        // the scalar loop below.
        if (comptime width == .narrow) {
            if (simd.lanes(u32)) |lanes| {
                const V = @Vector(lanes, u32);
                const lo: V = @splat(0x10);
                const hi: V = @splat(0xFF);
                while (idx + lanes <= cps.len) {
                    const v: V = cps[idx..][0..lanes].*;
                    const in_range = (v >= lo) & (v <= hi);
                    if (!@reduce(.And, in_range)) {
                        const bits: std.meta.Int(.unsigned, lanes) = @bitCast(in_range);
                        idx += @ctz(~bits);
                        break;
                    }
                    idx += lanes;
                }
            }
        }

        while (idx < cps.len) : (idx += 1) {
            const cp = cps[idx];
            if (comptime width == .narrow) {
                if (cp >= 0x10 and cp <= 0xFF) continue;
            }
            if (cp > 0xFF and allow_unicode and printSliceEligible(cp, width)) {
                if (!grapheme_cluster) continue;
                var state: uucode.grapheme.BreakState = .{};
                if (unicode.graphemeBreak(@intCast(cps[idx - 1]), @intCast(cp), &state)) continue;
            }
            break :run idx;
        }
        break :run cps.len;
    };
    assert(run_len > 0);

    // After doing any printing, wrapping, scrolling, etc. we want to
    // ensure that our screen remains in a consistent state.
    defer screen.assertIntegrity();

    // The number of cells each codepoint occupies.
    const cells_per_cp: usize = comptime width.cellsPerCp();

    var printed: usize = 0;
    outer: while (printed < run_len) {
        // If we're soft-wrapping, handle that first so that our cursor
        // is in the row/column that will receive the next codepoint.
        if (screen.cursor.pending_wrap) try self.printWrap();

        // Our right margin depends on where our cursor is now,
        // matching the logic in print().
        const right_limit: usize = if (screen.cursor.x > self.scrolling_region.right)
            self.cols
        else
            self.scrolling_region.right + 1;

        // A degenerate 1-wide region can't hold a wide char; print()
        // has special handling so fall back to it.
        if (comptime width == .wide) {
            if (right_limit - self.scrolling_region.left <= 1) break;
        }

        const cursor = &screen.cursor;
        const avail: usize = right_limit - cursor.x;
        assert(avail > 0);

        // The cursor caches live row and cell pointers into this mapping, so
        // its page cannot be compressed while this print path is active.
        const page = cursor.page_pin.node.pageAssumeResident();
        const cells: [*]Cell = @ptrCast(cursor.page_cell);
        const style_id = cursor.style_id;
        const template: Cell = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 0 } },
            .style_id = style_id,
            .wide = .narrow,
            .protected = cursor.protected,
            .semantic_content = cursor.semantic_content,
        };
        const template_bits: u64 = @bitCast(template);
        const check_expected: u64 = printSliceCheckExpected(style_id);

        if (comptime width == .wide) {
            if (avail == 1) {
                // Only one cell left in the row: print() writes a
                // spacer head (or a blank narrow cell if we're inside
                // a right margin) and wraps. We require a simple cell,
                // otherwise fall back to print() for the cleanup.
                if (!SimpleMask.eqlScalar(cells[0], check_expected)) break;

                var spacer = template;
                if (right_limit == self.cols) {
                    cursor.page_row.wrap = true;
                    spacer.wide = .spacer_head;
                }
                cursor.page_row.dirty = true;
                if (style_id != style.default_id) cursor.page_row.styled = true;
                cells[0] = spacer;
                try self.printWrap();
                continue :outer;
            }
        }

        // Number of codepoints and cells we're writing to this row.
        const count = @min(avail / cells_per_cp, run_len - printed);
        assert(count > 0);
        const cell_count = count * cells_per_cp;

        // Wide cells always come in (wide, spacer_tail) pairs.
        const spacer_bits: u64 = if (comptime width == .wide) spacer: {
            var spacer = template;
            spacer.wide = .spacer_tail;
            break :spacer @bitCast(spacer);
        } else undefined;
        const wide_bits: u64 = if (comptime width == .wide) wb: {
            var w = template;
            w.wide = .wide;
            break :wb @bitCast(w);
        } else undefined;

        var k: usize = 0; // cells written
        fill: while (k < cell_count) {
            // Find the run of simple cells so the store loop below is
            // branch-free (and vectorizable). This is an early-exit
            // search loop that LLVM won't auto-vectorize, and reused
            // rows typically match the whole way through, so scan
            // several cells at a time manually.
            var simple = k;
            simple: {
                while (simple + SimpleMask.group_len <= cell_count) {
                    const p = SimpleMask.eqlPrefix(
                        cells[0..cell_count],
                        simple,
                        check_expected,
                    );
                    simple += p;
                    if (p != SimpleMask.group_len) break :simple;
                }
                while (simple < cell_count) : (simple += 1) {
                    if (!SimpleMask.eqlScalar(
                        cells[simple],
                        check_expected,
                    )) break;
                }
            }

            if (comptime width == .wide) {
                // We can only write whole (wide, spacer) pairs.
                const pair_end = k + (simple - k) / 2 * 2;
                var idx = k;

                // Manually vectorized for the same reason as
                // printSliceStoreRun: build a vector of wide cells,
                // interleave with spacer tails, and store (wide,
                // spacer) pairs several at a time.
                if (simd.lanes(u64)) |lanes| {
                    const pair_lanes = lanes / 2;
                    const Vp = @Vector(pair_lanes, u64);
                    const wide_v: Vp = @splat(wide_bits);
                    const spacer_v: Vp = @splat(spacer_bits);
                    const shift_v: @Vector(
                        pair_lanes,
                        std.math.Log2Int(u64),
                    ) = @splat(cp_shift);
                    while (idx + 2 * pair_lanes <= pair_end) : (idx += 2 * pair_lanes) {
                        const narrow: @Vector(pair_lanes, u32) =
                            cps[printed + idx / 2 ..][0..pair_lanes].*;
                        const wides: Vp = wide_v | (@as(Vp, @intCast(narrow)) << shift_v);
                        const inter: [2 * pair_lanes]u64 = std.simd.interlace(.{
                            wides,
                            spacer_v,
                        });
                        cells[idx..][0 .. 2 * pair_lanes].* = @bitCast(inter);
                    }
                }
                while (idx < pair_end) : (idx += 2) {
                    cells[idx] = @bitCast(
                        wide_bits | (@as(u64, cps[printed + idx / 2]) << cp_shift),
                    );
                    cells[idx + 1] = @bitCast(spacer_bits);
                }

                // If the simple run ended mid-pair we stop at the pair
                // boundary and handle the offending cell below.
                k = pair_end;
                if (simple != pair_end) {
                    // The first cell of the next pair is simple but the
                    // second isn't; handle both via the general path.
                    simple = pair_end;
                }
            } else {
                printSliceStoreRun(
                    cells,
                    cps.ptr + printed,
                    k,
                    simple,
                    template_bits,
                    charset_table,
                );
                k = simple;
            }
            if (k >= cell_count) break;

            // Bulk path for runs of cells that differ from the
            // expected simple cell only by their style: this is the
            // common case when styled text overwrites previously
            // styled (or default-styled) rows, e.g. TUI redraws.
            // These runs are handled wholesale: one scan to find the
            // run of identical old styles, two ref-count updates,
            // and a branch-free fill.
            if (comptime width == .narrow) bulk: {
                const first = SimpleMask.pattern(cells[k]);

                // The old cell must be a plain narrow codepoint cell
                // with no hyperlink whose only difference is the
                // style id (see printSliceCheckExpected: every other
                // masked field must be zero).
                const style_shift = @bitOffsetOf(Cell, "style_id");
                const old_style: style.Id = @truncate(first >> style_shift);
                if (first != printSliceCheckExpected(old_style)) break :bulk;
                assert(old_style != style_id); // it failed the simple check

                // Find the run of cells with identical masked bits.
                var m = k + 1;
                scan: {
                    while (m + SimpleMask.group_len <= cell_count) {
                        const p = SimpleMask.eqlPrefix(
                            cells[0..cell_count],
                            m,
                            first,
                        );
                        m += p;
                        if (p != SimpleMask.group_len) break :scan;
                    }
                    while (m < cell_count) : (m += 1) {
                        if (!SimpleMask.eqlScalar(cells[m], first)) break;
                    }
                }

                // Fix up the style ref counts for the whole run at
                // once. Each of the old cells held a reference to
                // old_style so the release is safe by construction.
                const n = m - k;
                if (old_style != style.default_id) {
                    page.styles.releaseMultiple(page.memory, old_style, @intCast(n));
                }
                if (style_id != style.default_id) {
                    page.styles.useMultiple(page.memory, style_id, @intCast(n));
                }

                printSliceStoreRun(
                    cells,
                    cps.ptr + printed,
                    k,
                    m,
                    template_bits,
                    charset_table,
                );
                k = m;
                continue :fill;
            }

            // General path for cells that failed the masked check:
            // style-only mismatches are handled inline; anything that
            // needs cleanup (wide chars and their spacers, grapheme
            // data, hyperlinks) falls back to print().
            const general_count: usize = cells_per_cp;
            for (0..general_count) |offset| {
                const cell = &cells[k + offset];
                if (cell.wide != .narrow or
                    cell.hasGrapheme() or
                    cell.hyperlink) break :fill;
            }
            for (0..general_count) |offset| {
                const cell = &cells[k + offset];
                if (cell.style_id != style_id) {
                    if (cell.style_id != style.default_id) {
                        page.styles.release(page.memory, cell.style_id);
                    }
                    if (style_id != style.default_id) {
                        page.styles.use(page.memory, style_id);
                    }
                }
            }
            if (comptime width == .wide) {
                cells[k] = @bitCast(
                    wide_bits | (@as(u64, cps[printed + k / 2]) << cp_shift),
                );
                cells[k + 1] = @bitCast(spacer_bits);
            } else {
                const cp = if (charset_table) |table|
                    table[cps[printed + k]]
                else
                    cps[printed + k];
                cells[k] = @bitCast(
                    template_bits | (@as(u64, cp) << cp_shift),
                );
            }
            k += cells_per_cp;
        }

        if (k > 0) {
            assert(k % cells_per_cp == 0);
            cursor.page_row.dirty = true;
            if (style_id != style.default_id) cursor.page_row.styled = true;
            self.previous_char = @intCast(cps[printed + k / cells_per_cp - 1]);
            printed += k / cells_per_cp;

            // Advance the cursor. If we filled through the right limit
            // then the cursor stays on the last cell with the pending
            // wrap flag set, matching print().
            if (cursor.x + k >= right_limit) {
                assert(cursor.x + k == right_limit);
                screen.cursorRight(@intCast(k - 1));
                cursor.pending_wrap = true;
            } else {
                screen.cursorRight(@intCast(k));
            }
        }

        // We hit a cell that requires the slow path. The cursor is
        // exactly at that cell so return and let the caller print the
        // next codepoint via print().
        if (k < cell_count) break;
    }

    return printed;
}

/// The expected value of a simple cell (per SimpleMask in
/// printSliceFill) that already has the given style (so no
/// ref-counting is needed).
inline fn printSliceCheckExpected(style_id: style.Id) u64 {
    var e: Cell = @bitCast(@as(u64, 0));
    e.style_id = style_id;
    return @bitCast(e);
}

pub fn print(self: *Terminal, c: u21) !void {
    self.accessibility_revision +%= 1;
    // log.debug("print={x} y={} x={}", .{ c, self.screens.active.cursor.y, self.screens.active.cursor.x });

    // If we're not on the main display, do nothing for now
    if (self.status_display != .main) {
        @branchHint(.cold);
        return;
    }

    // After doing any printing, wrapping, scrolling, etc. we want to ensure
    // that our screen remains in a consistent state.
    defer self.screens.active.assertIntegrity();

    // Our right margin depends where our cursor is now.
    const right_limit = if (self.screens.active.cursor.x > self.scrolling_region.right)
        self.cols
    else
        self.scrolling_region.right + 1;

    // Perform grapheme clustering if grapheme support is enabled (mode 2027).
    // This is MUCH slower than the normal path so the conditional below is
    // purposely ordered in least-likely to most-likely so we can drop out
    // as quickly as possible.
    if (c > 255 and
        self.modes.get(.grapheme_cluster) and
        self.screens.active.cursor.x > 0)
    grapheme: {
        @branchHint(.unlikely);
        // We need the previous cell to determine if we're at a grapheme
        // break or not. If we are NOT, then we are still combining the
        // same grapheme, and will be appending to prev.cell. Otherwise, we are
        // in a new cell.
        const Prev = struct { cell: *Cell, left: size.CellCountInt };
        var prev: Prev = prev: {
            const left: size.CellCountInt = left: {
                // If we have wraparound, then we use the prev col unless
                // there's a pending wrap, in which case we use the current.
                if (self.modes.get(.wraparound)) {
                    break :left @intFromBool(!self.screens.active.cursor.pending_wrap);
                }

                // If we do not have wraparound, the logic is trickier. If
                // we're not on the last column, then we just use the previous
                // column. Otherwise, we need to check if there is text to
                // figure out if we're attaching to the prev or current.
                if (self.screens.active.cursor.x != right_limit - 1) break :left 1;
                break :left @intFromBool(self.screens.active.cursor.page_cell.codepoint() == 0);
            };

            // If the previous cell is a wide spacer tail, then we actually
            // want to use the cell before that because that has the actual
            // content.
            const immediate = self.screens.active.cursorCellLeft(left);
            break :prev switch (immediate.wide) {
                else => .{ .cell = immediate, .left = left },
                .spacer_tail => .{
                    .cell = self.screens.active.cursorCellLeft(left + 1),
                    .left = left + 1,
                },
            };
        };

        // If our cell has no content, then this is a new cell and
        // necessarily a grapheme break.
        if (prev.cell.codepoint() == 0) break :grapheme;

        var previous_codepoint: u21 = prev.cell.content.codepoint.data;
        const grapheme_break = brk: {
            var state: uucode.grapheme.BreakState = .{};
            if (prev.cell.hasGrapheme()) {
                const cps = self.screens.active.cursor.page_pin.node.page().lookupGrapheme(prev.cell).?;
                for (cps) |cp2| {
                    // log.debug("cp1={x} cp2={x}", .{ previous_codepoint, cp2 });
                    // With mode 2027 disabled, zero-width codepoints are
                    // attached without applying grapheme boundary rules. If
                    // the mode is enabled later, an existing cell can
                    // therefore contain one or more breaks. Feed those breaks
                    // into the state machine so it can reset its context and
                    // determine the boundary for the new codepoint.
                    _ = unicode.graphemeBreak(previous_codepoint, cp2, &state);
                    previous_codepoint = cp2;
                }
            }

            // log.debug("cp1={x} cp2={x} end", .{ previous_codepoint, c });
            break :brk unicode.graphemeBreak(previous_codepoint, c, &state);
        };

        // If we can NOT break, this means that "c" is part of a grapheme
        // with the previous char.
        if (!grapheme_break) {
            switch (unicode.graphemeWidthEffect(previous_codepoint, c)) {
                .ignore => return,
                .wide => wide: {
                    if (prev.cell.wide == .wide) break :wide;

                    // Move our cursor back to the previous. We'll move
                    // the cursor within this block to the proper location.
                    self.screens.active.cursorLeft(prev.left);

                    // If we don't have space for the wide char, we need to
                    // insert spacers and wrap. We need special handling if the
                    // previous cell has grapheme data.
                    if (self.screens.active.cursor.x == right_limit - 1) {
                        if (!self.modes.get(.wraparound)) return;

                        // This path can write a spacer_head before printWrap
                        // which can trigger integrity violations so mark
                        // the wrap first to keep the intermediary state valid
                        // if we're wrapping.
                        const row_wrap = right_limit == self.cols;
                        if (row_wrap) self.screens.active.cursor.page_row.wrap = true;

                        const prev_cp = prev.cell.content.codepoint.data;
                        if (prev.cell.hasGrapheme()) {
                            // This is like printCell but without clearing the
                            // grapheme data from the cell, so we can move it
                            // later.
                            prev.cell.wide = if (row_wrap) .spacer_head else .narrow;
                            prev.cell.content.codepoint.data = 0;

                            try self.printWrap();
                            self.printCell(prev_cp, .wide);

                            const new_pin = self.screens.active.cursor.page_pin.*;
                            const new_rac = new_pin.rowAndCell();

                            transfer_graphemes: {
                                var old_pin = self.screens.active.cursor.page_pin.up(1) orelse break :transfer_graphemes;
                                old_pin.x = right_limit - 1;
                                const old_rac = old_pin.rowAndCell();

                                if (new_pin.node == old_pin.node) {
                                    new_pin.node.page().moveGrapheme(old_rac.cell, new_rac.cell);
                                    old_rac.cell.content_tag = .codepoint;
                                    new_rac.cell.content_tag = .codepoint_grapheme;
                                    new_rac.row.grapheme = true;
                                } else {
                                    const cps = old_pin.node.page().lookupGrapheme(old_rac.cell).?;
                                    for (cps) |cp| {
                                        // appendGrapheme can grow the cursor
                                        // page, so read the destination from
                                        // the cursor each time rather than
                                        // holding a pointer across the call.
                                        try self.screens.active.appendGrapheme(
                                            self.screens.active.cursor.page_cell,
                                            cp,
                                        );
                                    }
                                    old_pin.node.page().clearGrapheme(old_rac.cell);
                                }

                                old_pin.node.page().updateRowGraphemeFlag(old_rac.row);
                            }

                            // Point prev.cell to our new previous cell that
                            // we'll be appending graphemes to
                            prev.cell = self.screens.active.cursor.page_cell;
                        } else {
                            self.printCell(
                                0,
                                if (row_wrap) .spacer_head else .narrow,
                            );
                            try self.printWrap();
                            self.printCell(prev_cp, .wide);

                            // Point prev.cell to our new previous cell that
                            // we'll be appending graphemes to
                            prev.cell = self.screens.active.cursor.page_cell;
                        }
                    } else {
                        prev.cell.wide = .wide;
                    }

                    // Write our spacer, since prev.cell is now wide
                    self.screens.active.cursorRight(1);

                    // Writing the spacer can grow the page to make room for
                    // the cursor hyperlink. Growing replaces the page, which
                    // invalidates `prev.cell`. Record the page identity first
                    // so the common case where nothing grows stays free.
                    //
                    // A pointer comparison alone isn't enough: pages are
                    // pooled, so a replacement can reuse the same address.
                    // The serial makes the pair a unique identity.
                    const spacer_node = self.screens.active.cursor.page_pin.node;
                    const spacer_serial = spacer_node.serial;

                    self.printCell(0, .spacer_tail);

                    if (self.screens.active.cursor.page_pin.node != spacer_node or
                        self.screens.active.cursor.page_pin.node.serial != spacer_serial)
                    {
                        @branchHint(.unlikely);

                        // The cursor is on the spacer tail we just wrote, so
                        // the wide cell we append to is the one to its left.
                        prev.cell = self.screens.active.cursorCellLeft(1);
                    }

                    // Move the cursor again so we're beyond our spacer
                    if (self.screens.active.cursor.x == right_limit - 1) {
                        self.screens.active.cursor.pending_wrap = true;
                    } else {
                        self.screens.active.cursorRight(1);
                    }
                },

                .narrow => narrow: {
                    // Prev cell is no longer wide
                    if (prev.cell.wide != .wide) break :narrow;
                    prev.cell.wide = .narrow;

                    // Remove the wide spacer tail. The previous cell may be
                    // under the cursor, so locate the tail from the wide base
                    // rather than by subtracting from the cursor distance.
                    const prev_x = self.screens.active.cursor.x - prev.left;
                    if (prev_x < self.cols - 1) {
                        const cells: [*]Cell = @ptrCast(prev.cell);
                        cells[1].wide = .narrow;
                    }

                    // Place the cursor one cell after the now-narrow base,
                    // clamped to the right edge. Usually this moves the cursor
                    // back from after the old tail, but saved cursor state or
                    // changed margins can leave it directly on the base.
                    self.screens.active.cursor.pending_wrap = false;
                    self.screens.active.cursorHorizontalAbsolute(
                        @min(prev_x + 1, right_limit - 1),
                    );

                    break :narrow;
                },

                .no_change => {},
            }

            log.debug("c={X} grapheme attach to left={} primary_cp={X}", .{
                c,
                prev.left,
                prev.cell.codepoint(),
            });
            self.screens.active.cursorMarkDirty();
            try self.screens.active.appendGrapheme(prev.cell, c);
            return;
        }
    }

    // Determine the width of this character so we can handle
    // non-single-width characters properly. We have a fast-path for
    // byte-sized characters since they're so common. We can ignore
    // control characters because they're always filtered prior.
    const width: usize = if (c <= 0xFF) 1 else @intCast(unicode.table.get(c).width);

    // Note: it is possible to have a width of "3" and a width of "-1" from
    // uucode.x's wcwidth. We should look into those cases and handle them
    // appropriately.
    assert(width <= 2);
    // log.debug("c={x} width={}", .{ c, width });

    // Attach zero-width characters to our cell as grapheme data.
    if (width == 0) {
        @branchHint(.unlikely);
        // If we have grapheme clustering enabled, we don't blindly attach
        // any zero width character to our cells and we instead just ignore
        // it.
        if (self.modes.get(.grapheme_cluster)) return;

        // If we have wraparound enabled and a pending wrap, the character
        // we're attaching to is still under the cursor. Otherwise, it's the
        // cell to the left.
        const left: size.CellCountInt = if (self.modes.get(.wraparound) and self.screens.active.cursor.pending_wrap) 0 else 1;

        // If we're at cell zero and not pending a wrap, then this is malformed
        // data and we don't print anything or even store this. Zero-width
        // characters are ALWAYS attached to some other non-zero-width
        // character at the time of writing.
        if (self.screens.active.cursor.x == 0 and left == 1) {
            log.warn("zero-width character with no prior character, ignoring", .{});
            return;
        }

        // Find our previous cell
        const prev = prev: {
            const immediate = self.screens.active.cursorCellLeft(left);
            if (immediate.wide != .spacer_tail) break :prev immediate;
            break :prev self.screens.active.cursorCellLeft(left + 1);
        };

        // If our previous cell has no text, just ignore the zero-width character
        if (!prev.hasText()) {
            log.warn("zero-width character with no prior character, ignoring", .{});
            return;
        }

        // If this is a emoji variation selector, prev must be an emoji
        if (c == 0xFE0F or c == 0xFE0E) {
            const prev_props = unicode.table.get(prev.content.codepoint.data);
            const emoji = prev_props.grapheme_break == .extended_pictographic;
            if (!emoji) return;
        }

        try self.screens.active.appendGrapheme(prev, c);
        return;
    }

    // We have a printable character, save it
    self.previous_char = c;

    // If we're soft-wrapping, then handle that first.
    if (self.screens.active.cursor.pending_wrap and self.modes.get(.wraparound)) {
        try self.printWrap();
    }

    // If we have insert mode enabled then we need to handle that. We
    // only do insert mode if we're not at the end of the line.
    if (self.modes.get(.insert) and
        self.screens.active.cursor.x + width < self.cols)
    {
        self.insertBlanks(width);
    }

    switch (width) {
        // Single cell is very easy: just write in the cell
        1 => {
            @branchHint(.likely);
            self.screens.active.cursorMarkDirty();
            @call(.always_inline, printCell, .{ self, c, .narrow });
        },

        // Wide character requires a spacer. We print this by
        // using two cells: the first is flagged "wide" and has the
        // wide char. The second is guaranteed to be a spacer if
        // we're not at the end of the line.
        2 => if ((right_limit - self.scrolling_region.left) > 1) {
            // If we don't have space for the wide char, we need
            // to insert spacers and wrap. Then we just print the wide
            // char as normal.
            if (self.screens.active.cursor.x == right_limit - 1) {
                // If we don't have wraparound enabled then we don't print
                // this character at all and don't move the cursor. This is
                // how xterm behaves.
                if (!self.modes.get(.wraparound)) return;

                // We only create a spacer head if we're at the real edge
                // of the screen. Otherwise, we clear the space with a narrow.
                // This allows soft wrapping to work correctly.
                if (right_limit == self.cols) {
                    // Special-case: we need to set wrap to true even
                    // though we call printWrap below because if there is
                    // a page resize during printCell then it'll fail
                    // integrity checks.
                    self.screens.active.cursor.page_row.wrap = true;
                    self.printCell(0, .spacer_head);
                } else {
                    self.printCell(0, .narrow);
                }
                try self.printWrap();
            }

            self.screens.active.cursorMarkDirty();
            self.printCell(c, .wide);
            self.screens.active.cursorRight(1);
            self.printCell(0, .spacer_tail);
        } else {
            // This is pretty broken, terminals should never be only 1-wide.
            // We should prevent this downstream.
            self.screens.active.cursorMarkDirty();
            self.printCell(0, .narrow);
        },

        else => unreachable,
    }

    // If we're at the column limit, then we need to wrap the next time.
    // In this case, we don't move the cursor.
    if (self.screens.active.cursor.x == right_limit - 1) {
        self.screens.active.cursor.pending_wrap = true;
        return;
    }

    // Move the cursor
    self.screens.active.cursorRight(1);
}

fn printCell(
    self: *Terminal,
    unmapped_c: u21,
    wide: Cell.Wide,
) void {
    defer self.screens.active.assertIntegrity();

    // TODO: spacers should use a bgcolor only cell

    const c: u21 = c: {
        // TODO: non-utf8 handling, gr

        // If we're single shifting, then we use the key exactly once.
        const key = if (self.screens.active.charset.single_shift) |key_once| blk: {
            self.screens.active.charset.single_shift = null;
            break :blk key_once;
        } else self.screens.active.charset.gl;

        const set = self.screens.active.charset.charsets.get(key);

        // UTF-8 or ASCII is used as-is
        if (set == .utf8 or set == .ascii) {
            @branchHint(.likely);
            break :c unmapped_c;
        }

        // If we're outside of ASCII range this is an invalid value in
        // this table so we just return space.
        if (unmapped_c > std.math.maxInt(u8)) break :c ' ';

        // Get our lookup table and map it
        const table = charsets.table(set);
        break :c @intCast(table[@intCast(unmapped_c)]);
    };

    const cell = self.screens.active.cursor.page_cell;

    // If the wide property of this cell is the same, then we don't
    // need to do the special handling here because the structure will
    // be the same. If it is NOT the same, then we may need to clear some
    // cells.
    if (cell.wide != wide) {
        switch (cell.wide) {
            // Previous cell was narrow. Do nothing.
            .narrow => {},

            // Previous cell was wide. We need to clear the tail and head.
            .wide => wide: {
                if (self.screens.active.cursor.x >= self.cols - 1) break :wide;

                const spacer_cell = self.screens.active.cursorCellRight(1);
                self.screens.active.clearCells(
                    self.screens.active.cursor.page_pin.node.page(),
                    self.screens.active.cursor.page_row,
                    spacer_cell[0..1],
                );

                // If we're near the left edge, a wide char may have
                // wrapped from the previous row, leaving a spacer_head
                // at the end of that row. Clear it so the previous row
                // doesn't keep a stale spacer_head.
                if (self.screens.active.cursor.y > 0 and self.screens.active.cursor.x <= 1) {
                    const head_cell = self.screens.active.cursorCellEndOfPrev();
                    if (head_cell.wide == .spacer_head) head_cell.wide = .narrow;
                }
            },

            .spacer_tail => {
                assert(self.screens.active.cursor.x > 0);

                // So integrity checks pass. We fix this up later so we don't
                // need to do this without safety checks.
                if (comptime build_options.slow_runtime_safety) {
                    cell.wide = .narrow;
                }

                const wide_cell = self.screens.active.cursorCellLeft(1);
                self.screens.active.clearCells(
                    self.screens.active.cursor.page_pin.node.page(),
                    self.screens.active.cursor.page_row,
                    wide_cell[0..1],
                );
                // If we're near the left edge, a wide char may have
                // wrapped from the previous row, leaving a spacer_head
                // at the end of that row. Clear it so the previous row
                // doesn't keep a stale spacer_head.
                if (self.screens.active.cursor.y > 0 and self.screens.active.cursor.x <= 1) {
                    const head_cell = self.screens.active.cursorCellEndOfPrev();
                    if (head_cell.wide == .spacer_head) head_cell.wide = .narrow;
                }
            },

            // TODO: this case was not handled in the old terminal implementation
            // but it feels like we should do something. investigate other
            // terminals (xterm mainly) and see what's up.
            .spacer_head => {},
        }
    }

    // If the prior value had graphemes, clear those
    if (cell.hasGrapheme()) {
        const page = self.screens.active.cursor.page_pin.node.page();
        page.clearGrapheme(cell);
        page.updateRowGraphemeFlag(self.screens.active.cursor.page_row);
    }

    // We don't need to update the style refs unless the
    // cell's new style will be different after writing.
    const style_changed = cell.style_id != self.screens.active.cursor.style_id;
    if (style_changed) {
        var page = self.screens.active.cursor.page_pin.node.page();

        // Release the old style.
        if (cell.style_id != style.default_id) {
            assert(self.screens.active.cursor.page_row.styled);
            page.styles.release(page.memory, cell.style_id);
        }
    }

    // Keep track if we had a hyperlink so we can unset it.
    const had_hyperlink = cell.hyperlink;

    // Write
    cell.* = .{
        .content_tag = .codepoint,
        .content = .{ .codepoint = .{ .data = c } },
        .style_id = self.screens.active.cursor.style_id,
        .wide = wide,
        .protected = self.screens.active.cursor.protected,
        .semantic_content = self.screens.active.cursor.semantic_content,
    };

    if (style_changed) {
        var page = self.screens.active.cursor.page_pin.node.page();

        // Use the new style.
        if (cell.style_id != style.default_id) {
            page.styles.use(page.memory, cell.style_id);
            self.screens.active.cursor.page_row.styled = true;
        }
    }

    // If this is a Kitty unicode placeholder then we need to mark the
    // row so that the renderer can lookup rows with these much faster.
    {
        if (c == kitty.graphics.unicode.placeholder) {
            @branchHint(.unlikely);
            self.screens.active.cursor.page_row.kitty_virtual_placeholder = true;
        }
    }

    // We check for an active hyperlink first because setHyperlink
    // handles clearing the old hyperlink and an optimization if we're
    // overwriting the same hyperlink.
    if (self.screens.active.cursor.hyperlink_id > 0) {
        self.screens.active.cursorSetHyperlink() catch |err| {
            @branchHint(.unlikely);
            log.warn("error reallocating for more hyperlink space, ignoring hyperlink err={}", .{err});

            // A partially successful grow can replace the page even when the
            // call fails, so `cell` may be stale here. The cursor pointers are
            // always reloaded, so read the cell through the cursor.
            assert(!self.screens.active.cursor.page_cell.hyperlink);
        };
    } else if (had_hyperlink) {
        // If the previous cell had a hyperlink then we need to clear it.
        var page = self.screens.active.cursor.page_pin.node.page();
        page.clearHyperlink(cell);
        page.updateRowHyperlinkFlag(self.screens.active.cursor.page_row);
    }
}

fn printWrap(self: *Terminal) !void {
    // We only mark that we soft-wrapped if we're at the edge of our
    // full screen. We don't mark the row as wrapped if we're in the
    // middle due to a right margin.
    const cursor: *Screen.Cursor = &self.screens.active.cursor;
    const mark_wrap = cursor.x == self.cols - 1;
    if (mark_wrap) cursor.page_row.wrap = true;

    // Get the old semantic prompt so we can extend it to the next
    // line. We need to do this before we index() because we may
    // modify memory.
    const old_semantic = cursor.semantic_content;
    const old_semantic_clear = cursor.semantic_content_clear_eol;

    // Move to the next line
    try self.index();
    self.screens.active.cursorHorizontalAbsolute(self.scrolling_region.left);

    // Our pointer should never move
    assert(cursor == &self.screens.active.cursor);

    // We always reset our semantic prompt state
    cursor.semantic_content = old_semantic;
    cursor.semantic_content_clear_eol = old_semantic_clear;
    switch (old_semantic) {
        .output, .input => {},
        .prompt => cursor.page_row.semantic_prompt = .prompt_continuation,
    }

    if (mark_wrap) {
        const row = self.screens.active.cursor.page_row;
        // Always mark the row as a continuation
        row.wrap_continuation = true;
    }

    // Assure that our screen is consistent
    self.screens.active.assertIntegrity();
}

/// Set the charset into the given slot.
pub fn configureCharset(self: *Terminal, slot: charsets.Slots, set: charsets.Charset) void {
    self.screens.active.charset.charsets.set(slot, set);
}

/// Invoke the charset in slot into the active slot. If single is true,
/// then this will only be invoked for a single character.
pub fn invokeCharset(
    self: *Terminal,
    active: charsets.ActiveSlot,
    slot: charsets.Slots,
    single: bool,
) void {
    if (single) {
        assert(active == .GL);
        self.screens.active.charset.single_shift = slot;
        return;
    }

    switch (active) {
        .GL => self.screens.active.charset.gl = slot,
        .GR => self.screens.active.charset.gr = slot,
    }
}

/// Carriage return moves the cursor to the first column.
pub fn carriageReturn(self: *Terminal) void {
    // Always reset pending wrap state
    self.screens.active.cursor.pending_wrap = false;

    // In origin mode we always move to the left margin
    self.screens.active.cursorHorizontalAbsolute(if (self.modes.get(.origin))
        self.scrolling_region.left
    else if (self.screens.active.cursor.x >= self.scrolling_region.left)
        self.scrolling_region.left
    else
        0);
}

/// Linefeed moves the cursor to the next line.
pub fn linefeed(self: *Terminal) !void {
    try self.index();
    if (self.modes.get(.linefeed)) self.carriageReturn();
}

/// Backspace moves the cursor back a column (but not less than 0).
pub fn backspace(self: *Terminal) void {
    self.cursorLeft(1);
}

/// Move the cursor up amount lines. If amount is greater than the maximum
/// move distance then it is internally adjusted to the maximum. If amount is
/// 0, adjust it to 1.
pub fn cursorUp(self: *Terminal, count_req: usize) void {
    // Always resets pending wrap
    self.screens.active.cursor.pending_wrap = false;

    // The maximum amount the cursor can move up depends on scrolling regions
    const max = if (self.screens.active.cursor.y >= self.scrolling_region.top)
        self.screens.active.cursor.y - self.scrolling_region.top
    else
        self.screens.active.cursor.y;
    const count = @min(max, @max(count_req, 1));

    // We can safely intCast below because of the min/max clamping we did above.
    self.screens.active.cursorUp(@intCast(count));
}

/// Move the cursor down amount lines. If amount is greater than the maximum
/// move distance then it is internally adjusted to the maximum. This sequence
/// will not scroll the screen or scroll region. If amount is 0, adjust it to 1.
pub fn cursorDown(self: *Terminal, count_req: usize) void {
    // Always resets pending wrap
    self.screens.active.cursor.pending_wrap = false;

    // The max the cursor can move to depends where the cursor currently is
    const max = if (self.screens.active.cursor.y <= self.scrolling_region.bottom)
        self.scrolling_region.bottom - self.screens.active.cursor.y
    else
        self.rows - self.screens.active.cursor.y - 1;
    const count = @min(max, @max(count_req, 1));
    self.screens.active.cursorDown(@intCast(count));
}

/// Move the cursor right amount columns. If amount is greater than the
/// maximum move distance then it is internally adjusted to the maximum.
/// This sequence will not scroll the screen or scroll region. If amount is
/// 0, adjust it to 1.
pub fn cursorRight(self: *Terminal, count_req: usize) void {
    // Always resets pending wrap
    self.screens.active.cursor.pending_wrap = false;

    // The max the cursor can move to depends where the cursor currently is
    const max = if (self.screens.active.cursor.x <= self.scrolling_region.right)
        self.scrolling_region.right - self.screens.active.cursor.x
    else
        self.cols - self.screens.active.cursor.x - 1;
    const count = @min(max, @max(count_req, 1));
    self.screens.active.cursorRight(@intCast(count));
}

/// Move the cursor to the left amount cells. If amount is 0, adjust it to 1.
pub fn cursorLeft(self: *Terminal, count_req: usize) void {
    // Wrapping behavior depends on various terminal modes
    const WrapMode = enum { none, reverse, reverse_extended };
    const wrap_mode: WrapMode = wrap_mode: {
        if (!self.modes.get(.wraparound)) break :wrap_mode .none;
        if (self.modes.get(.reverse_wrap_extended)) break :wrap_mode .reverse_extended;
        if (self.modes.get(.reverse_wrap)) break :wrap_mode .reverse;
        break :wrap_mode .none;
    };

    var count = @max(count_req, 1);

    // If we are in no wrap mode, then we move the cursor left and exit
    // since this is the fastest and most typical path.
    if (wrap_mode == .none) {
        self.screens.active.cursorLeft(@min(count, self.screens.active.cursor.x));
        self.screens.active.cursor.pending_wrap = false;
        return;
    }

    // If we have a pending wrap state and we are in either reverse wrap
    // modes then we decrement the amount we move by one to match xterm.
    if (self.screens.active.cursor.pending_wrap) {
        count -= 1;
        self.screens.active.cursor.pending_wrap = false;
        if (count == 0) return;
    }

    // The margins we can move to.
    const top = self.scrolling_region.top;
    const bottom = self.scrolling_region.bottom;
    const right_margin = self.scrolling_region.right;
    const left_margin = if (self.screens.active.cursor.x < self.scrolling_region.left)
        0
    else
        self.scrolling_region.left;

    // Handle some edge cases when our cursor is already on the left margin.
    if (self.screens.active.cursor.x == left_margin) {
        switch (wrap_mode) {
            // In reverse mode, if we're already before the top margin
            // then we just set our cursor to the top-left and we're done.
            .reverse => if (self.screens.active.cursor.y <= top) {
                self.screens.active.cursorAbsolute(left_margin, top);
                return;
            },

            // Handled in while loop
            .reverse_extended => {},

            // Handled above
            .none => unreachable,
        }
    }

    while (true) {
        // We can move at most to the left margin.
        const max = self.screens.active.cursor.x - left_margin;

        // We want to move at most the number of columns we have left
        // or our remaining count. Do the move.
        const amount = @min(max, count);
        count -= amount;
        self.screens.active.cursorLeft(amount);

        // If we have no more to move, then we're done.
        if (count == 0) break;

        // If we are at the top, then we are done.
        if (self.screens.active.cursor.y == top) {
            if (wrap_mode != .reverse_extended) break;

            self.screens.active.cursorAbsolute(right_margin, bottom);
            count -= 1;
            continue;
        }

        // UNDEFINED TERMINAL BEHAVIOR. This situation is not handled in xterm
        // and currently results in a crash in xterm. Given no other known
        // terminal [to me] implements XTREVWRAP2, I decided to just mimic
        // the behavior of xterm up and not including the crash by wrapping
        // up to the (0, 0) and stopping there. My reasoning is that for an
        // appropriately sized value of "count" this is the behavior that xterm
        // would have. This is unit tested.
        if (self.screens.active.cursor.y == 0) {
            assert(self.screens.active.cursor.x == left_margin);
            break;
        }

        // If our previous line is not wrapped then we are done.
        if (wrap_mode != .reverse_extended) {
            const prev_row = self.screens.active.cursorRowUp(1);
            if (!prev_row.wrap) break;
        }

        self.screens.active.cursorAbsolute(right_margin, self.screens.active.cursor.y - 1);
        count -= 1;
    }
}

/// Save cursor position and further state.
///
/// The primary and alternate screen have distinct save state. One saved state
/// is kept per screen (main / alternative). If for the current screen state
/// was already saved it is overwritten.
pub fn saveCursor(self: *Terminal) void {
    self.screens.active.saved_cursor = .{
        .x = self.screens.active.cursor.x,
        .y = self.screens.active.cursor.y,
        .style = self.screens.active.cursor.style,
        .protected = self.screens.active.cursor.protected,
        .pending_wrap = self.screens.active.cursor.pending_wrap,
        .origin = self.modes.get(.origin),
        .charset = self.screens.active.charset,
    };
}

/// Restore cursor position and other state.
///
/// The primary and alternate screen have distinct save state.
/// If no save was done before values are reset to their initial values.
pub fn restoreCursor(self: *Terminal) void {
    const saved: Screen.SavedCursor = self.screens.active.saved_cursor orelse .{
        .x = 0,
        .y = 0,
        .style = .{},
        .protected = false,
        .pending_wrap = false,
        .origin = false,
        .charset = .{},
    };

    // Set the style first because it can fail
    self.screens.active.cursor.style = saved.style;
    self.screens.active.manualStyleUpdate() catch |err| {
        // Regardless of the error here, we revert back to an unstyled
        // cursor. It is more important that the restore succeeds in
        // other attributes because terminals have no way to communicate
        // failure back.
        log.warn("restoreCursor error updating style err={}", .{err});
        const screen: *Screen = self.screens.active;
        screen.cursor.style = .{};
        self.screens.active.manualStyleUpdate() catch unreachable;
    };

    self.screens.active.charset = saved.charset;
    self.modes.set(.origin, saved.origin);
    self.screens.active.cursor.pending_wrap = saved.pending_wrap;
    self.screens.active.cursor.protected = saved.protected;
    self.screens.active.cursorAbsolute(
        @min(saved.x, self.cols - 1),
        @min(saved.y, self.rows - 1),
    );

    // Ensure our screen is consistent
    self.screens.active.assertIntegrity();
}

/// Set the character protection mode for the terminal.
pub fn setProtectedMode(self: *Terminal, mode: ansi.ProtectedMode) void {
    switch (mode) {
        .off => {
            self.screens.active.cursor.protected = false;

            // screen.protected_mode is NEVER reset to ".off" because
            // logic such as eraseChars depends on knowing what the
            // _most recent_ mode was.
        },

        .iso => {
            self.screens.active.cursor.protected = true;
            self.screens.active.protected_mode = .iso;
        },

        .dec => {
            self.screens.active.cursor.protected = true;
            self.screens.active.protected_mode = .dec;
        },
    }
}

/// Perform a semantic prompt command.
///
/// If there is an error, we do our best to get the terminal into
/// some coherent state, since callers typically can't handle errors
/// (since they're sending sequences via the pty).
pub fn semanticPrompt(
    self: *Terminal,
    cmd: osc.Command.SemanticPrompt,
) !void {
    switch (cmd.action) {
        .fresh_line => try self.semanticPromptFreshLine(),

        .fresh_line_new_prompt => {
            // "First do a fresh-line."
            try self.semanticPromptFreshLine();

            const screen: *Screen = self.screens.active;

            // "Subsequent text (until a OSC "133;B" or OSC "133;I" command)
            // is a prompt string (as if followed by OSC 133;P;k=i\007)."
            screen.cursorSetSemanticContent(.{
                .prompt = cmd.readOption(.prompt_kind) orelse .initial,
            });

            // This is a kitty-specific flag that notes that the shell
            // is NOT capable of redraw. Redraw defaults to true so this
            // usually just disables it, but either is possible.
            if (cmd.readOption(.redraw)) |v| {
                self.flags.shell_redraws_prompt = v;
            }

            click: {
                // Handle click_events as a priority over cl. click_events
                // is another Kitty-specific extension that converts clicks
                // within a prompt area to SGR mouse events and defers to the
                // shell to handle them.
                if (cmd.readOption(.click_events)) |v| {
                    screen.semantic_prompt.click = .{ .click_events = v };
                    break :click;
                }

                // If click_events was not set or disabled, fallback to `cl`.
                if (cmd.readOption(.cl)) |v| {
                    screen.semantic_prompt.click = .{ .cl = v };
                }
            }

            // The "aid" and "cl" options are also valid for this
            // command but we don't yet handle these in any meaningful way.
        },

        .new_command => {
            // Spec:
            // Same as OSC "133;A" but may first implicitly terminate a
            // previous command: if the options specify an aid and there
            // is an active (open) command with matching aid, finish the
            // innermost such command (as well as any other commands
            // nested more deeply). If no aid is specified, treat as an
            // aid whose value is the empty string.

            // Ghostty:
            // We don't currently do explicit command tracking in any way
            // so there is no need to terminate prior commands. We just
            // perform the `A` action.
            try self.semanticPrompt(.{
                .action = .fresh_line_new_prompt,
                .options_unvalidated = cmd.options_unvalidated,
            });
        },

        .prompt_start => {
            // Explicit start of prompt. Optional after an A or N command.
            // The k (kind) option specifies the type of prompt:
            // regular primary prompt (k=i or default),
            // right-side prompts (k=r), or prompts for continuation lines (k=c or k=s).
            self.screens.active.cursorSetSemanticContent(.{
                .prompt = cmd.readOption(.prompt_kind) orelse .initial,
            });
        },

        .end_prompt_start_input => {
            // End of prompt and start of user input, terminated by a OSC
            // "133;C" or another prompt (OSC "133;P").
            self.screens.active.cursorSetSemanticContent(.{
                .input = .clear_explicit,
            });
        },

        .end_prompt_start_input_terminate_eol => {
            // End of prompt and start of user input, terminated by end-of-line.
            self.screens.active.cursorSetSemanticContent(.{
                .input = .clear_eol,
            });
        },

        .end_input_start_output => {
            // "End of input, and start of output."
            self.screens.active.cursorSetSemanticContent(.output);

            // If our current row is marked as a prompt and we're
            // at column zero then we assume we're un-prompting. This
            // is a heuristic to deal with fish, mostly. The issue that
            // fish brings up is that it has no PS2 equivalent and its
            // builtin OSC133 marking doesn't output continuation lines
            // as k=s. So, we assume when we get a newline with a prompt
            // cursor that the new line is also a prompt. But fish changes
            // to output on the newline. So if we're at col 0 we just assume
            // we're overwriting the prompt.
            if (self.screens.active.cursor.page_row.semantic_prompt != .none and
                self.screens.active.cursor.x == 0)
            {
                self.screens.active.cursor.page_row.semantic_prompt = .none;
            }
        },

        .end_command => {
            // From a terminal state perspective, this doesn't really do
            // anything. Other terminals appear to do nothing here. I think
            // its reasonable at this point to reset our semantic content
            // state but the spec doesn't really say what to do.
            self.screens.active.cursorSetSemanticContent(.output);
        },
    }
}

// OSC 133;L
fn semanticPromptFreshLine(self: *Terminal) !void {
    const left_margin = if (self.screens.active.cursor.x < self.scrolling_region.left)
        0
    else
        self.scrolling_region.left;

    // Spec: "If the cursor is the initial column (left, assuming
    // left-to-right writing), do nothing" This specification is very under
    // specified. We are taking the liberty to assume that in a left/right
    // margin context, if the cursor is outside of the left margin, we treat
    // it as being at the left margin for the purposes of this command.
    // This is arbitrary. If someone has a better reasonable idea we can
    // apply it.
    if (self.screens.active.cursor.x == left_margin) return;

    self.carriageReturn();
    try self.index();
}

/// The semantic prompt type. This is used when tracking a line type and
/// requires integration with the shell. By default, we mark a line as "none"
/// meaning we don't know what type it is.
///
/// See: https://gitlab.freedesktop.org/Per_Bothner/specifications/blob/master/proposals/semantic-prompts.md
pub const SemanticPrompt = enum {
    prompt,
    prompt_continuation,
    input,
    command,
};

/// Returns true if the cursor is currently at a prompt. Another way to look
/// at this is it returns false if the shell is currently outputting something.
/// This requires shell integration (semantic prompt integration).
///
/// If the shell integration doesn't exist, this will always return false.
pub fn cursorIsAtPrompt(self: *Terminal) bool {
    // If we're on the secondary screen, we're never at a prompt.
    if (self.screens.active_key == .alternate) return false;

    // If our page row is a prompt then we're always at a prompt
    const cursor: *const Screen.Cursor = &self.screens.active.cursor;
    if (cursor.page_row.semantic_prompt != .none) return true;

    // Otherwise, determine our cursor state
    return switch (cursor.semantic_content) {
        .input, .prompt => true,
        .output => false,
    };
}

/// Horizontal tab moves the cursor to the next tabstop, clearing
/// the screen to the left the tabstop.
pub fn horizontalTab(self: *Terminal) void {
    while (self.screens.active.cursor.x < self.scrolling_region.right) {
        // Move the cursor right
        self.screens.active.cursorRight(1);

        // If the last cursor position was a tabstop we return. We do
        // "last cursor position" because we want a space to be written
        // at the tabstop unless we're at the end (the while condition).
        if (self.tabstops.get(self.screens.active.cursor.x)) return;
    }
}

// Same as horizontalTab but moves to the previous tabstop instead of the next.
pub fn horizontalTabBack(self: *Terminal) void {
    // With origin mode enabled, our leftmost limit is the left margin.
    const left_limit = if (self.modes.get(.origin)) self.scrolling_region.left else 0;

    while (true) {
        // If we're already at the edge of the screen, then we're done.
        if (self.screens.active.cursor.x <= left_limit) return;

        // Move the cursor left
        self.screens.active.cursorLeft(1);
        if (self.tabstops.get(self.screens.active.cursor.x)) return;
    }
}

/// Clear tab stops.
pub fn tabClear(self: *Terminal, cmd: csi.TabClear) void {
    switch (cmd) {
        .current => self.tabstops.unset(self.screens.active.cursor.x),
        .all => self.tabstops.reset(0),
        else => log.warn("invalid or unknown tab clear setting: {}", .{cmd}),
    }
}

/// Set a tab stop on the current cursor.
/// TODO: test
pub fn tabSet(self: *Terminal) void {
    self.tabstops.set(self.screens.active.cursor.x);
}

/// TODO: test
pub fn tabReset(self: *Terminal) void {
    self.tabstops.reset(TABSTOP_INTERVAL);
}

/// Move the cursor to the next line in the scrolling region, possibly scrolling.
///
/// If the cursor is outside of the scrolling region: move the cursor one line
/// down if it is not on the bottom-most line of the screen.
///
/// If the cursor is inside the scrolling region:
///   If the cursor is on the bottom-most line of the scrolling region:
///     invoke scroll up with amount=1
///   If the cursor is not on the bottom-most line of the scrolling region:
///     move the cursor one line down
///
/// This unsets the pending wrap state without wrapping.
pub fn index(self: *Terminal) !void {
    self.accessibility_revision +%= 1;
    const screen: *Screen = self.screens.active;

    // Unset pending wrap state
    screen.cursor.pending_wrap = false;

    // We handle our cursor semantic prompt state AFTER doing the
    // scrolling, because we may need to apply to new rows.
    defer if (screen.cursor.semantic_content != .output) {
        @branchHint(.unlikely);

        // Always reset any semantic content clear-eol state.
        //
        // The specification is not clear what "end-of-line" means. If we
        // discover that there are more scenarios we should be unsetting
        // this we should document and test it.
        if (screen.cursor.semantic_content_clear_eol) {
            screen.cursor.semantic_content = .output;
            screen.cursor.semantic_content_clear_eol = false;
        } else {
            // If we aren't clearing our state at EOL and we're not output,
            // then we mark the new row as a prompt continuation. This is
            // to work around shells that don't send OSC 133 k=s sequences
            // for continuations.
            //
            // This can be a false positive if the shell changes content
            // type later and outputs something. We handle that in the
            // semanticPrompt function.
            screen.cursor.page_row.semantic_prompt = .prompt_continuation;
        }
    } else {
        // This should never be set in the output mode.
        assert(!screen.cursor.semantic_content_clear_eol);
    };

    // Outside of the scroll region we move the cursor one line down.
    if (screen.cursor.y < self.scrolling_region.top or
        screen.cursor.y > self.scrolling_region.bottom)
    {
        // We only move down if we're not already at the bottom of
        // the screen.
        if (screen.cursor.y < self.rows - 1) {
            screen.cursorDown(1);
        }

        return;
    }

    // If the cursor is inside the scrolling region and on the bottom-most
    // line, then we scroll up. If our scrolling region is the full screen
    // we create scrollback.
    if (screen.cursor.y == self.scrolling_region.bottom and
        screen.cursor.x >= self.scrolling_region.left and
        screen.cursor.x <= self.scrolling_region.right)
    {
        {
            // Scrolling dirties the images because it updates their placements pins.
            screen.kitty_images.dirty = true;
        }

        // If our scrolling region is at the top, we create scrollback,
        // but only if our screen retains scrollback. If our screen
        // doesn't retain scrollback (e.g. the alternate screen) then
        // creating scrollback is pure overhead: the rows are never
        // visible and are simply pruned later. In that case we use the
        // in-place region scroll below, unless the region is a single
        // row (a one row screen) which cursorScrollRegionUp can't
        // handle (and cursorDownScroll special-cases).
        if (self.scrolling_region.top == 0 and
            self.scrolling_region.left == 0 and
            self.scrolling_region.right == self.cols - 1 and
            (!screen.no_scrollback or
                self.scrolling_region.bottom == 0))
        {
            // If a bottom margin is set, kitty image placements may
            // need adjusting around the scroll. The rare placements-
            // present case is handled out of line so this hot path
            // only pays a count check (a load from a cache line we
            // already write, above).
            {
                if (screen.kitty_images.placements.count() != 0) {
                    @branchHint(.unlikely);
                    try self.indexScrollWithImages(.window_shift);
                    self.recordScroll(self.scrolling_region.top, -1);
                    return;
                }
            }

            try screen.cursorScrollAbove();
            self.recordScroll(self.scrolling_region.top, -1);
            return;
        }

        // Slow path for left and right scrolling region margins.
        // scrollUp handles the kitty image adjustment itself.
        if (self.scrolling_region.left != 0 or
            self.scrolling_region.right != self.cols - 1)
        {
            try self.scrollUp(1);
            return;
        }

        // Kitty image placements may need adjusting around the scroll;
        // handled out of line like the scrollback path above.
        {
            if (screen.kitty_images.placements.count() != 0) {
                @branchHint(.unlikely);
                try self.indexScrollWithImages(.in_place);
                self.recordScroll(self.scrolling_region.top, -1);
                return;
            }
        }

        // Otherwise use a fast path function to efficiently scroll
        // the contents of the scrolling region.
        try screen.cursorScrollRegionUp(
            self.scrolling_region.bottom - self.scrolling_region.top,
        );
        self.recordScroll(self.scrolling_region.top, -1);

        return;
    }

    // Increase cursor by 1, maximum to bottom of scroll region
    if (screen.cursor.y < self.scrolling_region.bottom) {
        screen.cursorDown(1);
    }
}

/// The operation when we have Kitty image placements during index.
/// Split out of index() so its hot paths don't carry the adjustment
/// state in their stack frame, which measurably slows the scroll
/// hot path.
fn indexScrollWithImages(
    self: *Terminal,
    comptime op: kitty.graphics.ImageStorage.ScrollOp,
) !void {
    var kitty_scroll = self.kittyScrollMarginsBegin(-1, op);
    defer if (kitty_scroll) |*state| state.end();
    switch (op) {
        .window_shift => try self.screens.active.cursorScrollAbove(),
        .in_place => try self.screens.active.cursorScrollRegionUp(
            self.scrolling_region.bottom - self.scrolling_region.top,
        ),
    }
}

const KittyScrollMargins = kitty.graphics.ImageStorage.ScrollMargins;

/// Begin adjusting kitty image placements for a scroll of the
/// scrolling region by delta rows (negative moves content up). If
/// adjustment is needed this returns state whose end() must be called
/// after the scroll's row operations complete (see
/// ImageStorage.scrollMarginsBegin for why this is two phases). This
/// returns null when the scrolling region is the full screen, because
/// placements then follow their anchored rows via pin tracking which
/// matches kitty's marginless behavior.
///
/// Callers must comptime-gate on /// check that placements exist before calling, which keeps the cost
/// on the hot scroll paths cheap.
fn kittyScrollMarginsBegin(
    self: *Terminal,
    delta: isize,
    op: kitty.graphics.ImageStorage.ScrollOp,
) ?kitty.graphics.ImageStorage.ScrollMargins {
    @branchHint(.cold);

    // Full-screen scrolls need no adjustment: placements follow their
    // anchored rows (possibly into the scrollback) via pin tracking.
    if (self.scrolling_region.top == 0 and
        self.scrolling_region.bottom == self.rows - 1 and
        self.scrolling_region.left == 0 and
        self.scrolling_region.right == self.cols - 1) return null;

    const screen: *Screen = self.screens.active;
    return screen.kitty_images.scrollMarginsBegin(
        self.io(),
        self,
        delta,
        op,
    );
}

/// Move the cursor to the previous line in the scrolling region, possibly
/// scrolling.
///
/// If the cursor is outside of the scrolling region, move the cursor one
/// line up if it is not on the top-most line of the screen.
///
/// If the cursor is inside the scrolling region:
///
///   * If the cursor is on the top-most line of the scrolling region:
///     invoke scroll down with amount=1
///   * If the cursor is not on the top-most line of the scrolling region:
///     move the cursor one line up
pub fn reverseIndex(self: *Terminal) void {
    self.accessibility_revision +%= 1;
    if (self.screens.active.cursor.y != self.scrolling_region.top or
        self.screens.active.cursor.x < self.scrolling_region.left or
        self.screens.active.cursor.x > self.scrolling_region.right)
    {
        self.cursorUp(1);
        return;
    }

    self.scrollDown(1);
}

/// Set Cursor Position. Move cursor to the position indicated
/// by row and column (1-indexed). If column is 0, it is adjusted to 1.
/// If column is greater than the right-most column it is adjusted to
/// the right-most column. If row is 0, it is adjusted to 1. If row is
/// greater than the bottom-most row it is adjusted to the bottom-most
/// row.
pub fn setCursorPos(self: *Terminal, row_req: usize, col_req: usize) void {
    // If cursor origin mode is set the cursor row will be moved relative to
    // the top margin row and adjusted to be above or at bottom-most row in
    // the current scroll region.
    //
    // If origin mode is set and left and right margin mode is set the cursor
    // will be moved relative to the left margin column and adjusted to be on
    // or left of the right margin column.
    const params: struct {
        x_offset: size.CellCountInt = 0,
        y_offset: size.CellCountInt = 0,
        x_max: size.CellCountInt,
        y_max: size.CellCountInt,
    } = if (self.modes.get(.origin)) .{
        .x_offset = self.scrolling_region.left,
        .y_offset = self.scrolling_region.top,
        .x_max = self.scrolling_region.right + 1, // We need this 1-indexed
        .y_max = self.scrolling_region.bottom + 1, // We need this 1-indexed
    } else .{
        .x_max = self.cols,
        .y_max = self.rows,
    };

    // Unset pending wrap state
    self.screens.active.cursor.pending_wrap = false;

    // Calculate our new x/y
    const row = if (row_req == 0) 1 else row_req;
    const col = if (col_req == 0) 1 else col_req;
    const x = @min(params.x_max, col +| params.x_offset) -| 1;
    const y = @min(params.y_max, row +| params.y_offset) -| 1;

    // If the y is unchanged then this is fast pointer math
    if (y == self.screens.active.cursor.y) {
        if (x > self.screens.active.cursor.x) {
            self.screens.active.cursorRight(x - self.screens.active.cursor.x);
        } else {
            self.screens.active.cursorLeft(self.screens.active.cursor.x - x);
        }

        return;
    }

    // If everything changed we do an absolute change which is slightly slower
    self.screens.active.cursorAbsolute(x, y);
    // log.info("set cursor position: col={} row={}", .{ self.screens.active.cursor.x, self.screens.active.cursor.y });
}

/// Set Top and Bottom Margins If bottom is not specified, 0 or bigger than
/// the number of the bottom-most row, it is adjusted to the number of the
/// bottom most row.
///
/// If top < bottom set the top and bottom row of the scroll region according
/// to top and bottom and move the cursor to the top-left cell of the display
/// (when in cursor origin mode is set to the top-left cell of the scroll region).
///
/// Otherwise: Set the top and bottom row of the scroll region to the top-most
/// and bottom-most line of the screen.
///
/// Top and bottom are 1-indexed.
pub fn setTopAndBottomMargin(self: *Terminal, top_req: usize, bottom_req: usize) void {
    const top = @max(1, top_req);
    const bottom = @min(self.rows, if (bottom_req == 0) self.rows else bottom_req);
    if (top >= bottom) return;

    self.scrolling_region.top = @intCast(top - 1);
    self.scrolling_region.bottom = @intCast(bottom - 1);
    self.setCursorPos(1, 1);
}

/// DECSLRM
pub fn setLeftAndRightMargin(self: *Terminal, left_req: usize, right_req: usize) void {
    // We must have this mode enabled to do anything
    if (!self.modes.get(.enable_left_and_right_margin)) return;

    const left = @max(1, left_req);
    const right = @min(self.cols, if (right_req == 0) self.cols else right_req);
    if (left >= right) return;

    self.scrolling_region.left = @intCast(left - 1);
    self.scrolling_region.right = @intCast(right - 1);
    self.setCursorPos(1, 1);
}

/// Scroll the text down by one row.
pub fn scrollDown(self: *Terminal, count: usize) void {
    self.accessibility_revision +%= 1;
    // Preserve our x/y to restore.
    const old_x = self.screens.active.cursor.x;
    const old_y = self.screens.active.cursor.y;
    const old_wrap = self.screens.active.cursor.pending_wrap;
    defer {
        self.screens.active.cursorAbsolute(old_x, old_y);
        self.screens.active.cursor.pending_wrap = old_wrap;
    }

    // If margins are set and kitty image placements exist, they need
    // adjusting around the scroll. Note this wraps scrollDown and NOT
    // insertLines: kitty scrolls images for SD/RI but leaves them
    // alone for IL/DL.
    var kitty_scroll: ?KittyScrollMargins = null;
    defer if (kitty_scroll) |*state| state.end();
    {
        if (self.screens.active.kitty_images.placements.count() != 0) {
            @branchHint(.unlikely);
            const region_height: usize =
                @as(usize, self.scrolling_region.bottom - self.scrolling_region.top) + 1;
            kitty_scroll = self.kittyScrollMarginsBegin(
                @intCast(@min(count, region_height)),
                .in_place,
            );
        }
    }

    // Move to the top of the scroll region
    self.screens.active.cursorAbsolute(self.scrolling_region.left, self.scrolling_region.top);
    self.insertLines(count);
}

/// Removes amount lines from the top of the scroll region. The remaining lines
/// to the bottom margin are shifted up and space from the bottom margin up
/// is filled with empty lines.
///
/// The new lines are created according to the current SGR state.
///
/// Does not change the (absolute) cursor position.
pub fn scrollUp(self: *Terminal, count: usize) !void {
    self.accessibility_revision +%= 1;
    // Preserve our x/y to restore.
    const old_x = self.screens.active.cursor.x;
    const old_y = self.screens.active.cursor.y;
    const old_wrap = self.screens.active.cursor.pending_wrap;
    defer {
        self.screens.active.cursorAbsolute(old_x, old_y);
        self.screens.active.cursor.pending_wrap = old_wrap;
    }

    // If margins are set and kitty image placements exist, they need
    // adjusting around the scroll. Note this wraps scrollUp and NOT
    // deleteLines: kitty scrolls images for SU/IND but leaves them
    // alone for IL/DL.
    var kitty_scroll: ?KittyScrollMargins = null;
    defer if (kitty_scroll) |*state| state.end();
    {
        if (self.screens.active.kitty_images.placements.count() != 0) {
            @branchHint(.unlikely);

            // The op must mirror the branch below: the scrollback path
            // shifts the active window while the deleteLines path
            // moves rows in place.
            const region_height: usize =
                @as(usize, self.scrolling_region.bottom - self.scrolling_region.top) + 1;
            kitty_scroll = self.kittyScrollMarginsBegin(
                -@as(isize, @intCast(@min(count, region_height))),
                if (self.scrolling_region.top == 0 and
                    self.scrolling_region.left == 0 and
                    self.scrolling_region.right == self.cols - 1 and
                    (!self.screens.active.no_scrollback or
                        self.scrolling_region.bottom == self.rows - 1))
                    .window_shift
                else
                    .in_place,
            );
        }
    }

    // If our scroll region is at the top and we have no left/right
    // margins then we move the scrolled out text into the scrollback.
    //
    // If our screen doesn't retain scrollback (e.g. the alternate
    // screen) then creating scrollback is pure overhead, so we use the
    // deleteLines path below instead, unless the region is the full
    // screen where cursorScrollAbove has a specialized fast path
    // (cursorDownScroll) for scrolling without scrollback.
    if (self.scrolling_region.top == 0 and
        self.scrolling_region.left == 0 and
        self.scrolling_region.right == self.cols - 1 and
        (!self.screens.active.no_scrollback or
            self.scrolling_region.bottom == self.rows - 1))
    {
        // Scrolling dirties the images because it updates their placements pins.
        {
            self.screens.active.kitty_images.dirty = true;
        }

        // Clamp count to the scroll region height.
        const region_height = self.scrolling_region.bottom + 1;
        const adjusted_count = @min(count, region_height);

        // TODO: Create an optimized version that can scroll N times
        // This isn't critical because in most cases, scrollUp is used
        // with count=1, but it's still a big optimization opportunity.

        // Move our cursor to the bottom of the scroll region so we can
        // use the cursorScrollAbove function to create scrollback
        self.screens.active.cursorAbsolute(0, self.scrolling_region.bottom);
        for (0..adjusted_count) |_| try self.screens.active.cursorScrollAbove();
        self.recordScroll(self.scrolling_region.top, -@as(i32, @intCast(adjusted_count)));
        return;
    }

    // Move to the top of the scroll region
    self.screens.active.cursorAbsolute(self.scrolling_region.left, self.scrolling_region.top);
    self.deleteLines(count);
}

/// Options for scrolling the viewport of the terminal grid.
pub const ScrollViewport = union(Tag) {
    /// Scroll to the top of the scrollback
    top,

    /// Scroll to the bottom, i.e. the top of the active area
    bottom,

    /// Scroll by some delta amount, up is negative.
    delta: isize,

    /// Scroll to the given absolute row offset from the top of the
    /// scrollable area. A value of zero is the top row. The requested
    /// row becomes the first visible row of the viewport, clamped so
    /// the viewport never scrolls beyond the top of the active area.
    /// This is the same row space as PageList.Scrollbar offset.
    row: usize,

    pub const Tag = enum(u2) {
        top = 0,
        bottom = 1,
        delta = 2,
        row = 3,
    };
};

/// Scroll the viewport of the terminal grid.
pub fn scrollViewport(self: *Terminal, behavior: ScrollViewport) void {
    self.scroll_state.viewport_serial +%= 1;
    self.scroll_state.viewport_animate = false;
    self.scroll_state.viewport_fraction = 0;
    self.screens.active.scroll(switch (behavior) {
        .top => .{ .top = {} },
        .bottom => .{ .active = {} },
        .delta => |delta| .{ .delta_row = delta },
        .row => |row| .{ .row = row },
    });
}

/// Return the current compression activity value.
///
/// Callers should schedule a `compress` call whenever this value changes. The
/// direction of the change has no meaning; this is an opaque change token
/// rather than a monotonic sequence exposed by Terminal.
///
/// It is up to the terminal what it decides to compress, but currently
/// we compress cold (non-viewed, non-editable) scrollback history on
/// the primary screen.
///
/// Note that compression requires specific system features, namely
/// the ability to retain virtual memory allocations while discarding their
/// physical memory backings. Callers must still use `compress` to determine
/// whether compression is supported on the current target.
pub fn compressionActivity(self: *const Terminal) u64 {
    const state = &self.screens.get(.primary).?.pages.page_compression;
    // For now we don't use the extra 16 bits.
    return @as(u64, state.activity_serial);
}

/// The amount of compression work performed by `compress` before returning.
///
/// The declaration order is part of the libghostty-vt C ABI. Removed values
/// must leave a `null` hole so later values retain their integer values.
pub const CompressionMode = enum(u1) {
    incremental = 0,
    full = 1,
};

/// The scheduling result of a `compress` call.
///
/// The declaration order is part of the libghostty-vt C ABI. Removed values
/// must leave a `null` hole so later values retain their integer values.
pub const CompressionResult = enum(u2) {
    unsupported = 0,
    pending = 1,
    complete = 2,
};

/// Compress cold memory to save resident memory space.
///
/// Full compression does a full pass compressing everything it can before
/// returning. This is not recommended for interactive terminals because
/// compression is relatively slow and with large scrollbacks this can cause
/// stalls.
///
/// Incremental compression bounds itself on how much data it can look
/// up to compress and how much compression work it does before returning.
/// It is stateful (we maintain the state) and the return value tells callers
/// whether they should continue calling it in the future.
///
/// Callers should schedule compression when it doesn't impact user
/// experience, for example during idle times.
pub fn compress(
    self: *Terminal,
    mode: CompressionMode,
) CompressionResult {
    const pages = &self.screens.get(.primary).?.pages;
    const result = switch (mode) {
        .incremental => pages.compress(.incremental),
        .full => pages.compress(.full),
    };

    return switch (result) {
        .unsupported => .unsupported,
        .pending => .pending,
        .complete => .complete,
    };
}

/// To be called before shifting a row (as in insertLines and deleteLines)
///
/// Takes care of boundary conditions such as potentially split wide chars
/// across scrolling region boundaries and orphaned spacer heads at line
/// ends.
fn rowWillBeShifted(
    self: *Terminal,
    page: *Page,
    row: *Row,
) void {
    const cells = row.cells.ptr(page.memory.ptr);

    // If our scrolling region includes the rightmost column then we
    // need to turn any spacer heads in to normal empty cells, since
    // once we move them they no longer correspond with soft-wrapped
    // wide characters.
    //
    // If it contains either of the 2 leftmost columns, then the wide
    // characters in the first column which may be associated with a
    // spacer head will be either moved or cleared, so we also need
    // to turn the spacer heads in to empty cells in that case.
    if (self.scrolling_region.right == self.cols - 1 or
        self.scrolling_region.left < 2)
    {
        const end_cell: *Cell = &cells[page.size.cols - 1];
        if (end_cell.wide == .spacer_head) {
            end_cell.wide = .narrow;
        }
    }

    // If the leftmost or rightmost cells of our scrolling region
    // are parts of wide chars, we need to clear the cells' contents
    // since they'd be split by the move.
    const left_cell: *Cell = &cells[self.scrolling_region.left];
    const right_cell: *Cell = &cells[self.scrolling_region.right];

    if (left_cell.wide == .spacer_tail) {
        const wide_cell: *Cell = &cells[self.scrolling_region.left - 1];
        if (wide_cell.hasGrapheme()) {
            page.clearGrapheme(wide_cell);
            page.updateRowGraphemeFlag(row);
        }
        wide_cell.content.codepoint = .{ .data = 0 };
        wide_cell.wide = .narrow;
        left_cell.wide = .narrow;
    }

    if (right_cell.wide == .wide) {
        const tail_cell: *Cell = &cells[self.scrolling_region.right + 1];
        if (right_cell.hasGrapheme()) {
            page.clearGrapheme(right_cell);
            page.updateRowGraphemeFlag(row);
        }
        right_cell.content.codepoint.data = 0;
        right_cell.wide = .narrow;
        tail_cell.wide = .narrow;
    }
}

/// Renew every live page generation in an inclusive range before a full-width
/// line operation moves logical rows between their coordinates.
fn invalidateFullWidthRowRange(
    self: *Terminal,
    first: *PageList.List.Node,
    last: *PageList.List.Node,
) void {
    var node = first;
    while (true) : (node = node.next.?) {
        // Full-width line movement remaps cached row coordinates in this page.
        self.screens.active.pages.invalidateNodeLayout(node);
        if (node == last) break;
    }
}

// TODO(qwerasd): `insertLines` and `deleteLines` are 99% identical,
// the majority of their logic can (and should) be abstracted in to
// a single shared helper function, probably on `Screen` not here.
// I'm just too lazy to do that rn :p

/// Insert amount lines at the current cursor row. The contents of the line
/// at the current cursor row and below (to the bottom-most line in the
/// scrolling region) are shifted down by amount lines. The contents of the
/// amount bottom-most lines in the scroll region are lost.
///
/// This unsets the pending wrap state without wrapping. If the current cursor
/// position is outside of the current scroll region it does nothing.
///
/// If amount is greater than the remaining number of lines in the scrolling
/// region it is adjusted down (still allowing for scrolling out every remaining
/// line in the scrolling region)
///
/// In left and right margin mode the margins are respected; lines are only
/// scrolled in the scroll region.
///
/// All cleared space is colored according to the current SGR state.
///
/// Moves the cursor to the left margin.
pub fn insertLines(self: *Terminal, count: usize) void {
    self.accessibility_revision +%= 1;
    // Rare, but happens
    if (count == 0) return;

    // If the cursor is outside the scroll region we do nothing.
    if (self.screens.active.cursor.y < self.scrolling_region.top or
        self.screens.active.cursor.y > self.scrolling_region.bottom or
        self.screens.active.cursor.x < self.scrolling_region.left or
        self.screens.active.cursor.x > self.scrolling_region.right) return;

    {
        // Scrolling dirties the images because it updates their placements pins.
        self.screens.active.kitty_images.dirty = true;
    }

    // At the end we need to return the cursor to the row it started on.
    const start_y = self.screens.active.cursor.y;
    defer {
        self.screens.active.cursorAbsolute(self.scrolling_region.left, start_y);

        // Always unset pending wrap
        self.screens.active.cursor.pending_wrap = false;
    }

    // We have a slower path if we have left or right scroll margins.
    const left_right = self.scrolling_region.left > 0 or
        self.scrolling_region.right < self.cols - 1;

    // Remaining rows from our cursor to the bottom of the scroll region.
    const rem = self.scrolling_region.bottom - self.screens.active.cursor.y + 1;

    // We can only insert lines up to our remaining lines in the scroll
    // region. So we take whichever is smaller.
    const adjusted_count = @min(count, rem);
    self.recordScroll(start_y, @intCast(adjusted_count));

    // Create a new tracked pin which we'll use to navigate the page list
    // so that if we need to adjust capacity it will be properly tracked.
    var cur_p = self.screens.active.pages.trackPin(
        self.screens.active.cursor.page_pin.down(rem - 1).?,
    ) catch |err| {
        comptime assert(@TypeOf(err) == error{OutOfMemory});

        // This error scenario means that our GPA is OOM. This is not a
        // situation we can gracefully handle. We can't just ignore insertLines
        // because it'll result in a corrupted screen. Ideally in the future
        // we flag the state as broken and show an error message to the user.
        // For now, we panic.
        log.err("insertLines trackPin error err={}", .{err});
        @panic("insertLines trackPin OOM");
    };
    defer self.screens.active.pages.untrackPin(cur_p);

    // Partial-width margins edit cells in stable rows; full-width moves rows.
    if (!left_right) self.invalidateFullWidthRowRange(
        self.screens.active.cursor.page_pin.node,
        cur_p.node,
    );

    // Our current y position relative to the cursor
    var y: usize = rem;

    // Traverse from the bottom up
    while (y > 0) {
        const cur_rac = cur_p.rowAndCell();
        const cur_row: *Row = cur_rac.row;

        // If this is one of the lines we need to shift, do so
        if (y > adjusted_count) {
            const off_p = cur_p.up(adjusted_count).?;
            const off_rac = off_p.rowAndCell();
            const off_row: *Row = off_rac.row;

            self.rowWillBeShifted(cur_p.node.page(), cur_row);
            self.rowWillBeShifted(off_p.node.page(), off_row);

            // If our scrolling region is full width, then we unset wrap.
            if (!left_right) {
                off_row.wrap = false;
                cur_row.wrap = false;
                off_row.wrap_continuation = false;
                cur_row.wrap_continuation = false;
            }

            const src_p = off_p;
            const src_row = off_row;
            const dst_p = cur_p;
            const dst_row = cur_row;

            // If our page doesn't match, then we need to do a copy from
            // one page to another. This is the slow path.
            if (src_p.node != dst_p.node) {
                // The copy may replace the destination node in order
                // to increase its capacity. Our pins are tracked so
                // they update automatically; we can discard the
                // replacement because the remainder of this iteration
                // only accesses rows through the pins.
                _ = self.screens.active.clonePartialRowGrowCapacity(
                    dst_p.node,
                    dst_p.y,
                    src_p.node.page(),
                    src_row,
                    self.scrolling_region.left,
                    self.scrolling_region.right + 1,
                );
            } else {
                if (!left_right) {
                    // Swap the src/dst cells. This ensures that our dst gets the
                    // proper shifted rows and src gets non-garbage cell data that
                    // we can clear.
                    const dst = dst_row.*;
                    dst_row.* = src_row.*;
                    src_row.* = dst;

                    // Ensure what we did didn't corrupt the page
                    cur_p.node.page().assertIntegrity();
                } else {
                    // Left/right scroll margins we have to
                    // copy cells, which is much slower...
                    const page = cur_p.node.page();
                    page.moveCells(
                        src_row,
                        self.scrolling_region.left,
                        dst_row,
                        self.scrolling_region.left,
                        (self.scrolling_region.right - self.scrolling_region.left) + 1,
                    );
                }
            }
        } else {
            // Clear the cells for this row, it has been shifted.
            self.rowWillBeShifted(cur_p.node.page(), cur_row);
            const page = cur_p.node.page();
            const cells = page.getCells(cur_row);
            self.screens.active.clearCells(
                page,
                cur_row,
                cells[self.scrolling_region.left .. self.scrolling_region.right + 1],
            );

            // With a full-width scroll region the entire row is a
            // fresh blank row: reset the metadata so nothing (wrap
            // state, semantic prompt) is retained from the row whose
            // storage it recycles. With left/right margins the row
            // keeps content outside the margins so the metadata is
            // preserved, matching the shift case above.
            if (!left_right) cur_row.reset();
        }

        // Mark the row as dirty
        cur_p.markDirty();

        // We have successfully processed a line.
        y -= 1;
        // Move our pin up to the next row.
        if (cur_p.up(1)) |p| cur_p.* = p;
    }
}

/// Removes amount lines from the current cursor row down. The remaining lines
/// to the bottom margin are shifted up and space from the bottom margin up is
/// filled with empty lines.
///
/// If the current cursor position is outside of the current scroll region it
/// does nothing. If amount is greater than the remaining number of lines in the
/// scrolling region it is adjusted down.
///
/// In left and right margin mode the margins are respected; lines are only
/// scrolled in the scroll region.
///
/// If the cell movement splits a multi cell character that character cleared,
/// by replacing it by spaces, keeping its current attributes. All other
/// cleared space is colored according to the current SGR state.
///
/// Moves the cursor to the left margin.
pub fn deleteLines(self: *Terminal, count: usize) void {
    self.accessibility_revision +%= 1;
    // Rare, but happens
    if (count == 0) return;

    // If the cursor is outside the scroll region we do nothing.
    if (self.screens.active.cursor.y < self.scrolling_region.top or
        self.screens.active.cursor.y > self.scrolling_region.bottom or
        self.screens.active.cursor.x < self.scrolling_region.left or
        self.screens.active.cursor.x > self.scrolling_region.right) return;

    {
        // Scrolling dirties the images because it updates their placements pins.
        self.screens.active.kitty_images.dirty = true;
    }

    // At the end we need to return the cursor to the row it started on.
    const start_y = self.screens.active.cursor.y;
    defer {
        self.screens.active.cursorAbsolute(self.scrolling_region.left, start_y);
        // Always unset pending wrap
        self.screens.active.cursor.pending_wrap = false;
    }

    // We have a slower path if we have left or right scroll margins.
    const left_right = self.scrolling_region.left > 0 or
        self.scrolling_region.right < self.cols - 1;

    // Remaining rows from our cursor to the bottom of the scroll region.
    const rem = self.scrolling_region.bottom - self.screens.active.cursor.y + 1;

    // We can only insert lines up to our remaining lines in the scroll
    // region. So we take whichever is smaller.
    const adjusted_count = @min(count, rem);
    self.recordScroll(start_y, -@as(i32, @intCast(adjusted_count)));

    // Create a new tracked pin which we'll use to navigate the page list
    // so that if we need to adjust capacity it will be properly tracked.
    var cur_p = self.screens.active.pages.trackPin(
        self.screens.active.cursor.page_pin.*,
    ) catch |err| {
        // See insertLines
        comptime assert(@TypeOf(err) == error{OutOfMemory});
        log.err("deleteLines trackPin error err={}", .{err});
        @panic("deleteLines trackPin OOM");
    };
    defer self.screens.active.pages.untrackPin(cur_p);

    // Partial-width margins edit cells in stable rows; full-width moves rows.
    if (!left_right) self.invalidateFullWidthRowRange(
        cur_p.node,
        cur_p.down(rem - 1).?.node,
    );

    // Our current y position relative to the cursor
    var y: usize = 0;

    // Traverse from the top down
    while (y < rem) {
        const cur_rac = cur_p.rowAndCell();
        const cur_row: *Row = cur_rac.row;

        // If this is one of the lines we need to shift, do so
        if (y < rem - adjusted_count) {
            const off_p = cur_p.down(adjusted_count).?;
            const off_rac = off_p.rowAndCell();
            const off_row: *Row = off_rac.row;

            self.rowWillBeShifted(cur_p.node.page(), cur_row);
            self.rowWillBeShifted(off_p.node.page(), off_row);

            // If our scrolling region is full width, then we unset wrap.
            if (!left_right) {
                off_row.wrap = false;
                cur_row.wrap = false;
                off_row.wrap_continuation = false;
                cur_row.wrap_continuation = false;
            }

            const src_p = off_p;
            const src_row = off_row;
            const dst_p = cur_p;
            const dst_row = cur_row;

            // If our page doesn't match, then we need to do a copy from
            // one page to another. This is the slow path.
            if (src_p.node != dst_p.node) {
                // The copy may replace the destination node in order
                // to increase its capacity. Our pins are tracked so
                // they update automatically; we can discard the
                // replacement because the remainder of this iteration
                // only accesses rows through the pins.
                _ = self.screens.active.clonePartialRowGrowCapacity(
                    dst_p.node,
                    dst_p.y,
                    src_p.node.page(),
                    src_row,
                    self.scrolling_region.left,
                    self.scrolling_region.right + 1,
                );
            } else {
                if (!left_right) {
                    // Swap the src/dst cells. This ensures that our dst gets the
                    // proper shifted rows and src gets non-garbage cell data that
                    // we can clear.
                    const dst = dst_row.*;
                    dst_row.* = src_row.*;
                    src_row.* = dst;

                    // Ensure what we did didn't corrupt the page
                    cur_p.node.page().assertIntegrity();
                } else {
                    // Left/right scroll margins we have to
                    // copy cells, which is much slower...
                    const page = cur_p.node.page();
                    page.moveCells(
                        src_row,
                        self.scrolling_region.left,
                        dst_row,
                        self.scrolling_region.left,
                        (self.scrolling_region.right - self.scrolling_region.left) + 1,
                    );
                }
            }
        } else {
            // Clear the cells for this row, it's from out of bounds.
            self.rowWillBeShifted(cur_p.node.page(), cur_row);
            const page = cur_p.node.page();
            const cells = page.getCells(cur_row);
            self.screens.active.clearCells(
                page,
                cur_row,
                cells[self.scrolling_region.left .. self.scrolling_region.right + 1],
            );

            // With a full-width scroll region the entire row is a
            // fresh blank row: reset the metadata so nothing (wrap
            // state, semantic prompt) is retained from the row whose
            // storage it recycles. With left/right margins the row
            // keeps content outside the margins so the metadata is
            // preserved, matching the shift case above.
            if (!left_right) cur_row.reset();
        }

        // Mark the row as dirty
        cur_p.markDirty();

        // We have successfully processed a line.
        y += 1;
        // Move our pin down to the next row.
        if (cur_p.down(1)) |p| cur_p.* = p;
    }
}

/// Inserts spaces at current cursor position moving existing cell contents
/// to the right. The contents of the count right-most columns in the scroll
/// region are lost. The cursor position is not changed.
///
/// This unsets the pending wrap state without wrapping.
///
/// The inserted cells are colored according to the current SGR state.
pub fn insertBlanks(self: *Terminal, count: usize) void {
    self.accessibility_revision +%= 1;
    // Unset pending wrap state without wrapping. Note: this purposely
    // happens BEFORE the scroll region check below, because that's what
    // xterm does.
    self.screens.active.cursor.pending_wrap = false;

    // If we're given a zero then we do nothing. The rest of this function
    // assumes count > 0 and will crash if zero so return early. Note that
    // this shouldn't be possible with real CSI sequences because the value
    // is clamped to 1 min.
    if (count == 0) return;

    // If our cursor is outside the margins then do nothing. We DO reset
    // wrap state still so this must remain below the above logic.
    if (self.screens.active.cursor.x < self.scrolling_region.left or
        self.screens.active.cursor.x > self.scrolling_region.right) return;

    // If our count is larger than the remaining amount, we just erase right.
    // We only do this if we can erase the entire line (no right margin).
    // if (right_limit == self.cols and
    //     count > right_limit - self.screens.active.cursor.x)
    // {
    //     self.eraseLine(.right, false);
    //     return;
    // }

    // left is just the cursor position but as a multi-pointer
    const left: [*]Cell = @ptrCast(self.screens.active.cursor.page_cell);
    var page = self.screens.active.cursor.page_pin.node.page();

    // If our X is a wide spacer tail then we need to erase the
    // previous cell too so we don't split a multi-cell character.
    if (self.screens.active.cursor.page_cell.wide == .spacer_tail) {
        assert(self.screens.active.cursor.x > 0);
        self.screens.active.clearCells(page, self.screens.active.cursor.page_row, (left - 1)[0..2]);
    }

    // Remaining cols from our cursor to the right margin.
    const rem = self.scrolling_region.right - self.screens.active.cursor.x + 1;

    // If the cell at the right margin is wide, its spacer tail is
    // outside the scroll region and would be orphaned by either the
    // shift or the clear. Clean up both halves up front.
    {
        const right_cell: *Cell = @ptrCast(left + (rem - 1));
        if (right_cell.wide == .wide) self.screens.active.clearCells(
            page,
            self.screens.active.cursor.page_row,
            @as([*]Cell, @ptrCast(right_cell))[0..2],
        );
    }

    // We can only insert blanks up to our remaining cols
    const adjusted_count = @min(count, rem);

    // This is the amount of space at the right of the scroll region
    // that will NOT be blank, so we need to shift the correct cols right.
    // "scroll_amount" is the number of such cols.
    const scroll_amount = rem - adjusted_count;
    if (scroll_amount > 0) {
        page.pauseIntegrityChecks(true);
        defer page.pauseIntegrityChecks(false);

        var x: [*]Cell = left + (scroll_amount - 1);

        // If our last cell we're shifting is wide, then we need to clear
        // it to be empty so we don't split the multi-cell char.
        const end: *Cell = @ptrCast(x);
        if (end.wide == .wide) {
            const end_multi: [*]Cell = @ptrCast(end);
            assert(end_multi[1].wide == .spacer_tail);
            self.screens.active.clearCells(
                page,
                self.screens.active.cursor.page_row,
                end_multi[0..2],
            );
        }

        // We work backwards so we don't overwrite data.
        while (@intFromPtr(x) >= @intFromPtr(left)) : (x -= 1) {
            const src: *Cell = @ptrCast(x);
            const dst: *Cell = @ptrCast(x + adjusted_count);
            page.swapCells(src, dst);
        }
    }

    // Insert blanks. The blanks preserve the background color.
    self.screens.active.clearCells(page, self.screens.active.cursor.page_row, left[0..adjusted_count]);

    // Our row is always dirty
    self.screens.active.cursorMarkDirty();
}

/// Removes amount characters from the current cursor position to the right.
/// The remaining characters are shifted to the left and space from the right
/// margin is filled with spaces.
///
/// If amount is greater than the remaining number of characters in the
/// scrolling region, it is adjusted down.
///
/// Does not change the cursor position.
pub fn deleteChars(self: *Terminal, count_req: usize) void {
    self.accessibility_revision +%= 1;
    if (count_req == 0) return;

    // If our cursor is outside the margins then do nothing. We DO reset
    // wrap state still so this must remain below the above logic.
    if (self.screens.active.cursor.x < self.scrolling_region.left or
        self.screens.active.cursor.x > self.scrolling_region.right) return;

    // left is just the cursor position but as a multi-pointer
    const left: [*]Cell = @ptrCast(self.screens.active.cursor.page_cell);
    var page = self.screens.active.cursor.page_pin.node.page();

    // Remaining cols from our cursor to the right margin.
    const rem = self.scrolling_region.right - self.screens.active.cursor.x + 1;

    // We can only insert blanks up to our remaining cols
    const count = @min(count_req, rem);

    self.screens.active.splitCellBoundary(self.screens.active.cursor.x);
    self.screens.active.splitCellBoundary(self.screens.active.cursor.x + count);
    self.screens.active.splitCellBoundary(self.scrolling_region.right + 1);

    // This is the amount of space at the right of the scroll region
    // that will NOT be blank, so we need to shift the correct cols right.
    // "scroll_amount" is the number of such cols.
    const scroll_amount = rem - count;
    var x: [*]Cell = left;
    if (scroll_amount > 0) {
        page.pauseIntegrityChecks(true);
        defer page.pauseIntegrityChecks(false);

        const right: [*]Cell = left + (scroll_amount - 1);

        while (@intFromPtr(x) <= @intFromPtr(right)) : (x += 1) {
            const src: *Cell = @ptrCast(x + count);
            const dst: *Cell = @ptrCast(x);
            page.swapCells(src, dst);
        }
    }

    // Insert blanks. The blanks preserve the background color.
    self.screens.active.clearCells(page, self.screens.active.cursor.page_row, x[0 .. rem - scroll_amount]);

    // Our row's soft-wrap is always reset.
    self.screens.active.cursorResetWrap();

    // Our row is always dirty
    self.screens.active.cursorMarkDirty();
}

pub fn eraseChars(self: *Terminal, count_req: usize) void {
    self.accessibility_revision +%= 1;
    const count = end: {
        const remaining = self.cols - self.screens.active.cursor.x;
        var end = @min(remaining, @max(count_req, 1));

        // If our last cell is a wide char then we need to also clear the
        // cell beyond it since we can't just split a wide char.
        if (end != remaining) {
            const last = self.screens.active.cursorCellRight(end - 1);
            if (last.wide == .wide) end += 1;
        }

        break :end end;
    };

    // Handle any boundary conditions on the edges of the erased area.
    //
    // TODO(qwerasd): This isn't actually correct if you take in to account
    // protected modes. We need to figure out how to make `clearCells` or at
    // least `clearUnprotectedCells` handle boundary conditions...
    self.screens.active.splitCellBoundary(self.screens.active.cursor.x);
    self.screens.active.splitCellBoundary(self.screens.active.cursor.x + count);

    // Reset our row's soft-wrap.
    self.screens.active.cursorResetWrap();

    // Mark our cursor row as dirty
    self.screens.active.cursorMarkDirty();

    // Clear the cells
    const cells: [*]Cell = @ptrCast(self.screens.active.cursor.page_cell);

    // If we never had a protection mode, then we can assume no cells
    // are protected and go with the fast path. If the last protection
    // mode was not ISO we also always ignore protection attributes.
    if (self.screens.active.protected_mode != .iso) {
        self.screens.active.clearCells(
            self.screens.active.cursor.page_pin.node.page(),
            self.screens.active.cursor.page_row,
            cells[0..count],
        );
        return;
    }

    self.screens.active.clearUnprotectedCells(
        self.screens.active.cursor.page_pin.node.page(),
        self.screens.active.cursor.page_row,
        cells[0..count],
    );
}

/// Erase the line.
pub fn eraseLine(
    self: *Terminal,
    mode: csi.EraseLine,
    protected_req: bool,
) void {
    self.accessibility_revision +%= 1;
    // Get our start/end positions depending on mode.
    const start, const end = switch (mode) {
        .right => right: {
            var x = self.screens.active.cursor.x;

            // If our X is a wide spacer tail then we need to erase the
            // previous cell too so we don't split a multi-cell character.
            if (x > 0 and self.screens.active.cursor.page_cell.wide == .spacer_tail) {
                x -= 1;
            }

            // Reset our row's soft-wrap.
            self.screens.active.cursorResetWrap();

            break :right .{ x, self.cols };
        },

        .left => left: {
            var x = self.screens.active.cursor.x;

            // If our x is a wide char we need to delete the tail too.
            if (self.screens.active.cursor.page_cell.wide == .wide) {
                x += 1;
            }

            break :left .{ 0, x + 1 };
        },

        .complete => complete: {
            // Xterm preserves this flag for EL2, but it also doesn't reflow
            // rows when resizing. Since we do, the erased row must no longer
            // continue onto the next row.
            self.screens.active.cursorResetWrap();

            break :complete .{ 0, self.cols };
        },

        else => {
            log.err("unimplemented erase line mode: {}", .{mode});
            return;
        },
    };

    // All modes will clear the pending wrap state and we know we have
    // a valid mode at this point.
    self.screens.active.cursor.pending_wrap = false;

    // We always mark our row as dirty
    self.screens.active.cursorMarkDirty();

    // Start of our cells
    const cells: [*]Cell = cells: {
        const cells: [*]Cell = @ptrCast(self.screens.active.cursor.page_cell);
        break :cells cells - self.screens.active.cursor.x;
    };

    // We respect protected attributes if explicitly requested (probably
    // a DECSEL sequence) or if our last protected mode was ISO even if its
    // not currently set.
    const protected = self.screens.active.protected_mode == .iso or protected_req;

    // If we're not respecting protected attributes, we can use a fast-path
    // to fill the entire line.
    if (!protected) {
        self.screens.active.clearCells(
            self.screens.active.cursor.page_pin.node.page(),
            self.screens.active.cursor.page_row,
            cells[start..end],
        );
        return;
    }

    self.screens.active.clearUnprotectedCells(
        self.screens.active.cursor.page_pin.node.page(),
        self.screens.active.cursor.page_row,
        cells[start..end],
    );
}

/// Erase the display.
pub fn eraseDisplay(
    self: *Terminal,
    mode: csi.EraseDisplay,
    protected_req: bool,
) void {
    self.accessibility_revision +%= 1;
    if (mode == .complete or mode == .scroll_complete) self.scroll_state.invalidate();
    // We respect protected attributes if explicitly requested (probably
    // a DECSEL sequence) or if our last protected mode was ISO even if its
    // not currently set.
    const protected = self.screens.active.protected_mode == .iso or protected_req;

    switch (mode) {
        .scroll_complete => {
            self.screens.active.scrollClear() catch |err| {
                log.warn("scroll clear failed, doing a normal clear err={}", .{err});
                self.eraseDisplay(.complete, protected_req);
                return;
            };

            // Unsets pending wrap state
            self.screens.active.cursor.pending_wrap = false;

            {
                // Clear only placements still visible after moving the active
                // area into scrollback.
                self.screens.active.kitty_images.clearScreen(
                    self.io(),
                    self.screens.active.alloc,
                    self,
                );
            }
        },

        .complete => {
            // If we're on the primary screen and our last non-empty row is
            // a prompt, then we do a scroll_complete instead. This is a
            // heuristic to get the generally desirable behavior that ^L
            // at a prompt scrolls the screen contents prior to clearing.
            // Most shells send `ESC [ H ESC [ 2 J` so we can't just check
            // our current cursor position. See #905
            if (self.screens.active_key == .primary) at_prompt: {
                // Go from the bottom of the active up and see if we're
                // at a prompt.
                const active_br = self.screens.active.pages.getBottomRight(
                    .active,
                ) orelse break :at_prompt;
                var it = active_br.rowIterator(
                    .left_up,
                    self.screens.active.pages.getTopLeft(.active),
                );
                while (it.next()) |p| {
                    const row = p.rowAndCell().row;
                    switch (row.semantic_prompt) {
                        // If we're at a prompt or input area, then we are at a prompt.
                        .prompt,
                        .prompt_continuation,
                        => break,

                        // If we have command output, then we're most certainly not
                        // at a prompt.
                        .none => break :at_prompt,
                    }
                } else break :at_prompt;

                self.screens.active.scrollClear() catch {
                    // If we fail, we just fall back to doing a normal clear
                    // so we don't worry about the error.
                };
            }

            // All active area
            self.screens.active.clearRows(
                .{ .active = .{} },
                null,
                protected,
            );

            // Unsets pending wrap state
            self.screens.active.cursor.pending_wrap = false;

            {
                // ED2 clears visible placements but preserves graphics that
                // are wholly in scrollback.
                self.screens.active.kitty_images.clearScreen(
                    self.io(),
                    self.screens.active.alloc,
                    self,
                );
            }

            // Cleared screen dirty bit
            self.flags.dirty.clear = true;
        },

        .below => {
            // All lines to the right (including the cursor)
            self.eraseLine(.right, protected_req);

            // All lines below
            if (self.screens.active.cursor.y + 1 < self.rows) {
                self.screens.active.clearRows(
                    .{ .active = .{ .y = self.screens.active.cursor.y + 1 } },
                    null,
                    protected,
                );
            }

            // Unsets pending wrap state. Should be done by eraseLine.
            assert(!self.screens.active.cursor.pending_wrap);
        },

        .above => {
            // Erase to the left (including the cursor)
            self.eraseLine(.left, protected_req);

            // All lines above
            if (self.screens.active.cursor.y > 0) {
                self.screens.active.clearRows(
                    .{ .active = .{ .y = 0 } },
                    .{ .active = .{ .y = self.screens.active.cursor.y - 1 } },
                    protected,
                );
            }

            // Unsets pending wrap state
            assert(!self.screens.active.cursor.pending_wrap);
        },

        .scrollback => self.screens.active.eraseHistory(null),
    }
}

/// Resets all margins and fills the whole screen with the character 'E'
///
/// Sets the cursor to the top left corner.
pub fn decaln(self: *Terminal) !void {
    self.accessibility_revision +%= 1;
    // Clear our stylistic attributes. This is the only thing that can
    // fail so we do it first so we can undo it.
    const old_style = self.screens.active.cursor.style;
    self.screens.active.cursor.style = .{
        .bg_color = self.screens.active.cursor.style.bg_color,
        .fg_color = self.screens.active.cursor.style.fg_color,
    };
    errdefer self.screens.active.cursor.style = old_style;
    try self.screens.active.manualStyleUpdate();

    // Reset margins, also sets cursor to top-left
    self.scrolling_region = .{
        .top = 0,
        .bottom = self.rows - 1,
        .left = 0,
        .right = self.cols - 1,
    };

    // Origin mode is disabled
    self.modes.set(.origin, false);

    // Move our cursor to the top-left
    self.setCursorPos(1, 1);

    // Use clearRows instead of eraseDisplay because we must NOT respect
    // protected attributes here.
    self.screens.active.clearRows(
        .{ .active = .{} },
        null,
        false,
    );

    // Fill with Es by moving the cursor but reset it after.
    while (true) {
        const page = self.screens.active.cursor.page_pin.node.page();
        const row = self.screens.active.cursor.page_row;
        const cells_multi: [*]Cell = row.cells.ptr(page.memory);
        const cells = cells_multi[0..page.size.cols];
        @memset(cells, .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 'E' } },
            .style_id = self.screens.active.cursor.style_id,

            // DECALN does not respect protected state. Verified with xterm.
            .protected = false,
        });

        // If we have a ref-counted style, increase
        if (self.screens.active.cursor.style_id != style.default_id) {
            page.styles.useMultiple(
                page.memory,
                self.screens.active.cursor.style_id,
                @intCast(cells.len),
            );
            row.styled = true;
        }

        // We messed with the page so assert its integrity here.
        page.assertIntegrity();

        self.screens.active.cursorMarkDirty();
        if (self.screens.active.cursor.y == self.rows - 1) break;
        self.screens.active.cursorDown(1);
    }

    // Reset the cursor to the top-left
    self.setCursorPos(1, 1);
}

/// Execute a kitty graphics command. The buf is used to populate with
/// the response that should be sent as an APC sequence. The response will
/// be a full, valid APC sequence.
///
/// If an error occurs, the caller should response to the pty that a
/// an error occurred otherwise the behavior of the graphics protocol is
/// undefined.
pub fn kittyGraphics(
    self: *Terminal,
    io_impl: std.Io,
    alloc: Allocator,
    cmd: *kitty.graphics.Command,
) ?kitty.graphics.Response {
    return kitty.graphics.execute(io_impl, alloc, self, cmd);
}

/// Set the Kitty image storage budget for every screen.
pub fn setKittyGraphicsSizeLimit(
    self: *Terminal,
    alloc: Allocator,
    limit: usize,
) void {
    var it = self.screens.all.iterator();
    while (it.next()) |entry| {
        const screen: *Screen = entry.value.*;
        screen.kitty_images.setLimit(self.io(), alloc, screen, limit);
    }
}

/// Set the allowed medium types for Kitty graphics image loading
/// across all screens.
pub fn setKittyGraphicsLoadingLimits(
    self: *Terminal,
    limits: kitty.graphics.LoadingImage.Limits,
) void {
    var it = self.screens.all.iterator();
    while (it.next()) |entry| {
        const screen: *Screen = entry.value.*;
        screen.kitty_images.image_limits = limits;
    }
}

/// Set a style attribute.
pub fn setAttribute(self: *Terminal, attr: sgr.Attribute) !void {
    try self.screens.active.setAttribute(attr);
}

/// Print the active attributes as a string. This is used to respond to DECRQSS
/// requests.
///
/// Boolean attributes are printed first, followed by foreground color, then
/// background color. Each attribute is separated by a semicolon.
pub fn printAttributes(self: *Terminal, buf: []u8) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buf);

    // The SGR response always starts with a 0. See https://vt100.net/docs/vt510-rm/DECRPSS
    try writer.writeByte('0');

    const pen = self.screens.active.cursor.style;
    var attrs: [9]u8 = @splat(0);
    var i: usize = 0;

    if (pen.flags.bold) {
        attrs[i] = 1;
        i += 1;
    }

    if (pen.flags.faint) {
        attrs[i] = 2;
        i += 1;
    }

    if (pen.flags.italic) {
        attrs[i] = 3;
        i += 1;
    }

    if (pen.flags.underline != .none) {
        attrs[i] = 4;
        i += 1;
    }

    if (pen.flags.overline) {
        attrs[i] = 53;
        i += 1;
    }

    if (pen.flags.blink) {
        attrs[i] = 5;
        i += 1;
    }

    if (pen.flags.inverse) {
        attrs[i] = 7;
        i += 1;
    }

    if (pen.flags.invisible) {
        attrs[i] = 8;
        i += 1;
    }

    if (pen.flags.strikethrough) {
        attrs[i] = 9;
        i += 1;
    }

    for (attrs[0..i]) |attr| {
        // Preserve underline styles. Kind of a hack to special case 4
        // here but its easier than changing how we do all attributes.
        if (attr == 4 and pen.flags.underline != .single) {
            try writer.print(";4:{}", .{@intFromEnum(pen.flags.underline)});
            continue;
        }

        try writer.print(";{}", .{attr});
    }

    switch (pen.fg_color) {
        .none => {},
        .palette => |idx| if (idx >= 16)
            try writer.print(";38:5:{}", .{idx})
        else if (idx >= 8)
            try writer.print(";9{}", .{idx - 8})
        else
            try writer.print(";3{}", .{idx}),
        .rgb => |rgb| try writer.print(";38:2::{[r]}:{[g]}:{[b]}", rgb),
    }

    switch (pen.bg_color) {
        .none => {},
        .palette => |idx| if (idx >= 16)
            try writer.print(";48:5:{}", .{idx})
        else if (idx >= 8)
            try writer.print(";10{}", .{idx - 8})
        else
            try writer.print(";4{}", .{idx}),
        .rgb => |rgb| try writer.print(";48:2::{[r]}:{[g]}:{[b]}", rgb),
    }

    return writer.buffered();
}

/// The modes for DECCOLM.
pub const DeccolmMode = enum(u1) {
    @"80_cols" = 0,
    @"132_cols" = 1,
};

/// DECCOLM changes the terminal width between 80 and 132 columns. This
/// function call will do NOTHING unless `setDeccolmSupported` has been
/// called with "true".
///
/// This breaks the expectation around modern terminals that they resize
/// with the window. This will fix the grid at either 80 or 132 columns.
/// The rows will continue to be variable.
pub fn deccolm(self: *Terminal, alloc: Allocator, mode: DeccolmMode) !void {
    // If DEC mode 40 isn't enabled, then this is ignored. We also make
    // sure that we don't have deccolm set because we want to fully ignore
    // set mode.
    if (!self.modes.get(.enable_mode_3)) {
        self.modes.set(.@"132_column", false);
        return;
    }

    // Enable it
    self.modes.set(.@"132_column", mode == .@"132_cols");

    // Resize to the requested size
    try self.resize(alloc, .{
        .cols = switch (mode) {
            .@"132_cols" => 132,
            .@"80_cols" => 80,
        },
        .rows = self.rows,
    });

    // Erase our display and move our cursor.
    self.eraseDisplay(.complete, false);
    self.setCursorPos(1, 1);
}

/// A terminal resize expressed in cells with optional per-cell pixel
/// geometry. It is highly recommended that callers supply cell geometry
/// but a terminal can technically function without it (but some reports
/// like certain mouse reporting modes and Kitty image protocol will
/// not be functional).
///
/// Cell pixel dimensions must already be scaled for the current display DPI.
pub const Resize = struct {
    cols: size.CellCountInt,
    rows: size.CellCountInt,
    cell_size_px: ?struct {
        width: u32,
        height: u32,
    } = null,
};

pub const ResizeError = error{
    /// Resize requires allocation
    OutOfMemory,

    /// Input value was invalid, such as a 0-sized dimension.
    InvalidValue,
};

const resize_tw = tripwire.module(enum {
    tabstops,
    primary_screen,
    alternate_screen,
    alternate_screen_init,
}, resize);

/// Resize the underlying terminal.
///
/// This has follow-on impacts:
///
///   - If the column count changes, tabstops are reset.
///   - The scroll region is always reset
///   - Synchronized output mode is reset for every successful resize.
///
/// This handles errors gracefully and recovers the terminal back to
/// a clean usable state.
///
/// The only error handling edge case is in the highly exceptional scenario
/// where the primary screen can be resized but the alternate screen cannot.
/// In this scenario, we attempt to clear the alt screen at the desired
/// new size. If that fails, we unconditionally deallocate the alt screen
/// and move to primary screen. This can break terminal programs but it
/// requires a really particular scenario where memory exists for one
/// but not the other and we do our best.
pub fn resize(
    self: *Terminal,
    alloc: Allocator,
    opts: Resize,
) ResizeError!void {
    self.scroll_state.invalidate();
    self.accessibility_revision +%= 1;
    const tw = resize_tw;

    // Screen and scrolling-region invariants require non-zero dimensions.
    // Validate before changing any terminal state.
    if (opts.cols == 0 or opts.rows == 0) return error.InvalidValue;

    // Pixel geometry and synchronized output are updated on every valid
    // resize attempt, including one that doesn't change the grid dimensions.
    // Save their old values so later allocation failures can roll them back.
    const old_width_px = self.width_px;
    const old_height_px = self.height_px;
    const old_synchronized_output = self.modes.get(.synchronized_output);
    errdefer {
        self.width_px = old_width_px;
        self.height_px = old_height_px;
        self.modes.set(.synchronized_output, old_synchronized_output);
    }

    // If our pixel geometry was set, then we set it even if our rows/cols
    // didn't change.
    if (opts.cell_size_px) |cell_size| {
        self.width_px = std.math.mul(
            u32,
            opts.cols,
            cell_size.width,
        ) catch std.math.maxInt(u32);
        self.height_px = std.math.mul(
            u32,
            opts.rows,
            cell_size.height,
        ) catch std.math.maxInt(u32);
    }

    self.modes.set(.synchronized_output, false);

    // If our cols/rows didn't change, skip grid work but still apply pixels.
    if (self.cols == opts.cols and self.rows == opts.rows) return;

    // Build replacement tabstops without touching the current table. Keep
    // ownership here until every fallible resize operation has succeeded.
    var new_tabstops: ?Tabstops = null;
    errdefer if (new_tabstops) |*v| v.deinit(alloc);
    if (self.cols != opts.cols) {
        try tw.check(.tabstops);
        new_tabstops = try .init(
            alloc,
            opts.cols,
            TABSTOP_INTERVAL,
        );
    }

    // Resize primary screen, which supports reflow. We do this first
    // because the cleanup situation is a lot better if this succeeds
    // and alt fails than the reverse.
    try tw.check(.primary_screen);
    const primary = self.screens.get(.primary).?;
    try primary.resize(.{
        .cols = opts.cols,
        .rows = opts.rows,
        .reflow = self.modes.get(.wraparound),
        .prompt_redraw = self.flags.shell_redraws_prompt,
        .pull_scrollback = self.flags.resize_pull_scrollback,
    });

    // Alternate screen, if it exists, doesn't reflow. The primary resize
    // above can't be losslessly undone, so if the alternate resize fails we
    // replace it with an empty screen at the requested size. If that
    // also fails, we fall back to the primary screen.
    if (self.screens.get(.alternate)) |alt| alt: {
        const err: ResizeError = resize: {
            tw.check(.alternate_screen) catch |err| break :resize err;
            alt.resize(.{
                .cols = opts.cols,
                .rows = opts.rows,
                .reflow = false,
                .pull_scrollback = self.flags.resize_pull_scrollback,
            }) catch |err| break :resize err;

            // Resize succeeded.
            break :alt;
        };

        log.warn("alternate screen resize failed, replacing it err={}", .{err});

        // If the alternate screen isn't active, then we just free it
        // and move on. It'll be reallocated when it gets reinitialized lazily.
        // In this case, we just lose the prior data if the terminal program
        // expected it to be saved.
        if (self.screens.active_key != .alternate) {
            self.screens.remove(alloc, .alternate);
            break :alt;
        }

        // The alt screen is active, so we temporarily switch to primary
        // so we can safely remove the alt and recreate it blank. This loses
        // the data but hopefully keeps us on the alt screen.
        const charset = alt.charset;
        self.scroll_state.invalidate();
        self.screens.switchTo(.primary);
        self.screens.remove(alloc, .alternate);

        // Replace the alt screen with an empty version. If this fails
        // we just go back to the primary screen. Not great, but best
        // we can do.
        tw.check(.alternate_screen_init) catch break :alt;
        const replacement = self.screens.getInit(
            self.io(),
            alloc,
            .alternate,
            .{
                .cols = opts.cols,
                .rows = opts.rows,
                .max_scrollback_bytes = 0,
                .kitty_image_storage_limit = primary.kitty_images.total_limit,
                .kitty_image_loading_limits = primary.kitty_images.image_limits,
            },
        ) catch |init_err| {
            log.warn(
                "alternate screen replacement failed, falling back to primary err={}",
                .{init_err},
            );
            break :alt;
        };

        replacement.charset = charset;
        self.scroll_state.invalidate();
        self.screens.switchTo(.alternate);
    }

    // No more failures are allowed after this point because the screens have
    // committed their new sizes and the remaining Terminal state must follow.
    errdefer comptime unreachable;

    // All fallible work is complete. Replace the old tabstop table only now.
    if (new_tabstops) |v| {
        self.tabstops.deinit(alloc);
        self.tabstops = v;
        new_tabstops = null;
    }

    // Whenever we resize we just mark it as a screen clear
    self.flags.dirty.clear = true;

    // Set our size
    self.cols = opts.cols;
    self.rows = opts.rows;

    // Reset the scrolling region
    self.scrolling_region = .{
        .top = 0,
        .bottom = opts.rows - 1,
        .left = 0,
        .right = opts.cols - 1,
    };
}

/// Set the pwd for the terminal.
pub fn setPwd(self: *Terminal, pwd: []const u8) !void {
    if (pwd.len == 0) {
        self.pwd.clearRetainingCapacity();
        return;
    }

    const capacity = std.math.add(usize, pwd.len, 1) catch
        return error.OutOfMemory;
    try self.pwd.ensureTotalCapacity(self.gpa(), capacity);

    self.pwd.items.len = capacity;
    std.mem.copyForwards(u8, self.pwd.items[0..pwd.len], pwd);
    self.pwd.items[pwd.len] = 0;
}

/// Returns the pwd for the terminal, if any. The memory is owned by the
/// Terminal and is not copied. It is safe until a reset or setPwd.
pub fn getPwd(self: *const Terminal) ?[:0]const u8 {
    if (self.pwd.items.len == 0) return null;
    return self.pwd.items[0 .. self.pwd.items.len - 1 :0];
}

/// Set the title for the terminal, as set by escape sequences (e.g. OSC 0/2).
pub fn setTitle(self: *Terminal, t: []const u8) !void {
    if (t.len == 0) {
        self.title.clearRetainingCapacity();
        return;
    }

    const capacity = std.math.add(usize, t.len, 1) catch
        return error.OutOfMemory;
    try self.title.ensureTotalCapacity(self.gpa(), capacity);

    self.title.items.len = capacity;
    std.mem.copyForwards(u8, self.title.items[0..t.len], t);
    self.title.items[t.len] = 0;
}

/// Returns the title for the terminal, if any. The memory is owned by the
/// Terminal and is not copied. It is safe until a reset or setTitle.
pub fn getTitle(self: *const Terminal) ?[:0]const u8 {
    if (self.title.items.len == 0) return null;
    return self.title.items[0 .. self.title.items.len - 1 :0];
}

/// Switch to the given screen type (alternate or primary).
///
/// This does NOT handle behaviors such as clearing the screen,
/// copying the cursor, etc. This should be handled by downstream
/// callers.
///
/// After calling this function, the `self.screen` field will point
/// to the current screen, and the returned value will be the previous
/// screen. If the return value is null, then the screen was not
/// switched because it was already the active screen.
///
/// Note: This is written in a generic way so that we can support
/// more than two screens in the future if needed. There isn't
/// currently a spec for this, but it is something I think might
/// be useful in the future.
pub fn switchScreen(self: *Terminal, key: ScreenSet.Key) !?*Screen {
    self.accessibility_revision +%= 1;
    // If we're already on the requested screen we do nothing.
    if (self.screens.active_key == key) return null;
    const old = self.screens.active;

    // We always end hyperlink state when switching screens.
    // We need to do this on the original screen.
    old.endHyperlink();

    // Switch the screens/
    const new = self.screens.get(key) orelse new: {
        const primary = self.screens.get(.primary).?;
        break :new try self.screens.getInit(
            old.io,
            old.alloc,
            key,
            .{
                .cols = self.cols,
                .rows = self.rows,
                .max_scrollback_bytes = switch (key) {
                    .primary => primary.pages.limits.bytes.explicit,
                    .alternate => 0,
                },

                // Inherit our Kitty image settings from the primary
                // screen if we have to initialize.
                .kitty_image_storage_limit = primary.kitty_images.total_limit,
                .kitty_image_loading_limits = primary.kitty_images.image_limits,
            },
        );
    };

    // The new screen should not have any hyperlinks set
    assert(new.cursor.hyperlink_id == 0);

    // Bring our charset state with us
    new.charset = old.charset;

    // Clear our selection
    new.clearSelection();

    {
        // Mark kitty images as dirty so they redraw. Without this set
        // the images will remain where they were (the dirty bit on
        // the screen only tracks the terminal grid, not the images).
        new.kitty_images.dirty = true;
    }

    // Mark our terminal as dirty to redraw the grid.
    self.flags.dirty.clear = true;

    // Finalize the switch
    self.scroll_state.invalidate();
    self.screens.switchTo(key);

    return old;
}

/// Switch screen via a mode switch (e.g. mode 47, 1047, 1049).
/// This is a much more opinionated operation than `switchScreen`
/// since it also handles the behaviors of the specific mode,
/// such as clearing the screen, saving/restoring the cursor,
/// etc.
///
/// This should be used for legacy compatibility with VT protocols,
/// but more modern usage should use `switchScreen` instead and handle
/// details like clearing the screen, cursor saving, etc. manually.
pub fn switchScreenMode(
    self: *Terminal,
    mode: SwitchScreenMode,
    enabled: bool,
) !void {
    self.accessibility_revision +%= 1;
    // The behavior in this function is completely based on reading
    // the xterm source, specifically "charproc.c" for
    // `srm_ALTBUF`, `srm_OPT_ALTBUF`, and `srm_OPT_ALTBUF_CURSOR`.
    // We shouldn't touch anything in here without adding a unit
    // test AND verifying the behavior with xterm.

    switch (mode) {
        .@"47" => {},

        // If we're disabling 1047 and we're on alt screen then
        // we clear the screen.
        .@"1047" => if (!enabled and self.screens.active_key == .alternate) {
            self.eraseDisplay(.complete, false);
        },

        // 1049 unconditionally saves the cursor on enabling, even
        // if we're already on the alternate screen.
        .@"1049" => if (enabled) self.saveCursor(),
    }

    // Switch screens first to whatever we're going to.
    const to: ScreenSet.Key = if (enabled) .alternate else .primary;
    const old_ = try self.switchScreen(to);

    switch (mode) {
        // For these modes, we need to copy the cursor. We only copy
        // the cursor if the screen actually changed, otherwise the
        // cursor is already copied. The cursor is copied regardless
        // of destination screen.
        .@"47", .@"1047" => if (old_) |old| {
            self.screens.active.cursorCopy(old.cursor, .{
                .hyperlink = false,
            }) catch |err| {
                log.warn(
                    "cursor copy failed entering alt screen err={}",
                    .{err},
                );
            };
        },

        // Mode 1049 restores cursor on the primary screen when
        // we disable it.
        .@"1049" => if (enabled) {
            assert(self.screens.active_key == .alternate);
            self.eraseDisplay(.complete, false);

            // When we enter alt screen with 1049, we always copy the
            // cursor from the primary screen (if we weren't already
            // on it).
            if (old_) |old| {
                self.screens.active.cursorCopy(old.cursor, .{
                    .hyperlink = false,
                }) catch |err| {
                    log.warn(
                        "cursor copy failed entering alt screen err={}",
                        .{err},
                    );
                };
            }
        } else {
            assert(self.screens.active_key == .primary);
            self.restoreCursor();
        },
    }
}

/// Modal screen changes. These map to the literal terminal
/// modes to enable or disable alternate screen modes. They each
/// have subtle behaviors so we define them as an enum here.
pub const SwitchScreenMode = enum {
    /// Legacy alternate screen mode. This goes to the alternate
    /// screen or primary screen and only copies the cursor. The
    /// screen is not erased.
    @"47",

    /// Alternate screen mode where the alternate screen is cleared
    /// on exit. The primary screen is never cleared. The cursor is
    /// copied.
    @"1047",

    /// Save primary screen cursor, switch to alternate screen,
    /// and clear the alternate screen on entry. On exit,
    /// do not clear the screen, and restore the cursor on the
    /// primary screen.
    @"1049",
};

/// Return the current string value of the terminal. Newlines are
/// encoded as "\n". This omits any formatting such as fg/bg.
///
/// The caller must free the string.
pub fn plainString(self: *Terminal, alloc: Allocator) ![]const u8 {
    return try self.screens.active.dumpStringAlloc(alloc, .{ .viewport = .{} });
}

/// Same as plainString, but respects row wrap state when building the string.
pub fn plainStringUnwrapped(self: *Terminal, alloc: Allocator) ![]const u8 {
    return try self.screens.active.dumpStringAllocUnwrapped(alloc, .{ .viewport = .{} });
}

/// Full reset.
///
/// This will attempt to free the existing screen memory but if that fails
/// this will reuse the existing memory. In the latter case, memory may
/// be wasted (since its unused) but it isn't leaked.
pub fn fullReset(self: *Terminal) void {
    self.scroll_state.invalidate();
    self.accessibility_revision +%= 1;
    // Ensure we're back on primary screen
    self.screens.switchTo(.primary);
    self.screens.remove(
        self.screens.active.alloc,
        .alternate,
    );

    // Reset our screens
    self.screens.active.reset();

    // Rest our basic state
    const visible = self.flags.visible;
    const resize_pull_scrollback = self.flags.resize_pull_scrollback;
    self.modes.reset();
    self.flags = .{
        // Visibility belongs to the view rather than terminal state, so a
        // terminal reset must not make a hidden view potentially visible.
        .visible = visible,

        // This is configuration based on the pty rather than terminal
        // state, so a terminal reset must not change it.
        .resize_pull_scrollback = resize_pull_scrollback,
    };
    self.tabstops.reset(TABSTOP_INTERVAL);
    self.previous_char = null;
    self.pwd.clearRetainingCapacity();
    self.title.clearRetainingCapacity();
    // A reset only interrupts an in-progress chunked OSC 72 command;
    // drag and drop registration survives, matching kitty.
    if (self.kitty_dnd) |dnd| dnd.chunking = .{};
    self.status_display = .main;
    self.scrolling_region = .{
        .top = 0,
        .bottom = self.rows - 1,
        .left = 0,
        .right = self.cols - 1,
    };
    self.setCursorStyle(.default);

    // Always mark dirty so we redraw everything
    self.flags.dirty.clear = true;
}

/// Record only actual terminal region movement; never infer movement from keys.
fn recordScroll(self: *Terminal, top: u16, rows: i32) void {
    if (rows == 0) return;
    self.scroll_state.record(.{
        .left = self.scrolling_region.left,
        .top = top,
        .right = self.scrolling_region.right + 1,
        .bottom = self.scrolling_region.bottom + 1,
    }, rows);
}

/// White-box regression hooks; absent from application builds.
pub const TestAccess = if (@import("builtin").is_test) struct {
    pub const printSliceFast = Terminal.printSliceFast;
    pub const resize_tw = Terminal.resize_tw;
} else struct {};

test {
    _ = @import("tests/Terminal/scrolling.zig");
    _ = @import("tests/Terminal/state.zig");
    _ = @import("tests/Terminal/operations.zig");
    _ = @import("tests/Terminal/printing.zig");
    _ = @import("tests/Terminal/editing.zig");
}
