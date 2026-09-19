const std = @import("std");
const buildpkg = @import("src/build/main.zig");
const translate_c = @import("translate_c");
const zon = @import("build.zig.zon");

comptime {
    buildpkg.requireZig(zon.minimum_zig_version);
}

pub fn build(b: *std.Build) !void {
    const config = try buildpkg.Config.init(b, zon.version);
    const filters = b.option([][]const u8, "test-filter", "Filter Zig unit tests") orelse &.{};
    const deps = try buildpkg.SharedDeps.init(b, &config);
    const resources = try buildpkg.GhosttyResources.init(b, &config, &deps);
    const docs = try buildpkg.GhosttyDocs.init(b, &deps);
    if (config.emit_docs) docs.install() else docs.installDummy(b.getInstallStep());
    const i18n = if (config.i18n) try buildpkg.GhosttyI18n.init(b, &config) else null;

    if (config.emit_xcframework or config.emit_macos_app) {
        const framework = try buildpkg.GhosttyXCFramework.init(b, &deps, config.xcframework_target);
        framework.install();
        resources.install();
        if (i18n) |v| v.install();
        // The checked-in Nushell wrapper is the sole app build entry point.
        if (config.emit_macos_app) {
            const app = b.addSystemCommand(&.{ "nu", "macos/build.nu", "--skip-core", "--version", b.fmt("{f}", .{config.version}), "--configuration", if (config.optimize == .Debug) "Debug" else "ReleaseLocal" });
            framework.addStepDependencies(&app.step);
            resources.addStepDependencies(&app.step);
            docs.installDummy(&app.step);
            if (i18n) |v| v.addStepDependencies(&app.step);
            b.getInstallStep().dependOn(&app.step);
        }
    }
    if (config.emit_bench) {
        const bench = try buildpkg.GhosttyBench.init(b, &deps);
        bench.install();
    }
    if (config.emit_helpgen) deps.help_strings.install();

    const tests = b.addTest(.{
        .name = "cghostty-test",
        .filters = filters,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = config.baselineTarget(b.graph.io),
            .optimize = .Debug,
            .strip = false,
            .omit_frame_pointer = false,
            .unwind_tables = .sync,
        }),
        .use_llvm = true,
    });
    _ = try deps.add(tests);
    try translate_c.addImportToModule(b, "ghostty.h", tests.root_module, .{
        .source = .{ .includes = .{ .files = &.{.{ .path = "ghostty.h" }} } },
        .target = config.baselineTarget(b.graph.io),
        .optimize = .Debug,
        .system_include_paths = &.{b.path("include")},
    });
    const test_step = b.step("test", "Run macOS core Zig tests");
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
    b.step("test-build", "Compile macOS core tests without running").dependOn(&tests.step);
    if (config.emit_test_exe) b.installArtifact(tests);
    if (i18n) |v| b.step("update-translations", "Update shared-core translations").dependOn(v.update_step);
}
