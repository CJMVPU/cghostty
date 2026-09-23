//! Load the pinned default font from executable memory, independent of Resources.
const std = @import("std");
const font = @import("main.zig");

pub fn load(library: font.Library, options: font.face.Options) !font.Face {
    return font.Face.init(library, font.embedded.default_font, options);
}

test "bundled font uses pinned embedded Medium without filesystem resources" {
    var library = try font.Library.init(std.testing.allocator);
    defer library.deinit();
    var face = try load(library, .{ .size = .{ .points = 16 } });
    defer face.deinit();
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("LXGW WenKai Mono", try face.name(&buffer));
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(font.embedded.default_font, &hash, .{});
    try std.testing.expectEqualStrings("7a674f448b15a1b3df781c3498973d77f71d270788f7f921080c1344e9d739e1", &std.fmt.bytesToHex(hash, .lower));
}
