//! The default font is an application resource, not part of the executable.
const std = @import("std");
const builtin = @import("builtin");
const font = @import("main.zig");
const global = @import("../global.zig");

pub const relative_path = "fonts/LXGWWenKaiMono-Medium.ttf";

pub fn load(alloc: std.mem.Allocator, options: font.face.Options) !font.Face {
    // Core tests load the same pinned file via a build-supplied path. Release
    // code only uses the resolved app resources directory, never the checkout.
    if (comptime builtin.is_test) {
        return font.Face.initFile(@import("font_resources").wenkai, options);
    }
    const root = global.resourcesDir().app() orelse return error.MissingFontResources;
    const path = try std.fs.path.join(alloc, &.{ root, relative_path });
    defer alloc.free(path);
    return font.Face.initFile(path, options);
}

test "bundled font loads exact file and missing file fails" {
    var face = try load(std.testing.allocator, .{ .size = .{ .points = 16 } });
    defer face.deinit();
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("LXGW WenKai Mono", try face.name(&buffer));
    try std.testing.expectError(error.FontInitFailure, font.Face.initFile("/nonexistent-cghostty-font/LXGWWenKaiMono-Medium.ttf", .{ .size = .{ .points = 16 } }));
}
