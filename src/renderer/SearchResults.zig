//! Latest owned search highlights. Producers never wait for queue capacity.
//! Each replacement releases superseded storage; take transfers ownership.
const Self = @This();
const std = @import("std");
const global = @import("../global.zig");
const Message = @import("message.zig").Message;

mutex: std.Io.Mutex = .init,
pending: Pending = .{},

pub const Pending = struct {
    matches: ?Message.SearchMatches = null,
    selected_changed: bool = false,
    selected: ?Message.SearchMatch = null,

    pub fn deinit(self: *Pending) void {
        if (self.matches) |matches| matches.deinit();
        if (self.selected) |*selected| selected.arena.deinit();
        self.* = .{};
    }
};

pub fn deinit(self: *Self) void {
    var pending = self.take();
    pending.deinit();
}

pub fn publishMatches(self: *Self, owned: Message.SearchMatches) void {
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    if (self.pending.matches) |old| old.deinit();
    self.pending.matches = owned;
}

pub fn publishSelected(self: *Self, owned: ?Message.SearchMatch) void {
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    if (self.pending.selected) |*old| old.arena.deinit();
    self.pending.selected = owned;
    self.pending.selected_changed = true;
}

pub fn clear(self: *Self) void {
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    self.pending.deinit();
    self.pending = .{ .matches = .empty, .selected_changed = true };
}

pub fn take(self: *Self) Pending {
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    const result = self.pending;
    self.pending = .{};
    return result;
}

test "search results coalesce owned highlights and clear without a consumer" {
    const t = std.testing;
    var results: Self = .{};
    defer results.deinit();
    for (0..100) |_| {
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        const chunks = try arena.allocator().alloc(u8, 1024);
        @memset(chunks, 0);
        results.publishSelected(.{ .arena = arena, .match = .empty });
        results.publishMatches(@import("../terminal/search/Snapshot.zig").empty.retain());
    }
    var pending = results.take();
    defer pending.deinit();
    try t.expect(pending.selected_changed);
    try t.expect(pending.selected != null);
    try t.expect(pending.matches != null);
    results.clear();
    var cleared = results.take();
    defer cleared.deinit();
    try t.expect(cleared.selected_changed);
    try t.expect(cleared.selected == null);
    try t.expect(cleared.matches != null);
    var empty = results.take();
    defer empty.deinit();
    try t.expect(!empty.selected_changed);
    try t.expect(empty.matches == null);
}
