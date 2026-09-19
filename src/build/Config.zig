//! Build configuration for the macOS-only cghostty application.
const Config = @This();
const std = @import("std");
const builtin = @import("builtin");
const ApprtRuntime = @import("../apprt/runtime.zig").Runtime;
const FontBackend = @import("../font/backend.zig").Backend;
const RendererBackend = @import("../renderer/backend.zig").Backend;
const TerminalBuildOptions = @import("../terminal/build_options.zig").Options;
const XCFrameworkTarget = @import("xcframework.zig").Target;

optimize: std.builtin.OptimizeMode,
target: std.Build.ResolvedTarget,
env: *const std.process.Environ.Map,
xcframework_target: XCFrameworkTarget = .native,
app_runtime: ApprtRuntime = .none,
renderer: RendererBackend = .metal,
font_backend: FontBackend = .coretext,
simd: bool = true,
i18n: bool = true,
exe_entrypoint: ExeEntrypoint = .ghostty,
version: std.SemanticVersion = .{ .major = 0, .minor = 1, .patch = 0 },
strip: bool = false,
emit_bench: bool = false,
emit_docs: bool = false,
emit_helpgen: bool = false,
emit_macos_app: bool = true,
emit_terminfo: bool = false,
emit_termcap: bool = false,
emit_test_exe: bool = false,
emit_themes: bool = true,
emit_xcframework: bool = true,
emit_unicode_table_gen: bool = false,

pub fn init(b: *std.Build, version: []const u8) !Config {
    const requested = b.standardTargetOptions(.{});
    if (builtin.os.tag != .macos or requested.result.os.tag != .macos) {
        std.log.err("cghostty must be built on and for macOS", .{});
        return error.UnsupportedTarget;
    }
    switch (requested.result.cpu.arch) {
        .aarch64 => {},
        else => {
            std.log.err("cghostty supports Apple Silicon (aarch64) only", .{});
            return error.UnsupportedArchitecture;
        },
    }
    const optimize = b.standardOptimizeOption(.{});
    var config: Config = .{
        .optimize = optimize,
        .target = genericMacOSTarget(b, requested.result.cpu.arch),
        .env = &b.graph.environ_map,
        .version = try std.SemanticVersion.parse(b.option([]const u8, "version-string", "cghostty semantic version") orelse version),
        .strip = b.option(bool, "strip", "Strip release symbols") orelse (optimize == .ReleaseFast or optimize == .ReleaseSmall),
        .xcframework_target = .native,
        .font_backend = b.option(FontBackend, "font-backend", "macOS font backend") orelse .coretext,
        .simd = b.option(bool, "simd", "Enable SIMD acceleration") orelse true,
        .i18n = b.option(bool, "i18n", "Build gettext translations") orelse true,
    };
    inline for (.{ "bench", "docs", "helpgen", "macos-app", "terminfo", "termcap", "test-exe", "themes", "xcframework", "unicode-table-gen" }) |name| {
        const field = comptime blk: {
            var result = ("emit_" ++ name).*;
            for (&result) |*c| {
                if (c.* == '-') c.* = '_';
            }
            break :blk result;
        };
        @field(config, &field) = b.option(bool, "emit-" ++ name, "Build/install " ++ name) orelse @field(config, &field);
    }
    for ([_][]const u8{ "freetype", "harfbuzz", "libpng", "zlib", "oniguruma", "glslang", "spirv-cross", "simdutf", "libintl" }) |dep| {
        _ = b.systemIntegrationOption(dep, .{ .default = false });
    }
    return config;
}

pub fn addOptions(self: *const Config, step: *std.Build.Step.Options) !void {
    step.addOption(bool, "simd", self.simd);
    step.addOption(bool, "i18n", self.i18n);
    step.addOption(ApprtRuntime, "app_runtime", self.app_runtime);
    step.addOption(FontBackend, "font_backend", self.font_backend);
    step.addOption(RendererBackend, "renderer", self.renderer);
    step.addOption(ExeEntrypoint, "exe_entrypoint", self.exe_entrypoint);
    step.addOption(std.SemanticVersion, "app_version", self.version);
    var buffer: [1024]u8 = undefined;
    step.addOption([:0]const u8, "app_version_string", try std.fmt.bufPrintZ(&buffer, "{f}", .{self.version}));
    step.addOption(ReleaseChannel, "release_channel", if (self.version.pre == null) .stable else .tip);
}

pub fn terminalOptions(self: *const Config, artifact: TerminalBuildOptions.Artifact, optimize: std.builtin.OptimizeMode) TerminalBuildOptions {
    return .{ .artifact = artifact, .simd = self.simd, .oniguruma = true, .c_abi = false, .features = .{}, .version = self.version, .slow_runtime_safety = optimize == .Debug };
}

pub fn baselineTarget(self: *const Config, io: std.Io) std.Build.ResolvedTarget {
    // Set our cpu model as baseline. There may need to be other modifications
    // we need to make such as resetting CPU features but for now this works.
    var q = self.target.query;
    q.cpu_model = .baseline;

    // Same logic as build.resolveTargetQuery but we don't need to
    // handle the native case.
    return .{
        .query = q,
        .result = std.zig.system.resolveTargetQuery(io, q) catch
            @panic("unable to resolve baseline query"),
    };
}

pub fn fromOptions() Config {
    const options = @import("build_options");
    return .{ .optimize = undefined, .target = undefined, .env = undefined, .version = options.app_version, .simd = options.simd, .font_backend = std.meta.stringToEnum(FontBackend, @tagName(options.font_backend)).?, .exe_entrypoint = std.meta.stringToEnum(ExeEntrypoint, @tagName(options.exe_entrypoint)).?, .i18n = options.i18n };
}
pub fn omitFramePointer(_: *const Config) bool {
    return false;
}
pub fn osVersionMin(_: std.Target.Os.Tag) ?std.Target.Query.OsVersion {
    return .{ .semver = .{ .major = 13, .minor = 0, .patch = 0 } };
}
pub fn genericMacOSTarget(
    b: *std.Build,
    arch: ?std.Target.Cpu.Arch,
) std.Build.ResolvedTarget {
    return b.resolveTargetQuery(.{
        .cpu_arch = arch orelse .aarch64,
        .os_tag = .macos,
        .os_version_min = osVersionMin(.macos),
    });
}

pub const ExeEntrypoint = enum { ghostty, helpgen, mdgen_ghostty_1, mdgen_ghostty_5 };
pub const ReleaseChannel = enum { tip, stable };
