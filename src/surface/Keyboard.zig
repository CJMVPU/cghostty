//! Surface keyboard state. Owns queued writes and bounded key-table state;
//! native notifications and IO delivery stay with Surface.
const Self = @This();
const std = @import("std");
const input = @import("../input.zig");
const termio = @import("../termio.zig");
pub const max_active_key_tables = 8;
pub const SequenceAction = enum { flush, drop };
pub const SequenceMemory = enum { retain, free };

/// The currently active key sequence for the surface. If this is null
/// then we're not currently in a key sequence.
sequence_set: ?*const input.Binding.Set = null,

/// The queued keys when we're in the middle of a sequenced binding.
/// These are flushed when the sequence is completed and unconsumed or
/// invalid.
///
/// This is naturally bounded due to the configuration maximum
/// length of a sequence.
sequence_queued: std.ArrayListUnmanaged(termio.Message.WriteReq) = .empty,

/// The stack of tables that is currently active. The first value
/// in this is the first activated table (NOT the default keybinding set).
///
/// This is bounded by `max_active_key_tables`.
table_stack: std.ArrayListUnmanaged(struct {
    set: *const input.Binding.Set,
    once: bool,
}) = .empty,

/// The last handled binding. This is used to prevent encoding release
/// events for handled bindings. We only need to keep track of one because
/// at least at the time of writing this, its impossible for two keys of
/// a combination to be handled by different bindings before the release
/// of the prior (namely since you can't bind modifier-only).
last_trigger: ?u64 = null,

pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
    for (self.sequence_queued.items) |req| req.deinit();
    self.sequence_queued.deinit(alloc);
    self.table_stack.deinit(alloc);
    self.* = .{};
}

pub fn activateTable(self: *Self, alloc: std.mem.Allocator, set: *const input.Binding.Set, once: bool) !bool {
    const items = self.table_stack.items;
    if (items.len > 0 and items[items.len - 1].set == set) return false;
    if (items.len >= max_active_key_tables) return false;
    try self.table_stack.append(alloc, .{ .set = set, .once = once });
    return true;
}

pub fn deactivateTable(self: *Self, alloc: std.mem.Allocator) bool {
    switch (self.table_stack.items.len) {
        0 => return false,
        1 => self.table_stack.clearAndFree(alloc),
        else => _ = self.table_stack.pop(),
    }
    return true;
}

pub fn deactivateAll(self: *Self, alloc: std.mem.Allocator) bool {
    if (self.table_stack.items.len == 0) return false;
    self.table_stack.clearAndFree(alloc);
    return true;
}

/// Takes ownership even if appending fails.
pub fn queueSequence(self: *Self, alloc: std.mem.Allocator, req: termio.Message.WriteReq) !void {
    errdefer req.deinit();
    try self.sequence_queued.append(alloc, req);
}

pub fn endSequence(self: *Self, alloc: std.mem.Allocator, action: SequenceAction, memory: SequenceMemory, context: anytype, comptime send: fn (@TypeOf(context), termio.Message.WriteReq) void) void {
    self.sequence_set = null;
    for (self.sequence_queued.items) |req| switch (action) {
        .flush => send(context, req),
        .drop => req.deinit(),
    };
    switch (memory) {
        .free => self.sequence_queued.clearAndFree(alloc),
        .retain => self.sequence_queued.clearRetainingCapacity(),
    }
}
pub fn catchAllIsIgnore(self: *const Self, default: *const input.Binding.Set) bool {
    // Get our catch all
    const entry: input.Binding.Set.Entry = entry: {
        const trigger: input.Binding.Trigger = .{ .key = .catch_all };

        const table_items = self.table_stack.items;
        for (0..table_items.len) |i| {
            const rev_i: usize = table_items.len - 1 - i;
            const entry = table_items[rev_i].set.get(trigger) orelse continue;
            break :entry entry;
        }

        break :entry default.get(trigger) orelse
            return false;
    };

    // We have a catch-all entry, see if its an ignore
    return switch (entry.value_ptr.*) {
        .leader => false,
        .leaf => |leaf| leaf.action == .ignore,
        .leaf_chained => |leaf| chained: for (leaf.actions.items) |action| {
            if (action == .ignore) break :chained true;
        } else false,
    };
}

test "Surface Keyboard tables preserve precedence depth and one-shot metadata" {
    const t = std.testing;
    var state: Self = .{};
    defer state.deinit(t.allocator);
    var sets: [9]input.Binding.Set = @splat(.{});
    defer for (&sets) |*set| set.deinit(t.allocator);
    try sets[0].parseAndPut(t.allocator, "catch_all=ignore");
    try sets[1].parseAndPut(t.allocator, "catch_all=text:hello");
    try t.expect(state.catchAllIsIgnore(&sets[0]));
    for (&sets, 0..) |*set, i| try t.expectEqual(i < max_active_key_tables, try state.activateTable(t.allocator, set, true));
    try t.expect(!state.catchAllIsIgnore(&sets[0]));
    try t.expect(state.table_stack.items[7].once);
    try t.expect(!try state.activateTable(t.allocator, &sets[7], false));
    try t.expect(state.deactivateAll(t.allocator));
    try t.expect(!state.deactivateAll(t.allocator));
    try t.expect(!state.deactivateTable(t.allocator));
    _ = try state.activateTable(t.allocator, &sets[1], true);
    _ = try state.activateTable(t.allocator, &sets[0], false);
    try t.expect(state.catchAllIsIgnore(&sets[0]));
    try t.expect(state.deactivateTable(t.allocator));
    try t.expect(!state.catchAllIsIgnore(&sets[0]));
}

const Sink = struct {
    count: usize = 0,
    bytes: usize = 0,
    fn send(self: *Sink, req: termio.Message.WriteReq) void {
        self.count += 1;
        self.bytes += req.slice().len;
        req.deinit();
    }
};

test "Surface Keyboard sequences transfer or release writes and free retained empty storage" {
    const t = std.testing;
    var state: Self = .{};
    defer state.deinit(t.allocator);
    var set: input.Binding.Set = .{};
    state.sequence_set = &set;
    var sink: Sink = .{};
    try state.queueSequence(t.allocator, try .init(t.allocator, @as([]const u8, "a")));
    try state.queueSequence(t.allocator, try .init(t.allocator, @as([]const u8, "x" ** 100)));
    state.endSequence(t.allocator, .flush, .retain, &sink, Sink.send);
    try t.expectEqual(@as(usize, 2), sink.count);
    try t.expectEqual(@as(usize, 101), sink.bytes);
    try t.expectEqual(null, state.sequence_set);
    try t.expect(state.sequence_queued.capacity > 0);
    state.endSequence(t.allocator, .drop, .free, &sink, Sink.send);
    try t.expectEqual(@as(usize, 0), state.sequence_queued.capacity);
    try state.queueSequence(t.allocator, try .init(t.allocator, @as([]const u8, "y" ** 100)));
    state.endSequence(t.allocator, .drop, .free, &sink, Sink.send);
    try t.expectEqual(@as(usize, 2), sink.count);
    var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    try t.expectError(error.OutOfMemory, state.queueSequence(failing.allocator(), try .init(t.allocator, @as([]const u8, "z" ** 100))));
}
