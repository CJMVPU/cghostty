//! A single completed viewport waiting for the GUI renderer. Access is
//! serialized by renderer.State.mutex; no GPU work runs on the IO thread.
const RenderHold = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const terminal = @import("../terminal/main.zig");
const image = @import("image.zig");
const CellSize = @import("size.zig").CellSize;

pending: ?Frame = null,

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
    self.* = .{};
}

/// Capture before processing any bytes belonging to the next frame. A
/// second capture replaces the pending frame, never queues more history.
pub fn capture(self: *RenderHold, alloc: Allocator, t: *terminal.Terminal, cell: CellSize, mouse: ?terminal.point.Coordinate) !void {
    var frame: Frame = .{
        .scrollbar = t.screens.active.pages.scrollbar(),
        .link_key = .read(t),
        .mouse = mouse,
    };
    errdefer frame.deinit(alloc);
    // This independent consumer must neither depend on nor steal another
    // consumer's dirty bits. Force a complete viewport and leave a complete
    // refresh pending for the next live update (also on allocation failure).
    t.flags.dirty.clear = true;
    defer t.flags.dirty.clear = true;
    try frame.render.beginUpdate(alloc, t);
    // OSC8 resolution dereferences terminal pages, unlike regex matching.
    // Resolve it now while these pages still describe the captured frame.
    if (mouse) |vp| frame.osc8 = try frame.render.linkCells(alloc, vp);
    // Keep style expansion on the renderer thread. All pending style data
    // is owned by RenderState, including after terminal pages are pruned.
    frame.images.kittyUpdate(alloc, t, cell);
    t.screens.active.kitty_images.dirty = true;
    self.deinit(alloc);
    self.pending = frame;
}

/// The caller owns the returned frame. If the hold ended (including a
/// resize, reset or timeout), the live terminal supersedes the snapshot.
pub fn take(self: *RenderHold, alloc: Allocator, held: bool) ?Frame {
    if (!held) {
        self.deinit(alloc);
        return null;
    }
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
    var frame = hold.take(alloc, true).?;
    defer frame.deinit(alloc);
    frame.render.endUpdate();
    try t.expectEqual('A', frame.render.row_data.items(.cells)[0].get(0).raw.codepoint());
    try t.expectEqual('B', frame.render.row_data.items(.cells)[0].get(1).raw.codepoint());
    try t.expect(hold.take(alloc, true) == null);
    var live: terminal.RenderState = .empty;
    defer live.deinit(alloc);
    try live.update(alloc, &term);
    try t.expectEqual('X', live.row_data.items(.cells)[0].get(0).raw.codepoint());
    // Capturing again must see the whole viewport even after another
    // renderer consumed the terminal's dirty flags.
    try hold.capture(alloc, &term, .{ .width = 10, .height = 20 }, null);
    try t.expect(term.flags.dirty.clear);
    try t.expect(hold.take(alloc, false) == null);
    try t.expect(hold.pending == null);
}

test "render hold releases snapshots after resize reset and timeout" {
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
        try t.expect(hold.take(t.allocator, term.modes.get(.synchronized_output)) == null);
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
    var frame = hold.take(t.allocator, true).?;
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
    var frame = hold.take(alloc, true).?;
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
