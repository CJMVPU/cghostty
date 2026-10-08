const std = @import("std");
const Allocator = std.mem.Allocator;

/// Single-threaded accounting for one allocation phase. Counts requested live
/// bytes, excluding child allocator overhead. No headers or layout changes:
/// surviving allocations may be transferred back to the same child allocator.
/// `initial_bytes` accounts for existing child allocations freed/resized here.
pub const PeakAllocator = struct {
    child: Allocator,
    live_bytes: usize,
    peak_bytes: usize,

    pub fn init(child: Allocator, initial_bytes: usize) PeakAllocator {
        return .{ .child = child, .live_bytes = initial_bytes, .peak_bytes = initial_bytes };
    }

    pub fn allocator(self: *PeakAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn replace(self: *PeakAllocator, old: usize, new: usize) void {
        self.live_bytes = self.live_bytes - old + new;
        self.peak_bytes = @max(self.peak_bytes, self.live_bytes);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *PeakAllocator = @ptrCast(@alignCast(ctx));
        const result = self.child.rawAlloc(len, alignment, ra) orelse return null;
        self.replace(0, len);
        return result;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *PeakAllocator = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(memory, alignment, new_len, ra)) return false;
        self.replace(memory.len, new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *PeakAllocator = @ptrCast(@alignCast(ctx));
        const result = self.child.rawRemap(memory, alignment, new_len, ra) orelse return null;
        self.replace(memory.len, new_len);
        return result;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *PeakAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ra);
        self.replace(memory.len, 0);
    }
};

test "PeakAllocator preserves accounting across failed growth and ownership transfer" {
    const t = std.testing;
    var child = t.FailingAllocator.init(t.allocator, .{ .resize_fail_index = 0 });
    const existing = try child.allocator().alloc(u8, 8);
    var peak: PeakAllocator = .init(child.allocator(), existing.len);
    const alloc = peak.allocator();
    const extra = try alloc.alloc(u8, 16);
    try t.expectEqual(@as(usize, 24), peak.peak_bytes);
    try t.expect(!alloc.resize(extra, 32));
    try t.expect(alloc.remap(extra, 32) == null);
    child.fail_index = child.alloc_index;
    try t.expectError(error.OutOfMemory, alloc.alloc(u8, 64));
    try t.expectEqual(@as(usize, 24), peak.live_bytes);
    try t.expectEqual(@as(usize, 24), peak.peak_bytes);
    alloc.free(existing);
    try t.expectEqual(@as(usize, 16), peak.live_bytes);
    // Surviving output uses exactly the child's allocation layout.
    child.allocator().free(extra);
    try t.expectEqual(child.allocated_bytes, child.freed_bytes);
}

test "PeakAllocator counts successful resize and remap once" {
    const t = std.testing;
    var storage: [64]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&storage);
    var peak: PeakAllocator = .init(fixed.allocator(), 0);
    const alloc = peak.allocator();
    const bytes = try alloc.alloc(u8, 8);
    try t.expect(alloc.resize(bytes, 16));
    const grown: []u8 = bytes.ptr[0..16];
    const moved = alloc.remap(grown, 32).?;
    try t.expectEqual(@as(usize, 32), peak.live_bytes);
    try t.expect(alloc.resize(moved, 4));
    try t.expectEqual(@as(usize, 4), peak.live_bytes);
    try t.expectEqual(@as(usize, 32), peak.peak_bytes);
    const shrunk: []u8 = moved.ptr[0..4];
    alloc.free(shrunk);
    try t.expectEqual(@as(usize, 0), peak.live_bytes);
}
