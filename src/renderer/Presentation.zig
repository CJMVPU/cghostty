//! GPU completion and presentation submission health. Asynchronous acceptance
//! does not mean Core Animation or the display has consumed the frame.
const std = @import("std");
const Health = @import("../renderer.zig").Health;

pub fn finish(api: anytype, target: anytype, sync: bool, health: Health, sequence: u64) Health {
    if (health == .unhealthy) return .unhealthy;
    api.present(target, sync, sequence) catch |err| {
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
        fn present(self: *@This(), _: u8, sync: bool, _: u64) !void {
            self.calls += 1;
            self.synchronous = sync;
            if (self.fail) return error.TestPresentationFailed;
        }
    };
    for ([_]bool{ false, true }) |sync| {
        var api: Fake = .{};
        try std.testing.expectEqual(Health.healthy, finish(&api, @as(u8, 0), sync, .healthy, 1));
        try std.testing.expectEqual(sync, api.synchronous);
        api.fail = true;
        try std.testing.expectEqual(Health.unhealthy, finish(&api, @as(u8, 0), sync, .healthy, 1));
        try std.testing.expectEqual(Health.unhealthy, finish(&api, @as(u8, 0), sync, .unhealthy, 2));
        try std.testing.expectEqual(@as(usize, 2), api.calls);
    }
}
