//! Synchronize one frame slot without consuming other slots' change history.
const std = @import("std");
const Atlas = @import("../font/Atlas.zig");

/// Caller owns a free frame slot and holds the font grid's shared lock.
/// Returns actual texel bytes submitted (source row padding is not uploaded).
pub fn sync(api: anytype, atlas: *const Atlas, texture: anytype, version: *usize) !usize {
    const current = atlas.modified.load(.monotonic);
    var region = atlas.changedRegion(version.*) orelse return 0;
    if (atlas.size > texture.width) {
        // Build and populate the replacement before releasing any live resource.
        var replacement = try api.initAtlasTexture(atlas);
        errdefer replacement.deinit();
        try replacement.replaceRegionStrided(0, 0, atlas.size, atlas.size, atlas.data, @as(usize, atlas.size) * atlas.format.depth());
        texture.deinit();
        texture.* = replacement;
        region = .{ .x = 0, .y = 0, .width = atlas.size, .height = atlas.size };
    } else {
        const stride = @as(usize, atlas.size) * atlas.format.depth();
        const offset = @as(usize, region.y) * stride + @as(usize, region.x) * atlas.format.depth();
        try texture.replaceRegionStrided(region.x, region.y, region.width, region.height, atlas.data[offset..], stride);
    }
    version.* = current;
    return @as(usize, region.width) * region.height * atlas.format.depth();
}

const FakeApi = struct {
    fail: bool = false,
    releases: usize = 0,
    pub fn initAtlasTexture(self: *FakeApi, atlas: *const Atlas) !FakeTexture {
        if (self.fail) return error.MetalFailed;
        return .{ .api = self, .width = atlas.size, .bpp = atlas.format.depth() };
    }
};
const FakeTexture = struct {
    api: *FakeApi,
    width: usize,
    bpp: usize,
    pixels: [64 * 64 * 4]u8 = @splat(0),
    pub fn deinit(self: *FakeTexture) void {
        self.api.releases += 1;
    }
    pub fn replaceRegionStrided(self: *FakeTexture, x: usize, y: usize, width: usize, height: usize, data: []const u8, stride: usize) !void {
        for (0..height) |row| {
            const dst = ((y + row) * self.width + x) * self.bpp;
            @memcpy(self.pixels[dst..][0 .. width * self.bpp], data[row * stride ..][0 .. width * self.bpp]);
        }
    }
};

test "atlas upload failure keeps old texture and version and retries" {
    const t = std.testing;
    var atlas = try Atlas.init(t.allocator, 8, .grayscale);
    defer atlas.deinit(t.allocator);
    var api: FakeApi = .{};
    var tex = try api.initAtlasTexture(&atlas);
    var version: usize = 0;
    _ = try sync(&api, &atlas, &tex, &version);
    const previous = version;
    try atlas.grow(t.allocator, 16);
    api.fail = true;
    try t.expectError(error.MetalFailed, sync(&api, &atlas, &tex, &version));
    try t.expectEqual(previous, version);
    try t.expectEqual(@as(usize, 8), tex.width);
    try t.expectEqual(@as(usize, 0), api.releases);
    api.fail = false;
    try t.expectEqual(@as(usize, 256), try sync(&api, &atlas, &tex, &version));
    try t.expectEqual(@as(usize, 1), api.releases);
    try t.expectEqual(atlas.modified.load(.monotonic), version);
}

test "atlas upload independent slots retain all changes with nonpacked source rows" {
    const t = std.testing;
    for ([_]Atlas.Format{ .grayscale, .bgra }) |format| {
        var atlas = try Atlas.init(t.allocator, 16, format);
        defer atlas.deinit(t.allocator);
        var api: FakeApi = .{};
        var slots = [_]FakeTexture{try api.initAtlasTexture(&atlas)} ** 3;
        var versions = [_]usize{0} ** 3;
        for (&slots, &versions) |*slot, *version| _ = try sync(&api, &atlas, slot, version);
        var partial_bytes: usize = 0;
        for (0..12) |i| {
            const reg: Atlas.Region = .{ .x = @intCast(1 + i % 5), .y = @intCast(1 + i % 7), .width = 2, .height = 2 };
            const bytes: [16]u8 = @splat(@intCast(i + 1));
            atlas.set(reg, bytes[0 .. 4 * format.depth()]);
            const index = i % slots.len;
            partial_bytes += try sync(&api, &atlas, &slots[index], &versions[index]);
            try t.expectEqualSlices(u8, atlas.data, slots[index].pixels[0..atlas.data.len]);
        }
        try t.expect(partial_bytes < 12 * atlas.data.len);
        std.debug.print("\nRESOURCE_METRIC atlas={s} full_bytes={d} partial_bytes={d}\n", .{ @tagName(format), 12 * atlas.data.len, partial_bytes });
        atlas.clear();
        for (&slots, &versions) |*slot, *version| {
            _ = try sync(&api, &atlas, slot, version);
            try t.expectEqualSlices(u8, atlas.data, slot.pixels[0..atlas.data.len]);
            try t.expectEqual(@as(usize, 0), try sync(&api, &atlas, slot, version));
        }
        for (0..300) |_| atlas.set(.{ .x = 1, .y = 1, .width = 1, .height = 1 }, &([_]u8{7} ** 4));
        try t.expectEqual(atlas.data.len, try sync(&api, &atlas, &slots[0], &versions[0]));
        try t.expectEqualSlices(u8, atlas.data, slots[0].pixels[0..atlas.data.len]);
    }
}
