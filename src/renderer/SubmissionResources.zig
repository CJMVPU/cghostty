//! Footprints of committed residency sets until their command references are
//! retired. A resource shared by multiple submissions is counted in each set;
//! this is neither unique allocation bytes nor additional renderer ownership.
const Self = @This();
const std = @import("std");

current: std.atomic.Value(u64) = .init(0),
peak: std.atomic.Value(u64) = .init(0),

pub fn acquire(self: *Self, bytes: u64) void {
    const total = self.current.fetchAdd(bytes, .monotonic) + bytes;
    _ = self.peak.fetchMax(total, .monotonic);
}

pub fn release(self: *Self, bytes: u64) void {
    const previous = self.current.fetchSub(bytes, .monotonic);
    std.debug.assert(previous >= bytes);
}

test "submission resources preserve overlapping footprints and the lifetime peak" {
    const t = std.testing;
    var usage: Self = .{};
    usage.acquire(100);
    usage.acquire(200);
    usage.release(100);
    usage.acquire(50);
    try t.expectEqual(@as(u64, 250), usage.current.load(.monotonic));
    try t.expectEqual(@as(u64, 300), usage.peak.load(.monotonic));
    usage.release(200);
    usage.release(50);
    try t.expectEqual(@as(u64, 0), usage.current.load(.monotonic));
    try t.expectEqual(@as(u64, 300), usage.peak.load(.monotonic));
}

test "submission resources count concurrent completions without losing the peak" {
    const t = std.testing;
    const Worker = struct {
        fn run(usage: *Self, bytes: u64, ready: *std.Io.Semaphore, retire: *std.Io.Semaphore) void {
            usage.acquire(bytes);
            ready.post(t.io);
            retire.waitUncancelable(t.io);
            usage.release(bytes);
        }
    };
    var usage: Self = .{};
    var ready: std.Io.Semaphore = .{};
    var retire: std.Io.Semaphore = .{};
    const first = try std.Thread.spawn(.{}, Worker.run, .{ &usage, 100, &ready, &retire });
    // Even if the second spawn fails, the first worker can finish.
    const second = std.Thread.spawn(.{}, Worker.run, .{ &usage, 200, &ready, &retire }) catch |err| {
        retire.post(t.io);
        first.join();
        return err;
    };
    ready.waitUncancelable(t.io);
    ready.waitUncancelable(t.io);
    const current = usage.current.load(.monotonic);
    const peak = usage.peak.load(.monotonic);
    retire.post(t.io);
    retire.post(t.io);
    second.join();
    // The first worker is joined before reading the final state.
    first.join();
    try t.expectEqual(@as(u64, 300), current);
    try t.expectEqual(@as(u64, 300), peak);
    try t.expectEqual(@as(u64, 0), usage.current.load(.monotonic));
}
