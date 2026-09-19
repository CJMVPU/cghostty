//! Combine the application core and its dependencies into one arm64 archive.
const std = @import("std");
const LibtoolStep = @import("LibtoolStep.zig");
pub fn create(b: *std.Build, _: std.Build.ResolvedTarget, name: []const u8, sources: []const std.Build.LazyPath) struct { step: *std.Build.Step, output: std.Build.LazyPath } {
    const libtool = LibtoolStep.create(b, .{ .name = name, .out_name = b.fmt("lib{s}-combined.a", .{name}), .sources = @constCast(sources) });
    return .{ .step = libtool.step, .output = libtool.output };
}
