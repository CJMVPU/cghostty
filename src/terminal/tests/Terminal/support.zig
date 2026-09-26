//! Shared fixtures and aliases for Terminal regression tests.
pub const Terminal = @import("../../Terminal.zig");
pub const std = @import("std");
pub const testing = std.testing;
pub const Allocator = std.mem.Allocator;
pub const unicode = @import("../../../unicode/main.zig");
pub const charsets = @import("../../charsets.zig");
pub const hyperlink = @import("../../hyperlink.zig");
pub const kitty = @import("../../kitty.zig");
pub const point = @import("../../point.zig");
pub const sgr = @import("../../sgr.zig");
pub const size = @import("../../size.zig");
pub const pagepkg = @import("../../page.zig");
pub const style = @import("../../style.zig");
pub const PageList = @import("../../PageList.zig");
pub const Screen = @import("../../Screen.zig");
pub const Page = pagepkg.Page;
pub const Cell = pagepkg.Cell;
pub const init = Terminal.init;
pub const printSliceFast = Terminal.TestAccess.printSliceFast;
pub const resize_tw = Terminal.TestAccess.resize_tw;

/// Returns true if the point is dirty, used for testing.
pub fn isDirty(t: *const Terminal, pt: point.Point) bool {
    return t.screens.active.pages.getCell(pt).?.isDirty();
}

/// Clear all dirty bits. Testing only.
pub fn clearDirty(t: *Terminal) void {
    t.screens.active.pages.clearDirty();
}

// Terminal.print receives one codepoint at a time, so it can't use
// unicode.graphemeWidth directly; that API requires a complete buffered
// cluster or string end. This keeps the streaming printer's cursor advance
// in sync with the buffered measurement API for representative clusters.
pub fn expectGraphemeWidthParity(cps: []const u21) !void {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 5 });
    defer t.deinit(testing.allocator);

    t.modes.set(.grapheme_cluster, true);

    var expected: usize = 0;
    var i: usize = 0;
    while (i < cps.len) {
        const result = unicode.graphemeWidth(u21, cps[i..]);
        try testing.expect(result.len > 0);
        i += result.len;
        expected += result.width;
    }

    for (cps) |cp| try t.print(cp);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(expected, t.screens.active.cursor.x);
}

/// Differential testing helper: applies the same logical print
/// operations to two terminals, one using per-codepoint print() and
/// the other using printSlice() with random chunking, verifying that
/// the results are identical.
pub fn testPrintSliceDifferential(
    io_impl: std.Io,
    alloc: Allocator,
    rand: std.Random,
    ops: usize,
    cols: size.CellCountInt,
    rows: size.CellCountInt,
) !void {
    var t1 = try init(io_impl, alloc, .{
        .cols = cols,
        .rows = rows,
    });
    defer t1.deinit(alloc);
    var t2 = try init(io_impl, alloc, .{
        .cols = cols,
        .rows = rows,
    });
    defer t2.deinit(alloc);

    // Alphabet of interesting codepoints: ascii, latin-1, combining
    // marks, CJK (wide), emoji (wide), ZWJ, variation selectors.
    const alphabet = [_]u21{
        'a',     'b',     'Z',    '0',    ' ',     0x10,   0x1F,   0x7F,
        'é',
        0xFF,    0x301,   0x4E00, 0x4E01, 0x1F600, 0x200D, 0xFE0F, 'x',
        'y',     0x1F9D1, 0x0308, 0xAD,   0x3042,  0xAC00, 'q',    'r',
        's',     't',     'u',    'v',    'w',     '1',    '2',    0x1F1E6,
        0x1F1E7, 0x1100,  0x1161, 0x11A8, 0x200C,  0x0430, 0x03B1,
    };

    var cps_buf: [64]u32 = undefined;
    var last_n: usize = 0;

    for (0..ops) |_| {
        switch (rand.intRangeAtMost(u8, 0, 20)) {
            // Print a run of codepoints (most common op).
            0...9 => {
                const n = rand.intRangeAtMost(usize, 1, cps_buf.len);
                last_n = n;
                for (cps_buf[0..n]) |*cp| {
                    cp.* = alphabet[rand.intRangeLessThan(usize, 0, alphabet.len)];
                }

                // t1: per-codepoint print
                for (cps_buf[0..n]) |cp| try t1.print(@intCast(cp));

                // t2: printSlice with random chunking
                var i: usize = 0;
                while (i < n) {
                    const chunk = rand.intRangeAtMost(usize, 1, n - i);
                    try t2.printSlice(cps_buf[i..][0..chunk]);
                    i += chunk;
                }
            },
            10 => {
                t1.carriageReturn();
                t2.carriageReturn();
                try t1.linefeed();
                try t2.linefeed();
            },
            11 => {
                const row = rand.intRangeAtMost(usize, 1, rows);
                const col = rand.intRangeAtMost(usize, 1, cols);
                t1.setCursorPos(row, col);
                t2.setCursorPos(row, col);
            },
            12 => {
                const attr: sgr.Attribute = switch (rand.intRangeAtMost(u8, 0, 3)) {
                    0 => .{ .unset = {} },
                    1 => .{ .bold = {} },
                    2 => .{ .direct_color_fg = .{
                        .r = rand.int(u8),
                        .g = rand.int(u8),
                        .b = rand.int(u8),
                    } },
                    3 => .{ .@"8_fg" = .red },
                    else => unreachable,
                };
                try t1.setAttribute(attr);
                try t2.setAttribute(attr);
            },
            13 => {
                const v = rand.boolean();
                t1.modes.set(.insert, v);
                t2.modes.set(.insert, v);
            },
            14 => {
                const v = rand.boolean();
                t1.modes.set(.wraparound, v);
                t2.modes.set(.wraparound, v);
            },
            15 => {
                const v = rand.boolean();
                t1.modes.set(.grapheme_cluster, v);
                t2.modes.set(.grapheme_cluster, v);
            },
            16 => {
                // Margins.
                t1.modes.set(.enable_left_and_right_margin, true);
                t2.modes.set(.enable_left_and_right_margin, true);
                const left = rand.intRangeAtMost(usize, 1, cols / 2);
                const right = rand.intRangeAtMost(usize, cols / 2, cols);
                t1.setLeftAndRightMargin(left, right);
                t2.setLeftAndRightMargin(left, right);
            },
            17 => {
                t1.setLeftAndRightMargin(0, 0);
                t2.setLeftAndRightMargin(0, 0);
            },
            18 => {
                try t1.screens.active.startHyperlink("http://example.com", null);
                try t2.screens.active.startHyperlink("http://example.com", null);
            },
            19 => {
                t1.screens.active.endHyperlink();
                t2.screens.active.endHyperlink();
            },
            20 => {
                const set = rand.enumValue(charsets.Charset);
                t1.configureCharset(.G0, set);
                t2.configureCharset(.G0, set);
            },
            else => unreachable,
        }

        // Cursor state must match exactly after every op.
        try testing.expectEqual(t1.screens.active.cursor.x, t2.screens.active.cursor.x);
        try testing.expectEqual(t1.screens.active.cursor.y, t2.screens.active.cursor.y);
        try testing.expectEqual(
            t1.screens.active.cursor.pending_wrap,
            t2.screens.active.cursor.pending_wrap,
        );

        // Full screen contents must match after every op. On failure,
        // dump diagnostics that make the failure reproducible.
        {
            const str1 = try t1.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
            defer alloc.free(str1);
            const str2 = try t2.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
            defer alloc.free(str2);
            testing.expectEqualStrings(str1, str2) catch |err| {
                std.debug.print("last print cps: {any}\n", .{cps_buf[0..last_n]});
                std.debug.print("modes: 2027={} insert={} wrap={} sr.left={} sr.right={} cols={}\n", .{
                    t1.modes.get(.grapheme_cluster),
                    t1.modes.get(.insert),
                    t1.modes.get(.wraparound),
                    t1.scrolling_region.left,
                    t1.scrolling_region.right,
                    cols,
                });
                return err;
            };
        }
    }

    // Page integrity (styles refcounts, grapheme maps, etc.) must hold.
    try t1.screens.active.cursor.page_pin.node.page().verifyIntegrity(alloc);
    try t2.screens.active.cursor.page_pin.node.page().verifyIntegrity(alloc);
}
