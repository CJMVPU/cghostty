//! Immutable, independently owned viewport highlights shared with rendering.
//! Page pointers inside flattened chunks remain identity tokens with serials;
//! consumers must never dereference them after the terminal lock is released.
const Self = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const Highlight = @import("../highlight.zig").Flattened;

storage: ?*Storage = null,
matches: []const Highlight = &.{},
pub const empty: Self = .{};

const Storage = struct {
    refs: std.atomic.Value(usize) = .init(1),
    arena: std.heap.ArenaAllocator,
};

pub fn retain(self: Self) Self {
    if (self.storage) |s| _ = s.refs.fetchAdd(1, .monotonic);
    return self;
}

pub fn deinit(self: Self) void {
    if (self.storage) |s| {
        if (s.refs.fetchSub(1, .acq_rel) != 1) return;
        // Storage itself belongs to the arena that is about to be freed.
        var arena = s.arena;
        arena.deinit();
    }
}

pub const Builder = struct {
    arena: std.heap.ArenaAllocator,
    matches: std.ArrayList(Highlight) = .empty,

    pub fn init(alloc: Allocator) Builder {
        return .{ .arena = .init(alloc) };
    }
    pub fn deinit(self: *Builder) void {
        self.arena.deinit();
    }
    pub fn append(self: *Builder, borrowed: Highlight) !void {
        const alloc = self.arena.allocator();
        try self.matches.append(alloc, try borrowed.clone(alloc));
    }
    pub fn finish(self: *Builder) !Self {
        if (self.matches.items.len == 0) return .empty;
        const storage = try self.arena.allocator().create(Storage);
        storage.* = .{ .arena = self.arena };
        const result: Self = .{ .storage = storage, .matches = self.matches.items };
        self.arena = .init(self.arena.child_allocator);
        self.matches = .empty;
        return result;
    }
};

test "search snapshot shares owned chunks and survives producer release" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(alloc: Allocator) !void {
            var source: Highlight = .empty;
            defer source.deinit(std.testing.allocator);
            var node: @import("../PageList.zig").List.Node = undefined;
            try source.chunks.append(std.testing.allocator, .{ .node = &node, .serial = 3, .start = 1, .end = 2 });
            var builder = Builder.init(alloc);
            defer builder.deinit();
            try builder.append(source);
            const first = try builder.finish();
            const second = first.retain();
            defer second.deinit();
            try std.testing.expectEqual(first.matches.ptr, second.matches.ptr);
            first.deinit();
            source.chunks.items(.serial)[0] = 99;
            try std.testing.expectEqual(@as(u64, 3), second.matches[0].chunks.items(.serial)[0]);
            const cleared = Self.empty.retain();
            cleared.deinit();
        }
    }.run, .{});
}

test "search snapshot retained consumers allocate no duplicate highlights" {
    const t = std.testing;
    var counter = t.FailingAllocator.init(t.allocator, .{});
    var builder = Builder.init(counter.allocator());
    defer builder.deinit();
    var source: Highlight = .empty;
    defer source.deinit(t.allocator);
    var node: @import("../PageList.zig").List.Node = undefined;
    try source.chunks.append(t.allocator, .{ .node = &node, .serial = 1, .start = 0, .end = 2 });
    for (0..1000) |_| try builder.append(source);
    const snapshot = try builder.finish();
    defer snapshot.deinit();
    const before = counter.allocations;
    for (0..100) |_| {
        const consumer = snapshot.retain();
        try t.expectEqual(snapshot.matches.ptr, consumer.matches.ptr);
        consumer.deinit();
    }
    try t.expectEqual(before, counter.allocations);
    std.debug.print("\nRESOURCE_METRIC search_matches=1000 consumers=100 additional_allocations={d}\n", .{counter.allocations - before});
}
