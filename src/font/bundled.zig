//! Load the pinned default font from executable memory, independent of Resources.
const std = @import("std");
const font = @import("main.zig");

pub fn load(options: font.face.Options) !font.Face {
    return font.Face.init(font.embedded.default_font, options);
}

test "bundled font uses pinned embedded Medium without filesystem resources" {
    var face = try load(.{ .size = .{ .points = 16 } });
    defer face.deinit();
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("LXGW WenKai Mono", try face.name(&buffer));
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(font.embedded.default_font, &hash, .{});
    try std.testing.expectEqualStrings("7a674f448b15a1b3df781c3498973d77f71d270788f7f921080c1344e9d739e1", &std.fmt.bytesToHex(hash, .lower));
}

test "font name belongs to caller buffer and survives face release" {
    const testing = std.testing;
    var buffer: [256]u8 = undefined;
    const name = name: {
        var face = try load(.{ .size = .{ .points = 16 } });
        defer face.deinit();
        var short: [1]u8 = undefined;
        try testing.expectError(error.OutOfMemory, face.name(&short));
        const name = try face.name(&buffer);
        try testing.expect(name.ptr == &buffer);
        break :name name;
    };
    try testing.expectEqualStrings("LXGW WenKai Mono", name);
}
