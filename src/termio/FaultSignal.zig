//! First worker failure, delivered once by the app thread without queue space.
const Self = @This();
const std = @import("std");

code: std.atomic.Value(u16) = .init(0),
delivered: bool = false,

pub fn publish(self: *Self, err: anyerror) bool {
    return self.code.cmpxchgStrong(0, @intFromError(err), .release, .monotonic) == null;
}

/// Only the app thread consumes this signal. The first error remains sticky.
pub fn take(self: *Self) ?anyerror {
    if (self.delivered) return null;
    const code = self.code.load(.acquire);
    if (code == 0) return null;
    self.delivered = true;
    return @errorFromInt(code);
}

test "IO fault signal preserves the first failure and delivers once" {
    const t = std.testing;
    var signal: Self = .{};
    try t.expect(signal.take() == null);
    try t.expect(signal.publish(error.ThreadQuotaExceeded));
    try t.expect(!signal.publish(error.OutOfMemory));
    try t.expectEqual(error.ThreadQuotaExceeded, signal.take().?);
    try t.expect(signal.take() == null);
    try t.expect(!signal.publish(error.Unexpected));
}
