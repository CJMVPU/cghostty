//! Owned strings returned across the inherited-surface configuration bridge.
const std = @import("std");

pub fn copyWorkingDirectory(alloc: std.mem.Allocator, cwd: []const u8) ?[*:0]const u8 {
    return alloc.dupeZ(u8, cwd) catch null;
}

pub fn freeWorkingDirectory(alloc: std.mem.Allocator, cwd: *?[*:0]const u8) void {
    const ptr = cwd.* orelse return;
    alloc.free(std.mem.sliceTo(ptr, 0));
    cwd.* = null;
}

test "inherited surface options release the working directory after copying" {
    const t = std.testing;
    const cwd = "/tmp/cghostty-inherited";
    var tracking: t.FailingAllocator = .init(t.allocator, .{});
    const alloc = tracking.allocator();
    var configs: [32]?[*:0]const u8 = @splat(null);
    defer for (&configs) |*config| freeWorkingDirectory(alloc, config);
    for (&configs) |*config| {
        // This is the allocation used by embedded.newSurfaceOptions. Its
        // native consumer String(cString:) also makes a separate copy.
        config.* = copyWorkingDirectory(alloc, cwd);
        const ptr = config.* orelse return error.MissingWorkingDirectory;
        const copied = try t.allocator.dupe(u8, std.mem.sliceTo(ptr, 0));
        defer t.allocator.free(copied);
        freeWorkingDirectory(alloc, config);
        // The caller retains its copy after releasing the returned C value.
        try t.expect(config.* == null);
        try t.expectEqualStrings(cwd, copied);
    }
    try t.expectEqual(@as(usize, 0), tracking.allocated_bytes - tracking.freed_bytes);
}

test "inherited surface options handle working directory allocation failure" {
    const t = std.testing;
    var failing: t.FailingAllocator = .init(t.allocator, .{ .fail_index = 0 });
    try t.expect(copyWorkingDirectory(failing.allocator(), "/tmp") == null);
    var empty: ?[*:0]const u8 = null;
    freeWorkingDirectory(failing.allocator(), &empty);
    try t.expectEqual(@as(usize, 0), failing.allocated_bytes - failing.freed_bytes);
}
