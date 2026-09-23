const std = @import("std");
const build_options = @import("build_options");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");
const xev = @import("../global.zig").xev;
const renderer = @import("../renderer.zig");
const global = @import("../global.zig");

pub const Options = struct {};

/// The `version` command is used to display information about Ghostty. Recognized as
/// either `+version` or `--version`.
pub fn run(_: Allocator) !u8 {
    var buffer: [1024]u8 = undefined;
    const stdout_file: std.Io.File = .stdout();
    var stdout_writer = stdout_file.writer(global.io(), &buffer);

    var environ_map = try global.environMap();
    defer environ_map.deinit();

    const stdout = &stdout_writer.interface;
    const tty = try stdout_file.isTty(global.io());

    if (tty) if (build_config.version.build) |commit_hash| {
        try stdout.print(
            "\x1b]8;;https://github.com/CJMVPU/cghostty/commit/{s}\x1b\\",
            .{commit_hash},
        );
    };
    try stdout.print("cghostty {s}\n\n", .{build_config.version_string});
    if (tty) try stdout.print("\x1b]8;;\x1b\\", .{});

    try stdout.print("Version\n", .{});
    try stdout.print("  - version: {s}\n", .{build_config.version_string});
    try stdout.print("  - channel: {t}\n", .{build_config.release_channel});

    try stdout.print("Build Config\n", .{});
    try stdout.print("  - Zig version   : {s}\n", .{builtin.zig_version_string});
    try stdout.print("  - build mode    : {}\n", .{builtin.mode});
    try stdout.print("  - app runtime   : {s}\n", .{if (build_config.artifact == .lib) "embedded" else "cli"});
    try stdout.writeAll("  - font engine   : CoreText\n");
    try stdout.print("  - renderer      : {}\n", .{renderer.Renderer});
    try stdout.print("  - libxev        : {t}\n", .{xev.backend});

    // Don't forget to flush!
    try stdout.flush();
    return 0;
}
