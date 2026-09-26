//! Accumulated completed-frame row deltas waiting for the GUI renderer. Access is
//! serialized by renderer.State.mutex; no GPU work runs on the IO thread.
const RenderHold = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const terminal = @import("../terminal/main.zig");
const image = @import("image.zig");
const CellSize = @import("size.zig").CellSize;

pending: ?Frame = null,
spare: terminal.RenderState = .empty,
image_cache: image.State = .empty,

pub const Frame = struct {
    render: terminal.RenderState = .empty,
    images: image.State = .empty,
    scrollbar: terminal.Scrollbar,
    osc8: terminal.RenderState.CellSet = .empty,
    mouse: ?terminal.point.Coordinate,
    link_key: terminal.accessibility.Tracker.Key,

    pub fn deinit(self: *Frame, alloc: Allocator) void {
        self.render.deinit(alloc);
        self.images.deinit(alloc);
        self.osc8.deinit(alloc);
    }
};

pub fn deinit(self: *RenderHold, alloc: Allocator) void {
    if (self.pending) |*frame| frame.deinit(alloc);
    self.spare.deinit(alloc);
    self.image_cache.deinit(alloc);
    self.* = .{};
}

/// Return CPU row/style storage only; it never contains GPU objects.
pub fn recycleRender(self: *RenderHold, alloc: Allocator, render: *terminal.RenderState) void {
    self.spare.deinit(alloc);
    self.spare = render.*;
    self.spare.clean();
    render.* = .empty;
}

/// Align the spare's cheap metadata after a live renderer update. The hold
/// and live renderer are one dirty-bit consumer, with exclusive ownership
/// transferred through pending. Never discard a pending delta on release.
pub fn syncLive(self: *RenderHold, render: *const terminal.RenderState) void {
    std.debug.assert(self.pending == null);
    self.spare.copyMetadata(render);
}

/// Capture only rows changed since the last capture/live update. Repeated
/// frame boundaries accumulate into the same mailbox until the GUI takes it.
/// This preserves reset/set boundaries within a single PTY read.
pub fn capture(self: *RenderHold, alloc: Allocator, t: *terminal.Terminal, cell: CellSize, mouse: ?terminal.point.Coordinate) !void {
    var frame: Frame = self.pending orelse .{
        .render = self.spare,
        .scrollbar = undefined,
        .link_key = undefined,
        .mouse = null,
    };
    if (self.pending == null) self.spare = .empty;
    self.pending = null;
    errdefer {
        frame.deinit(alloc);
        // beginUpdate may already have consumed some dirty flags. Recover
        // with a full live update (or next boundary) after allocation failure.
        t.flags.dirty.clear = true;
    }
    frame.scrollbar = t.screens.active.pages.scrollbar();
    frame.link_key = .read(t);
    frame.mouse = mouse;
    try frame.render.beginUpdate(alloc, t);
    frame.osc8.deinit(alloc);
    frame.osc8 = .empty;
    if (mouse) |vp| frame.osc8 = try frame.render.linkCells(alloc, vp);
    // Style expansion stays on the GUI thread, using only owned memory.
    self.image_cache.kittyUpdate(alloc, t, cell);
    t.screens.active.kitty_images.dirty = true;
    frame.images.deinit(alloc);
    frame.images = .empty;
    frame.images = try self.image_cache.cloneCapture(alloc);
    self.pending = frame;
}

/// The caller must merge the delta even if the hold has ended: it owns dirty
/// rows already consumed from the terminal. A subsequent live beginUpdate
/// then applies all changes made after this completed-frame boundary.
pub fn take(self: *RenderHold) ?Frame {
    const result = self.pending;
    self.pending = null;
    return result;
}

test "render hold owns a completed viewport and preserves live dirty state" {
    const t = std.testing;
    const alloc = t.allocator;
    var term = try terminal.Terminal.init(t.io, alloc, .{ .cols = 10, .rows = 3 });
    defer term.deinit(alloc);
    var hold: RenderHold = .{};
    defer hold.deinit(alloc);
    try term.printString("AB");
    try hold.capture(alloc, &term, .{ .width = 10, .height = 20 }, null);
    term.setCursorPos(1, 1);
    try term.printString("XYZ");
    var frame = hold.take().?;
    defer frame.deinit(alloc);
    frame.render.endUpdate();
    try t.expectEqual('A', frame.render.row_data.items(.cells)[0].get(0).raw.codepoint());
    try t.expectEqual('B', frame.render.row_data.items(.cells)[0].get(1).raw.codepoint());
    try t.expect(hold.take() == null);
    var live: terminal.RenderState = .empty;
    defer live.deinit(alloc);
    try live.update(alloc, &term);
    try t.expectEqual('X', live.row_data.items(.cells)[0].get(0).raw.codepoint());
    try hold.capture(alloc, &term, .{ .width = 10, .height = 20 }, null);
    try t.expect(!term.flags.dirty.clear);
    var completed = hold.take().?;
    defer completed.deinit(alloc);
    live.applyDelta(&completed.render);
    live.endUpdate();
    try t.expect(hold.pending == null);
}

test "render hold merges pending rows after resize reset and timeout" {
    const t = std.testing;
    var term = try terminal.Terminal.init(t.io, t.allocator, .{ .cols = 10, .rows = 3 });
    defer term.deinit(t.allocator);
    var hold: RenderHold = .{};
    defer hold.deinit(t.allocator);
    for (0..3) |operation| {
        try hold.capture(t.allocator, &term, .{ .width = 10, .height = 20 }, null);
        term.modes.set(.synchronized_output, true);
        switch (operation) {
            0 => try term.resize(t.allocator, .{ .cols = 12, .rows = 4 }),
            1 => term.fullReset(),
            2 => term.modes.set(.synchronized_output, false),
            else => unreachable,
        }
        try t.expect(!term.modes.get(.synchronized_output));
        var frame = hold.take().?;
        defer frame.deinit(t.allocator);
        var live: terminal.RenderState = .empty;
        defer live.deinit(t.allocator);
        live.applyDelta(&frame.render);
        try live.update(t.allocator, &term);
        try t.expectEqual(term.cols, live.cols);
        try t.expectEqual(term.rows, live.rows);
        try t.expect(hold.pending == null);
    }
}

test "render hold capture allocation failure keeps live terminal redrawable" {
    const t = std.testing;
    var term = try terminal.Terminal.init(t.io, t.allocator, .{ .cols = 10, .rows = 3 });
    defer term.deinit(t.allocator);
    var hold: RenderHold = .{};
    defer hold.deinit(t.allocator);
    var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    try t.expectError(error.OutOfMemory, hold.capture(failing.allocator(), &term, .{ .width = 10, .height = 20 }, null));
    try t.expect(hold.pending == null);
    try t.expect(term.flags.dirty.clear);
}

test "render hold OSC8 links survive terminal page replacement" {
    const t = std.testing;
    var term = try terminal.Terminal.init(t.io, t.allocator, .{ .cols = 10, .rows = 3 });
    defer term.deinit(t.allocator);
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("\x1b]8;;https://example.com\x1b\\LINK\x1b]8;;\x1b\\");
    var hold: RenderHold = .{};
    defer hold.deinit(t.allocator);
    try hold.capture(t.allocator, &term, .{ .width = 10, .height = 20 }, .{ .x = 0, .y = 0 });
    // Full reset can replace the pages. The captured renderer must never
    // dereference the old row pins to resolve link IDs after this point.
    term.fullReset();
    var frame = hold.take().?;
    defer frame.deinit(t.allocator);
    frame.render.endUpdate();
    try t.expectEqual(4, frame.osc8.count());
    try t.expect(frame.osc8.contains(.{ .x = 3, .y = 0 }));
    try t.expectEqual('L', frame.render.row_data.items(.cells)[0].get(0).raw.codepoint());
}

test "render hold keeps Kitty pixels and placements from the same completed frame" {
    const t = std.testing;
    const alloc = t.allocator;
    var term = try terminal.Terminal.init(t.io, alloc, .{ .cols = 10, .rows = 3 });
    defer term.deinit(alloc);
    term.width_px = 100;
    term.height_px = 60;
    const storage = &term.screens.active.kitty_images;
    try storage.addImage(t.io, alloc, term.screens.active, .{
        .id = 1,
        .width = 1,
        .height = 1,
        .format = .rgba,
        .data = .{ .complete = try alloc.dupe(u8, "rgba") },
    });
    const pin = try term.screens.active.pages.trackPin(term.screens.active.cursor.page_pin.*);
    try storage.addPlacement(t.io, alloc, term.screens.active, 1, 1, .{
        .location = .{ .pin = pin },
        .columns = 1,
        .rows = 1,
    });
    var hold: RenderHold = .{};
    defer hold.deinit(alloc);
    try hold.capture(alloc, &term, .{ .width = 10, .height = 20 }, null);
    // Replacing the terminal image deletes its placements, but the queued
    // frame must keep both the prior pixels and prior placement alive.
    _ = try storage.addPendingImage(t.io, alloc, term.screens.active, .{
        .id = 1,
        .width = 1,
        .height = 1,
        .format = .rgba,
        .data = .{ .pending = 4 },
    });
    var frame = hold.take().?;
    defer frame.deinit(alloc);
    try t.expectEqual(1, frame.images.kitty_placements.items.len);
    try t.expectEqualStrings("rgba", frame.images.images.get(.{ .kitty = 1 }).?.image.pending.dataSlice());
    var displayed: image.State = .empty;
    defer displayed.deinit(alloc);
    displayed.adopt(alloc, &frame.images);
    try t.expectEqual(0, frame.images.images.count());
    try t.expectEqual(1, displayed.kitty_placements.items.len);
    displayed.kittyUpdate(alloc, &term, .{ .width = 10, .height = 20 });
    try t.expectEqual(0, displayed.kitty_placements.items.len);
}

test "render hold reuses rows and pixels without borrowing live pages" {
    const t = std.testing;
    const alloc = t.allocator;
    var term = try terminal.Terminal.init(t.io, alloc, .{ .cols = 10, .rows = 3 });
    defer term.deinit(alloc);
    try term.printString("first");
    term.width_px = 100;
    term.height_px = 60;
    const storage = &term.screens.active.kitty_images;
    try storage.addImage(t.io, alloc, term.screens.active, .{
        .id = 1,
        .width = 1,
        .height = 1,
        .format = .rgba,
        .data = .{ .complete = try alloc.dupe(u8, "rgba") },
    });
    const pin = try term.screens.active.pages.trackPin(term.screens.active.cursor.page_pin.*);
    try storage.addPlacement(t.io, alloc, term.screens.active, 1, 1, .{
        .location = .{ .pin = pin },
        .columns = 1,
        .rows = 1,
    });
    var hold: RenderHold = .{};
    defer hold.deinit(alloc);
    try hold.capture(alloc, &term, .{ .width = 10, .height = 20 }, null);
    var old = hold.take().?;
    defer old.deinit(alloc);
    old.render.endUpdate();
    const rows = old.render.row_data.bytes;
    const pixels = old.images.images.get(.{ .kitty = 1 }).?.image.pending.data;
    hold.recycleRender(alloc, &old.render);
    term.setCursorPos(1, 1);
    try term.printString("second");
    try hold.capture(alloc, &term, .{ .width = 10, .height = 20 }, null);
    try t.expectEqual(rows, hold.pending.?.render.row_data.bytes);
    try t.expectEqual(pixels, hold.pending.?.images.images.get(.{ .kitty = 1 }).?.image.pending.data);
    // Removing the source/cache cannot free a displayed frame's pixel owner.
    term.fullReset();
    try hold.capture(alloc, &term, .{ .width = 10, .height = 20 }, null);
    try t.expectEqual(0, hold.image_cache.images.count());
    try t.expectEqualStrings("rgba", old.images.images.get(.{ .kitty = 1 }).?.image.pending.dataSlice());
}

// Exercise the same ownership handoff as Renderer.updateFrame.
fn presentTest(hold: *RenderHold, displayed: *terminal.RenderState) void {
    var frame = hold.take().?;
    defer frame.deinit(std.testing.allocator);
    displayed.applyDelta(&frame.render);
    hold.recycleRender(std.testing.allocator, &frame.render);
    displayed.endUpdate();
}

fn warmTest(hold: *RenderHold, displayed: *terminal.RenderState, term: *terminal.Terminal) !void {
    // Both reusable buffers acquire geometry once. Subsequent captures must
    // be incremental even when a live update consumed the last dirty bits.
    for (0..2) |_| {
        try hold.capture(std.testing.allocator, term, .{ .width = 10, .height = 20 }, null);
        presentTest(hold, displayed);
        displayed.clean();
    }
}

test "render hold incremental clean cursor and single row handoff" {
    const t = std.testing;
    var term = try terminal.Terminal.init(t.io, t.allocator, .{ .cols = 120, .rows = 40 });
    defer term.deinit(t.allocator);
    var hold: RenderHold = .{};
    defer hold.deinit(t.allocator);
    var displayed: terminal.RenderState = .empty;
    defer displayed.deinit(t.allocator);
    try term.printString("unchanged");
    term.setCursorPos(3, 2);
    try warmTest(&hold, &displayed, &term);
    const untouched = displayed.row_data.items(.cells)[0].bytes;
    try hold.capture(t.allocator, &term, .{ .width = 10, .height = 20 }, null);
    try t.expectEqual(.false, hold.pending.?.render.dirty);
    for (hold.pending.?.render.row_data.items(.dirty)) |dirty| try t.expect(!dirty);
    presentTest(&hold, &displayed);
    try t.expectEqual(2, displayed.cursor.viewport.?.y);
    try term.printString("中文e\u{301}");
    try hold.capture(t.allocator, &term, .{ .width = 10, .height = 20 }, null);
    try t.expectEqual(.partial, hold.pending.?.render.dirty);
    for (hold.pending.?.render.row_data.items(.dirty), 0..) |dirty, y| try t.expectEqual(y == 2, dirty);
    const changed = hold.pending.?.render.row_data.items(.cells)[2].bytes;
    // Later writes must not change the pending completed row.
    term.setCursorPos(3, 2);
    try term.printString("later");
    presentTest(&hold, &displayed);
    try t.expectEqual(untouched, displayed.row_data.items(.cells)[0].bytes);
    try t.expectEqual(changed, displayed.row_data.items(.cells)[2].bytes);
    try t.expectEqual('中', displayed.row_data.items(.cells)[2].get(1).raw.codepoint());
    displayed.clean();
    try displayed.update(t.allocator, &term);
    hold.syncLive(&displayed);
    try t.expectEqual(.partial, displayed.dirty);
    try t.expectEqual('l', displayed.row_data.items(.cells)[2].get(1).raw.codepoint());
    displayed.clean();
    try hold.capture(t.allocator, &term, .{ .width = 10, .height = 20 }, null);
    try t.expectEqual(.false, hold.pending.?.render.dirty);
    presentTest(&hold, &displayed);
    try t.expectEqual('l', displayed.row_data.items(.cells)[2].get(1).raw.codepoint());
}

test "render hold coalesces styled rows with bounded pending storage" {
    const t = std.testing;
    var term = try terminal.Terminal.init(t.io, t.allocator, .{ .cols = 20, .rows = 4 });
    defer term.deinit(t.allocator);
    var stream = term.vtStream();
    defer stream.deinit();
    var hold: RenderHold = .{};
    defer hold.deinit(t.allocator);
    var displayed: terminal.RenderState = .empty;
    defer displayed.deinit(t.allocator);
    try warmTest(&hold, &displayed, &term);
    for (0..1000) |_| {
        stream.nextSlice("\x1b[H\x1b[31m红\x1b[2;1H\x1b[32me\xcc\x81");
        try hold.capture(t.allocator, &term, .{ .width = 10, .height = 20 }, null);
        try t.expect(hold.pending.?.render.pending_styles.items.len <= 4);
    }
    stream.nextSlice("\x1b[H\x1b[34m蓝");
    try hold.capture(t.allocator, &term, .{ .width = 10, .height = 20 }, null);
    // The source pages can be destroyed before applying the row delta.
    term.fullReset();
    presentTest(&hold, &displayed);
    try t.expectEqual('蓝', displayed.row_data.items(.cells)[0].get(0).raw.codepoint());
    try t.expectEqual(terminal.Style.Color{ .palette = 4 }, displayed.row_data.items(.cells)[0].get(0).style.fg_color);
    try t.expectEqual(terminal.Style.Color{ .palette = 2 }, displayed.row_data.items(.cells)[1].get(0).style.fg_color);
    try t.expectEqualSlices(u21, &.{0x301}, displayed.row_data.items(.cells)[1].get(0).grapheme);
}

test "render hold links and palette follow live updates between captures" {
    const t = std.testing;
    var term = try terminal.Terminal.init(t.io, t.allocator, .{ .cols = 20, .rows = 4 });
    defer term.deinit(t.allocator);
    var stream = term.vtStream();
    defer stream.deinit();
    var hold: RenderHold = .{};
    defer hold.deinit(t.allocator);
    var displayed: terminal.RenderState = .empty;
    defer displayed.deinit(t.allocator);
    try warmTest(&hold, &displayed, &term);
    stream.nextSlice("\x1b]8;;https://example.com\x1b\\LINK\x1b]8;;\x1b\\\x1b]4;1;rgb:12/34/56\x1b\\");
    try displayed.update(t.allocator, &term);
    hold.syncLive(&displayed);
    displayed.clean();
    try hold.capture(t.allocator, &term, .{ .width = 10, .height = 20 }, .{ .x = 0, .y = 0 });
    try t.expectEqual(.false, hold.pending.?.render.dirty);
    try t.expectEqual(4, hold.pending.?.osc8.count());
    presentTest(&hold, &displayed);
    try t.expectEqual('L', displayed.row_data.items(.cells)[0].get(0).raw.codepoint());
    try t.expectEqual(terminal.color.RGB{ .r = 0x12, .g = 0x34, .b = 0x56 }, displayed.colors.palette[1]);
}

test "render hold deltas match full rebuild across live updates and geometry changes" {
    const t = std.testing;
    var term = try terminal.Terminal.init(t.io, t.allocator, .{ .cols = 20, .rows = 5 });
    defer term.deinit(t.allocator);
    var stream = term.vtStream();
    defer stream.deinit();
    var hold: RenderHold = .{};
    defer hold.deinit(t.allocator);
    var displayed: terminal.RenderState = .empty;
    defer displayed.deinit(t.allocator);
    const operations = [_][]const u8{
        "\x1b[H\x1b[31m中文e\xcc\x81",
        "\x1b[2;2H\x1b[0mplain",
        "\x1b[3;1H\x1b[44m\x1b[2K",
        "\x1b[2;4r\x1b[S\x1b[r",
        "\x1b[?1049h\x1b[1;1Halt",
        "\x1b[?1049l",
        "\x1b[2;2H\x1b[2L",
        "\x1b[3;3H\x1b[P",
        "\x1b[0m\x1b[2J\x1b[Hclear",
    };
    for (0..120) |i| {
        stream.nextSlice(operations[i % operations.len]);
        if (i % 17 == 0) try term.resize(t.allocator, .{ .cols = @intCast(20 + i % 3), .rows = @intCast(5 + i % 2) });
        if (i % 3 == 0) {
            try displayed.update(t.allocator, &term);
            hold.syncLive(&displayed);
        } else {
            try hold.capture(t.allocator, &term, .{ .width = 10, .height = 20 }, null);
            if (i % 3 == 1) {
                stream.nextSlice(operations[(i + 2) % operations.len]);
                try hold.capture(t.allocator, &term, .{ .width = 10, .height = 20 }, null);
            }
            presentTest(&hold, &displayed);
        }
        var fresh: terminal.RenderState = .empty;
        defer fresh.deinit(t.allocator);
        try fresh.update(t.allocator, &term);
        try t.expectEqual(fresh.cursor, displayed.cursor);
        try t.expectEqual(fresh.colors, displayed.colors);
        try t.expectEqual(fresh.screen, displayed.screen);
        try t.expectEqual(fresh.rows, displayed.rows);
        try t.expectEqual(fresh.cols, displayed.cols);
        for (0..fresh.rows) |y| {
            try t.expectEqual(fresh.row_data.items(.pin)[y], displayed.row_data.items(.pin)[y]);
            try t.expectEqual(fresh.row_data.items(.serial)[y], displayed.row_data.items(.serial)[y]);
            const expected = fresh.row_data.items(.cells)[y];
            const actual = displayed.row_data.items(.cells)[y];
            for (0..fresh.cols) |x| {
                const a = actual.get(x);
                const b = expected.get(x);
                try t.expectEqual(b.raw, a.raw);
                if (b.raw.style_id != 0) try t.expectEqual(b.style, a.style);
                if (b.raw.content_tag == .codepoint_grapheme) try t.expectEqualSlices(u21, b.grapheme, a.grapheme);
            }
        }
        displayed.clean();
    }
}

test "render hold failed accumulated capture recovers with complete live state" {
    const t = std.testing;
    var term = try terminal.Terminal.init(t.io, t.allocator, .{ .cols = 10, .rows = 3 });
    defer term.deinit(t.allocator);
    var hold: RenderHold = .{};
    defer hold.deinit(t.allocator);
    var displayed: terminal.RenderState = .empty;
    defer displayed.deinit(t.allocator);
    try warmTest(&hold, &displayed, &term);
    try term.printString("pending");
    try hold.capture(t.allocator, &term, .{ .width = 10, .height = 20 }, null);
    try term.resize(t.allocator, .{ .cols = 40, .rows = 12 });
    var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    try t.expectError(error.OutOfMemory, hold.capture(failing.allocator(), &term, .{ .width = 10, .height = 20 }, null));
    try t.expect(hold.pending == null);
    try t.expect(term.flags.dirty.clear);
    try displayed.update(t.allocator, &term);
    hold.syncLive(&displayed);
    try t.expectEqual('p', displayed.row_data.items(.cells)[0].get(0).raw.codepoint());
    try t.expectEqual(40, displayed.cols);
    try hold.capture(t.allocator, &term, .{ .width = 10, .height = 20 }, null);
    presentTest(&hold, &displayed);
    try t.expectEqual('p', displayed.row_data.items(.cells)[0].get(0).raw.codepoint());
}
