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
    // Reflection uses the same lightweight configuration as help generation;
    // this program does not initialize or link the terminal runtime.
    const config_gen = b.addExecutable(.{
        .name = "configgen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/configgen.zig"),
            .target = b.graph.host,
        }),
    });
    var generator_config = config;
    generator_config.exe_entrypoint = .helpgen;
    const generator_options = b.addOptions();
    try generator_config.addOptions(generator_options);
    config_gen.root_module.addOptions("build_options", generator_options);
    const generated_config = b.addRunArtifact(config_gen).captureStdOut(.{});
    const config_destination = "macos/Sources/Ghostty/Ghostty.ConfigSchema.swift";
    const check_config = b.addSystemCommand(&.{"python3"});
    check_config.addFileArg(b.path("scripts/config-bridge-output.py"));
    check_config.addFileArg(generated_config);
    check_config.addFileArg(b.path(config_destination));
    b.step("check-config-bridge", "Verify native config bridge matches Zig schema").dependOn(&check_config.step);
    b.getInstallStep().dependOn(&check_config.step);
    const update_config = b.addSystemCommand(&.{"python3"});
    update_config.addFileArg(b.path("scripts/config-bridge-output.py"));
    update_config.addFileArg(generated_config);
    update_config.addArg(b.pathFromRoot(config_destination));
    update_config.addArg("--update");
    b.step("update-config-bridge", "Regenerate native typed config bridge").dependOn(&update_config.step);
    const resources = try buildpkg.GhosttyResources.init(b, &config, &deps);
    const docs = try buildpkg.GhosttyDocs.init(b, &deps);
    if (config.emit_docs) docs.install() else docs.installDummy(b.getInstallStep());
    const i18n = if (config.i18n) try buildpkg.GhosttyI18n.init(b) else null;

    {
        const core = try buildpkg.GhosttyLib.initStatic(b, &deps);
        const install_core = b.addInstallFileWithDir(core.output, .lib, "libghostty-internal.a");
        b.getInstallStep().dependOn(&install_core.step);
        const record_core = b.addSystemCommand(&.{ "python3", "scripts/core-build-record.py", "record", "--archive", b.getInstallPath(.lib, "libghostty-internal.a"), "--optimize", @tagName(config.optimize), "--version", b.fmt("{f}", .{config.version}) });
        record_core.has_side_effects = true;
        record_core.step.dependOn(&install_core.step);
        b.getInstallStep().dependOn(&record_core.step);
        resources.install();
        if (i18n) |v| v.install();
        // The checked-in Nushell wrapper is the sole app build entry point.
        if (config.emit_macos_app) {
            const app = b.addSystemCommand(&.{ "nu", "macos/build.nu", "--skip-core", "--version", b.fmt("{f}", .{config.version}), "--configuration", if (config.optimize == .Debug) "Debug" else "ReleaseLocal" });
            app.step.dependOn(&record_core.step);
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
    tests.step.dependOn(&check_config.step);
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
    b.step("test-build", "Compile macOS core tests without running").dependOn(&tests.step);
    if (config.emit_test_exe) b.installArtifact(tests);
    if (i18n) |v| b.step("update-translations", "Update shared-core translations").dependOn(v.update_step);
}
