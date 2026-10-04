//! XDG state directories used by the SSH terminfo cache.
//! (https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html)

const std = @import("std");
const Allocator = std.mem.Allocator;
const homedir = @import("homedir.zig");

pub const Options = struct {
    /// Subdirectories to join to the base. This avoids extra allocations
    /// when building up the directory. This is commonly the application.
    subdir: ?[]const u8 = null,

    /// The home directory for the user. If this is not set, we will attempt
    /// to look it up which is an expensive process. By setting this, you can
    /// avoid lookups.
    home: ?[]const u8 = null,
};

/// Get the XDG state directory. The returned value is allocated.
pub fn state(io: std.Io, alloc: Allocator, environ_map: *const std.process.Environ.Map, opts: Options) ![]u8 {
    return try dir(io, alloc, environ_map, opts, .{
        .env = "XDG_STATE_HOME",
        .default_subdir = ".local/state",
    });
}

const InternalOptions = struct {
    env: []const u8,
    default_subdir: []const u8,
};

/// Unified helper to get XDG directories that follow a common pattern.
fn dir(
    io: std.Io,
    alloc: Allocator,
    environ_map: *const std.process.Environ.Map,
    opts: Options,
    internal_opts: InternalOptions,
) ![]u8 {
    // If we have a cached home dir, use that.
    if (opts.home) |home| {
        return try std.fs.path.join(alloc, &[_][]const u8{
            home,
            internal_opts.default_subdir,
            opts.subdir orelse "",
        });
    }

    // First check the requested XDG environment variable.
    const env = environ_map.get(internal_opts.env) orelse "";

    if (env.len > 0) {
        // If we have a subdir, then we use the env as-is to avoid a copy.
        if (opts.subdir) |subdir| {
            return try std.fs.path.join(alloc, &[_][]const u8{
                env,
                subdir,
            });
        }

        return try alloc.dupe(u8, env);
    }

    // Get our home dir
    var buf: [1024]u8 = undefined;
    if (try homedir.home(io, environ_map, &buf)) |home| {
        return try std.fs.path.join(alloc, &[_][]const u8{
            home,
            internal_opts.default_subdir,
            opts.subdir orelse "",
        });
    }

    return error.NoHomeDir;
}

test "state directory environment paths" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    var environ_map: std.process.Environ.Map = .init(alloc);
    defer environ_map.deinit();

    try environ_map.put("XDG_STATE_HOME", "/tmp/cghostty-state");

    const base = try state(io, alloc, &environ_map, .{});
    defer alloc.free(base);
    try testing.expectEqualStrings("/tmp/cghostty-state", base);

    const nested = try state(io, alloc, &environ_map, .{ .subdir = "cghostty" });
    defer alloc.free(nested);
    try testing.expectEqualStrings("/tmp/cghostty-state/cghostty", nested);
}

test "state directory explicit home paths" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    const mock_home = "/Users/test";
    var environ_map: std.process.Environ.Map = .init(alloc);
    defer environ_map.deinit();

    // An explicit home keeps its existing precedence over the environment.
    try environ_map.put("XDG_STATE_HOME", "/tmp/cghostty-state");
    {
        const path = try state(io, alloc, &environ_map, .{ .home = mock_home });
        defer alloc.free(path);
        try testing.expectEqualStrings("/Users/test/.local/state", path);
    }
    {
        const path = try state(io, alloc, &environ_map, .{
            .home = mock_home,
            .subdir = "cghostty",
        });
        defer alloc.free(path);
        try testing.expectEqualStrings("/Users/test/.local/state/cghostty", path);
    }
}

test "state directory fallback when environment missing or empty" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    for ([_]bool{ false, true }) |empty| {
        var environ_map: std.process.Environ.Map = .init(alloc);
        defer environ_map.deinit();
        const temp_home = "/tmp/ghostty-test-home";
        try environ_map.put("HOME", temp_home);

        if (empty) {
            try environ_map.put("XDG_STATE_HOME", "");
        }

        const base = try state(io, alloc, &environ_map, .{});
        defer alloc.free(base);
        try std.testing.expectEqualStrings("/tmp/ghostty-test-home/.local/state", base);

        const nested = try state(io, alloc, &environ_map, .{ .subdir = "cghostty" });
        defer alloc.free(nested);
        try std.testing.expectEqualStrings("/tmp/ghostty-test-home/.local/state/cghostty", nested);
    }
}
