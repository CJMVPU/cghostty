//! Build configuration for the macOS-only cghostty application.
const Config = @This();
const std = @import("std");
const builtin = @import("builtin");
const TerminalBuildOptions = @import("../terminal/build_options.zig").Options;

optimize: std.builtin.OptimizeMode,
target: std.Build.ResolvedTarget,
env: *const std.process.Environ.Map,
simd: bool = true,
exe_entrypoint: ExeEntrypoint = .ghostty,
version: std.SemanticVersion,
strip: bool = false,
emit_bench: bool = false,
emit_docs: bool = false,
emit_helpgen: bool = false,
emit_macos_app: bool = true,
emit_terminfo: bool = false,
emit_termcap: bool = false,
emit_test_exe: bool = false,
emit_themes: bool = true,
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
        .target = macOSTarget(b),
        .env = &b.graph.environ_map,
        .version = try std.SemanticVersion.parse(b.option([]const u8, "version-string", "cghostty semantic version") orelse version),
        .strip = b.option(bool, "strip", "Strip release symbols") orelse (optimize == .ReleaseFast or optimize == .ReleaseSmall),
        .simd = b.option(bool, "simd", "Enable SIMD acceleration") orelse true,
    };
    inline for (.{ "bench", "docs", "helpgen", "macos-app", "terminfo", "termcap", "test-exe", "themes", "unicode-table-gen" }) |name| {
        const field = comptime blk: {
            var result = ("emit_" ++ name).*;
            for (&result) |*c| {
                if (c.* == '-') c.* = '_';
            }
            break :blk result;
        };
        @field(config, &field) = b.option(bool, "emit-" ++ name, "Build/install " ++ name) orelse @field(config, &field);
    }
    for ([_][]const u8{"simdutf"}) |dep| {
        _ = b.systemIntegrationOption(dep, .{ .default = false });
    }
    return config;
}

pub fn addOptions(self: *const Config, step: *std.Build.Step.Options) !void {
    step.addOption(bool, "simd", self.simd);
    step.addOption(ExeEntrypoint, "exe_entrypoint", self.exe_entrypoint);
    step.addOption(std.SemanticVersion, "app_version", self.version);
    var buffer: [1024]u8 = undefined;
    step.addOption([:0]const u8, "app_version_string", try std.fmt.bufPrintZ(&buffer, "{f}", .{self.version}));
    step.addOption(ReleaseChannel, "release_channel", if (self.version.pre == null) .stable else .tip);
}

pub fn terminalOptions(self: *const Config, artifact: TerminalBuildOptions.Artifact, optimize: std.builtin.OptimizeMode) TerminalBuildOptions {
    return .{ .artifact = artifact, .simd = self.simd, .c_abi = false, .features = .{}, .version = self.version, .slow_runtime_safety = optimize == .Debug };
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
    return .{ .optimize = undefined, .target = undefined, .env = undefined, .version = options.app_version, .simd = options.simd, .exe_entrypoint = std.meta.stringToEnum(ExeEntrypoint, @tagName(options.exe_entrypoint)).? };
}
fn macOSTarget(b: *std.Build) std.Build.ResolvedTarget {
    return b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
        .os_version_min = .{ .semver = .{ .major = 27, .minor = 0, .patch = 0 } },
    });
}

pub const ExeEntrypoint = enum { ghostty, helpgen, mdgen_ghostty_1, mdgen_ghostty_5 };
pub const ReleaseChannel = enum { tip, stable };
