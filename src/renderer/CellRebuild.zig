//! Frame preparation/draw failure ownership. Keep a full rebuild pending until success; allow
//! two automatic retries per external update, then wait for another request.
const Self = @This();
pending: bool = false,
remaining: u2 = 0,
pub fn request(self: *Self) void {
    self.remaining = 3;
}
/// Begin one attempt, including failures before cell rebuilding. A retained
/// failed request cannot replenish this budget; only request() can do that.
pub fn begin(self: *Self) bool {
    if (self.pending and self.remaining == 0) return false;
    if (!self.pending and self.remaining == 0) self.remaining = 3;
    self.remaining -= 1;
    return true;
}
pub fn finish(self: *Self, failed: bool) void {
    self.pending = failed;
}
pub fn needsFrame(self: Self) bool {
    return self.pending and self.remaining > 0;
}
/// Other panes may still drive final composition after this pane exhausts its
/// budget. Keep its composed result, but never let it prolong the window clock.
pub fn frameResult(prepared: bool, result: @import("CompositorResult.zig").Result) @import("CompositorResult.zig").Result {
    var value = result;
    if (!prepared) value.needs_frame = false;
    return value;
}

test "cell rebuild retries are bounded and rearmed by new input" {
    const t = @import("std").testing;
    var retry: Self = .{};
    retry.request();
    try t.expect(retry.begin());
    retry.finish(true);
    try t.expect(retry.needsFrame());
    try t.expect(retry.begin());
    retry.finish(true);
    try t.expect(retry.needsFrame());
    try t.expect(retry.begin());
    retry.finish(true);
    try t.expect(!retry.needsFrame());
    try t.expect(retry.pending);
    retry.request();
    try t.expect(retry.needsFrame());
    try t.expect(retry.begin());
    retry.finish(false);
    try t.expect(!retry.pending);
}

test "cell rebuild early allocation failures exhaust budget and retain published cells" {
    const std = @import("std");
    const t = std.testing;
    const terminal = @import("../terminal/main.zig");
    const Contents = @import("cell.zig").Contents;
    const Preedit = @import("State.zig").Preedit;
    for (0..3) |stage| {
        var retry: Self = .{};
        retry.request();
        var term = try terminal.Terminal.init(t.io, t.allocator, .{ .cols = 8, .rows = 2 });
        defer term.deinit(t.allocator);
        try term.printString("published");
        var render: terminal.RenderState = .empty;
        defer render.deinit(t.allocator);
        var cells: Contents = .{};
        defer cells.deinit(t.allocator);
        try cells.resize(t.allocator, .{ .rows = 2, .columns = 8 });
        cells.bgCell(0, 0).* = .{ 1, 2, 3, 4 };
        const version = cells.bg_versions[0];
        const preedit: Preedit = .{ .codepoints = &.{.{ .codepoint = 'a' }} };
        for (0..3) |_| {
            try t.expect(retry.begin());
            var failure = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
            const alloc = failure.allocator();
            switch (stage) {
                0 => try t.expectError(error.OutOfMemory, render.beginUpdate(alloc, &term)),
                1 => try t.expectError(error.OutOfMemory, preedit.clone(alloc)),
                2 => try t.expectError(error.OutOfMemory, cells.resize(alloc, .{ .rows = 3, .columns = 9 })),
                else => unreachable,
            }
            retry.finish(true);
            try t.expectEqual(@as(@import("../renderer.zig").Metal.shaders.CellBg, .{ 1, 2, 3, 4 }), cells.bgCell(0, 0).*);
            try t.expectEqual(version, cells.bg_versions[0]);
        }
        try t.expect(!retry.needsFrame());
        try t.expect(!retry.begin());
        retry.request();
        try t.expect(retry.begin());
        try render.update(t.allocator, &term);
        const cloned = try preedit.clone(t.allocator);
        cloned.deinit(t.allocator);
        try cells.resize(t.allocator, .{ .rows = 3, .columns = 9 });
        retry.finish(false);
        try t.expect(!retry.pending);
    }
}

test "cell rebuild exhausted pane still composes without self waking" {
    const t = @import("std").testing;
    var retry: Self = .{};
    retry.request();
    for (0..3) |_| {
        try t.expect(retry.begin());
        retry.finish(true);
    }
    for (0..100) |_| {
        const prepared = retry.begin();
        try t.expect(!prepared);
        const result = frameResult(prepared, .{ .composed = true, .needs_frame = true });
        try t.expect(result.composed);
        try t.expect(!result.needs_frame);
        try t.expect(retry.pending);
        try t.expectEqual(@as(u2, 0), retry.remaining);
    }
    retry.request();
    const prepared = retry.begin();
    try t.expect(prepared);
    try t.expect(frameResult(prepared, .{ .needs_frame = true }).needs_frame);
}
