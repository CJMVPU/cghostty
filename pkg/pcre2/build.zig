const std = @import("std");
const translate_c = @import("translate_c");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("pcre2", .{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Use upstream's build; compile only the UTF-8 library, without JIT.
    const upstream = b.lazyDependency("pcre2", .{
        .target = target,
        .optimize = optimize,
        .linkage = .static,
        .@"code-unit-width" = .@"8",
        .support_jit = false,
    }) orelse return;
    const lib = upstream.artifact("pcre2-8");
    try @import("apple_sdk").addPaths(b, lib);
    b.installArtifact(lib);

    try translate_c.addImportToModule(b, "pcre2_c", module, .{
        .source = .{ .includes = .{ .files = &.{.{ .path = "pcre2.h" }} } },
        .target = target,
        .optimize = optimize,
        .extra_args = &.{"-DPCRE2_CODE_UNIT_WIDTH=8"},
        .link_libs = &.{lib},
    });

    const tests = b.addTest(.{ .root_module = module });
    b.step("test", "Test bounded UTF-8 matching").dependOn(&b.addRunArtifact(tests).step);
}
