//! Draw-lock-owned scroll textures and cache identity. The renderer owns pass
//! ordering and shared hit publication; this object owns only scene resources.
const std = @import("std");
const ScrollMotion = @import("ScrollMotion.zig");

pub const Key = struct {
    content: u64,
    images: u64,
    background: [4]u8,
};

pub const Scene = Pool(@import("Metal.zig").Texture);

fn Pool(comptime Texture: type) type {
    return struct {
        const Self = @This();
        textures: [3]?Texture = @splat(null),
        scene: ?usize = null,
        previous: ?usize = null,
        presented: ?usize = null,
        key: ?Key = null,
        config: usize = 0,
        motion: ScrollMotion = .{},
        failed: std.atomic.Value(bool) = .init(false),

        pub fn reset(self: *Self) void {
            for (&self.textures) |*texture| {
                if (texture.*) |t| t.deinit();
                texture.* = null;
            }
            self.scene = null;
            self.previous = null;
            self.presented = null;
            self.key = null;
            self.motion = .{};
        }

        pub fn dirty(self: *const Self, key: Key) bool {
            return self.scene == null or self.key == null or !std.meta.eql(self.key.?, key);
        }

        pub fn acquire(self: *Self, api: anytype, width: u32, height: u32, excluded: []const ?usize) !usize {
            outer: for (&self.textures, 0..) |*texture, i| {
                for (excluded) |index| if (index == i) continue :outer;
                if (texture.* == null) texture.* = try api.initContentTexture(width, height);
                return i;
            }
            unreachable; // Three slots: scene, history, composed destination.
        }
    };
}

const FakeTexture = struct {
    live: *usize,
    pub fn deinit(self: FakeTexture) void {
        self.live.* -= 1;
    }
};
const FakeApi = struct {
    live: usize = 0,
    fail: bool = false,
    pub fn initContentTexture(self: *FakeApi, _: u32, _: u32) !FakeTexture {
        if (self.fail) return error.OutOfMemory;
        self.live += 1;
        return .{ .live = &self.live };
    }
};

test "ScrollScene excludes live history retries allocation and resets ownership" {
    const t = std.testing;
    var api: FakeApi = .{};
    var scene: Pool(FakeTexture) = .{};
    defer scene.reset();
    const key: Key = .{ .content = 1, .images = 2, .background = .{ 0, 0, 0, 255 } };
    try t.expect(scene.dirty(key));
    scene.scene = try scene.acquire(&api, 100, 100, &.{});
    scene.key = key;
    try t.expect(!scene.dirty(key));
    scene.presented = scene.scene;
    scene.previous = scene.presented;
    api.fail = true;
    try t.expectError(error.OutOfMemory, scene.acquire(&api, 100, 100, &.{scene.previous}));
    try t.expectEqual(@as(usize, 1), api.live);
    api.fail = false;
    scene.scene = try scene.acquire(&api, 100, 100, &.{scene.previous});
    const destination = try scene.acquire(&api, 100, 100, &.{ scene.scene, scene.previous });
    try t.expect(destination != scene.scene and destination != scene.previous);
    var changed = key;
    changed.images += 1;
    try t.expect(scene.dirty(changed));
    changed = key;
    changed.background[3] = 0;
    try t.expect(scene.dirty(changed));
    scene.reset();
    scene.reset();
    try t.expectEqual(@as(usize, 0), api.live);
    try t.expect(scene.dirty(key));
}
