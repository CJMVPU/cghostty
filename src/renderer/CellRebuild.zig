//! Frame failure ownership. Keep a full rebuild pending until success; allow
//! two automatic retries per external update, then wait for another request.
const Self = @This();
pending: bool = false,
remaining: u2 = 0,
pub fn request(self: *Self) void {
    self.remaining = 2;
}
pub fn begin(self: *Self) void {
    if (self.pending and self.remaining > 0) self.remaining -= 1;
}
pub fn finish(self: *Self, failed: bool) void {
    self.pending = failed;
}
pub fn needsFrame(self: Self) bool {
    return self.pending and self.remaining > 0;
}
test "cell rebuild retries are bounded and rearmed by new input" {
    const t = @import("std").testing;
    var retry: Self = .{};
    retry.request();
    retry.begin();
    retry.finish(true);
    try t.expect(retry.needsFrame());
    retry.begin();
    retry.finish(true);
    try t.expect(retry.needsFrame());
    retry.begin();
    retry.finish(true);
    try t.expect(!retry.needsFrame());
    try t.expect(retry.pending);
    retry.request();
    try t.expect(retry.needsFrame());
    retry.begin();
    retry.finish(false);
    try t.expect(!retry.pending);
}
