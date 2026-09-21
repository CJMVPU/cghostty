//! A frame is healthy only if GPU execution AND presentation succeed.
const std = @import("std");
const Health = @import("../renderer.zig").Health;

pub fn finish(api: anytype, target: anytype, sync: bool, health: Health) Health {
    if (health == .unhealthy) return .unhealthy;
    api.present(target, sync) catch |err| {
        if (!@import("builtin").is_test) std.log.scoped(.metal).err("Failed to present frame: {}", .{err});
        return .unhealthy;
    };
    return .healthy;
}

test "Presentation propagates display failures in synchronous and asynchronous paths" {
    const Fake = struct {
        fail: bool = false,
        calls: usize = 0,
        synchronous: bool = false,
        fn present(self: *@This(), _: u8, sync: bool) !void {
            self.calls += 1;
            self.synchronous = sync;
            if (self.fail) return error.TestPresentationFailed;
        }
    };
    for ([_]bool{ false, true }) |sync| {
        var api: Fake = .{};
        try std.testing.expectEqual(Health.healthy, finish(&api, @as(u8, 0), sync, .healthy));
        try std.testing.expectEqual(sync, api.synchronous);
        api.fail = true;
        try std.testing.expectEqual(Health.unhealthy, finish(&api, @as(u8, 0), sync, .healthy));
        try std.testing.expectEqual(Health.unhealthy, finish(&api, @as(u8, 0), sync, .unhealthy));
        try std.testing.expectEqual(@as(usize, 2), api.calls);
    }
}
