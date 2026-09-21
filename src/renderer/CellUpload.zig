//! Per-swap-chain-slot content revision. Commit only after BOTH cell uploads
//! succeed; another slot being current does not make this slot current.
const Self = @This();
revision: ?u64 = null,
foreground_count: usize = 0,

pub fn needed(self: Self, revision: u64) bool {
    return self.revision == null or self.revision.? != revision;
}

pub fn commit(self: *Self, revision: u64, count: usize) void {
    self.* = .{ .revision = revision, .foreground_count = count };
}

pub fn invalidate(self: *Self) void {
    self.revision = null;
}

test "CellUpload independent slots catch up and interrupted uploads remain dirty" {
    const t = @import("std").testing;
    var slots = [_]Self{ .{}, .{}, .{} };
    for (&slots) |*slot| {
        try t.expect(slot.needed(0));
        slot.commit(0, 100);
    }
    for (0..30) |i| try t.expect(!slots[i % 3].needed(0));
    slots[0].commit(1, 50);
    try t.expect(!slots[0].needed(1));
    try t.expect(slots[1].needed(1));
    // Background upload completed, foreground upload failed: no commit.
    try t.expect(slots[1].needed(1));
    try t.expectEqual(@as(usize, 100), slots[1].foreground_count);
    slots[1].commit(1, 0);
    try t.expectEqual(@as(usize, 0), slots[1].foreground_count);
    slots[0].invalidate();
    try t.expect(slots[0].needed(1));
}
