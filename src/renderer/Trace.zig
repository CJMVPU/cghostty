//! Opt-in local performance trace. Never records terminal text or input.
//! Set CGHOSTTY_RENDER_TRACE to an existing directory; one CSV per surface.
const Self = @This();
const std = @import("std");
const global = @import("../global.zig");
var serial: std.atomic.Value(u64) = .init(0);
file: ?std.Io.File = null,
mutex: std.Io.Mutex = .init,

pub fn init(alloc: std.mem.Allocator) Self {
    const directory = global.environ().getAlloc(alloc, "CGHOSTTY_RENDER_TRACE") catch return .{};
    defer alloc.free(directory);
    const path = std.fmt.allocPrint(alloc, "{s}/render-{d}-{d}.csv", .{ directory, clock(), serial.fetchAdd(1, .monotonic) }) catch return .{};
    defer alloc.free(path);
    const file = std.Io.Dir.createFileAbsolute(global.io(), path, .{ .permissions = .fromMode(0o600), .exclusive = true }) catch return .{};
    return .{ .file = file };
}

pub fn deinit(self: *Self) void {
    if (self.file) |file| file.close(global.io());
}

pub fn clock() u64 {
    return @intCast(std.Io.Timestamp.now(global.io(), .awake).nanoseconds);
}

/// event,time_ns,a,b,c. Draw: wall CPU path ns / copied cell bytes / segments.
/// GPU: execution ns / healthy / unused. Timer: update kind / vsync / unused.
pub fn emit(self: *Self, event: []const u8, a: u64, b: u64, c: u64) void {
    const file = self.file orelse return;
    var buffer: [160]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, "{s},{d},{d},{d},{d}\n", .{ event, clock(), a, b, c }) catch return;
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    file.writeStreamingAll(global.io(), line) catch {};
}
