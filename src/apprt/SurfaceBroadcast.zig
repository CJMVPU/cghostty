//! Surface action traversal shared by the app and registry mutation tests.
const std = @import("std");

pub fn perform(registry: anytype, context: anytype, comptime apply: anytype) !void {
    // A native action may synchronously create or destroy surfaces. Capture
    // identities before dispatch so no callback observes a partial snapshot,
    // and never retain a pointer across another surface's callback.
    const alloc = registry.allocator();
    const current = registry.items();
    const ids = try alloc.alloc(u64, current.len);
    defer alloc.free(ids);
    for (current, ids) |surface, *id| id.* = registry.id(surface);
    for (ids) |id| {
        const surface = registry.find(id) orelse continue;
        // The callback may destroy this surface before returning an error.
        apply(context, surface) catch |err| registry.reportError(id, err);
    }
}

const TestRegistry = struct {
    const Surface = struct { id: u64 };
    alloc: std.mem.Allocator,
    surfaces: std.ArrayList(*Surface) = .empty,
    storage: [12]Surface = undefined,
    calls: [13]usize = @splat(0),
    errors: [13]usize = @splat(0),
    mutation: enum { none, remove_future, grow, remove_self_error } = .none,

    fn initialize(self: *TestRegistry) !void {
        self.surfaces = try .initCapacity(self.alloc, 3);
        for (&self.storage, 0..) |*surface, i| {
            surface.id = i + 1;
            if (i < 3) self.surfaces.appendAssumeCapacity(surface);
        }
    }

    pub fn items(self: *TestRegistry) []const *Surface {
        return self.surfaces.items;
    }

    pub fn allocator(self: *TestRegistry) std.mem.Allocator {
        return self.alloc;
    }

    pub fn id(_: *TestRegistry, surface: *Surface) u64 {
        return surface.id;
    }

    pub fn find(self: *TestRegistry, surface_id: u64) ?*Surface {
        for (self.surfaces.items) |surface| {
            if (surface.id == surface_id) return surface;
        }
        return null;
    }

    pub fn reportError(self: *TestRegistry, surface_id: u64, _: anyerror) void {
        self.errors[@intCast(surface_id)] += 1;
    }

    fn apply(self: *TestRegistry, surface: *Surface) !void {
        self.calls[@intCast(surface.id)] += 1;
        if (surface.id != 1 or self.mutation == .none) return;
        // Zig poisons entries invalidated by swapRemove/reallocation. Keep
        // the old arena allocation readable and restore its original values
        // so negative results are membership assertions, never poisoned reads.
        const old_items = self.surfaces.items;
        const old_values = old_items[0..3].*;
        defer @memcpy(old_items, &old_values);
        switch (self.mutation) {
            .none => {},
            .remove_future => {
                _ = self.surfaces.swapRemove(1);
                try self.detachRegistry();
            },
            .grow => for (self.storage[3..]) |*added| try self.surfaces.append(self.alloc, added),
            .remove_self_error => {
                _ = self.surfaces.swapRemove(0);
                try self.detachRegistry();
                return error.TestFailure;
            },
        }
    }

    fn detachRegistry(self: *TestRegistry) !void {
        var detached: std.ArrayList(*Surface) = try .initCapacity(self.alloc, self.surfaces.items.len);
        detached.appendSliceAssumeCapacity(self.surfaces.items);
        self.surfaces = detached;
    }
};

test "all surface actions skip a surface removed by an earlier callback" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var registry: TestRegistry = .{ .alloc = arena.allocator(), .mutation = .remove_future };
    try registry.initialize();
    try perform(&registry, &registry, TestRegistry.apply);
    try t.expectEqual(@as(usize, 1), registry.calls[1]);
    try t.expectEqual(@as(usize, 0), registry.calls[2]);
    try t.expectEqual(@as(usize, 1), registry.calls[3]);
}

test "all surface actions retain original membership when callbacks grow the registry" {
    const t = std.testing;
    // Keep the old backing allocation alive; the negative fixture does not
    // depend on reading freed memory when a callback forces registry growth.
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var registry: TestRegistry = .{ .alloc = arena.allocator(), .mutation = .grow };
    try registry.initialize();
    const original_capacity = registry.surfaces.capacity;
    try perform(&registry, &registry, TestRegistry.apply);
    try t.expect(registry.surfaces.items.len > original_capacity);
    try t.expectEqual(@as(usize, 12), registry.surfaces.items.len);
    for (registry.calls[1..4]) |count| try t.expectEqual(@as(usize, 1), count);
    for (registry.calls[4..13]) |count| try t.expectEqual(@as(usize, 0), count);
}

test "all surface actions allocation failure has no callback side effects" {
    const t = std.testing;
    var registry: TestRegistry = .{ .alloc = t.allocator };
    try registry.initialize();
    defer registry.surfaces.deinit(t.allocator);
    var failing: t.FailingAllocator = .init(t.allocator, .{ .fail_index = 0 });
    registry.alloc = failing.allocator();
    const result = perform(&registry, &registry, TestRegistry.apply);
    try t.expectEqual(@as(usize, 0), registry.calls[1]);
    try t.expectError(error.OutOfMemory, result);
}

test "all surface actions preserve identity when the current callback removes itself and fails" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var registry: TestRegistry = .{ .alloc = arena.allocator(), .mutation = .remove_self_error };
    try registry.initialize();
    try perform(&registry, &registry, TestRegistry.apply);
    for (registry.calls[1..4]) |count| try t.expectEqual(@as(usize, 1), count);
    try t.expectEqual(@as(usize, 1), registry.errors[1]);
    try t.expectEqual(@as(usize, 0), registry.errors[2]);
    try t.expectEqual(@as(usize, 0), registry.errors[3]);
}
