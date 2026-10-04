const std = @import("std");
const Allocator = std.mem.Allocator;
const internal_os = @import("../os/main.zig");
const cli = @import("../cli.zig");
const global = @import("../global.zig");

/// Location of possible themes. The order of this enum matters because it
/// defines the priority of theme search (from top to bottom).
pub const Location = enum {
    user, // Application Support config directory
    resources, // Ghostty resources dir

    /// Returns the directory for the given theme based on this location type.
    ///
    /// This will return null with no error if the directory type doesn't exist
    /// or is invalid for any reason. For example, it is perfectly valid to
    /// install and run Ghostty without the resources directory.
    ///
    /// Due to the way allocations are handled, an Arena allocator (or another
    /// similar allocator implementation) should be used. It may not be safe to
    /// free the returned allocations.
    pub fn dir(
        self: Location,
        arena_alloc: Allocator,
    ) error{ OutOfMemory, Unexpected }!?[]const u8 {
        return switch (self) {
            .user => internal_os.macos.appSupportDir(arena_alloc, "themes") catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.AppleAPIFailed => return null,
            },

            .resources => try std.fs.path.join(arena_alloc, &.{
                global.resourcesDir().app() orelse return null,
                "themes",
            }),
        };
    }
};

/// An iterator that returns all possible directories for finding themes in
/// order of priority.
pub const LocationIterator = struct {
    /// Due to the way allocations are handled, an Arena allocator (or another
    /// similar allocator implementation) should be used. It may not be safe to
    /// free the returned allocations.
    arena_alloc: Allocator,
    i: usize = 0,

    pub fn next(self: *LocationIterator) !?struct {
        location: Location,
        dir: []const u8,
    } {
        const max = @typeInfo(Location).@"enum".fields.len;
        while (self.i < max) {
            const location: Location = @enumFromInt(self.i);
            self.i += 1;
            if (try location.dir(self.arena_alloc)) |dir|
                return .{
                    .location = location,
                    .dir = dir,
                };
        }
        return null;
    }

    pub fn reset(self: *LocationIterator) void {
        self.i = 0;
    }
};

const OpenedTheme = struct {
    path: []const u8,
    file: std.Io.File,
};

/// Open the given named theme. If there are any errors then messages
/// will be appended to the given error list and null is returned. If
/// a non-null return value is returned, there are never any errors added.
///
/// One error that is not recoverable and may be returned is OOM. This is
/// always a critical error for configuration loading so it is returned.
///
/// Due to the way allocations are handled, an Arena allocator (or another
/// similar allocator implementation) should be used. It may not be safe to
/// free the returned allocations.
///
/// This will never return anything other than a handle to a regular file. If
/// the theme resolves to something other than a regular file a diagnostic entry
/// will be added to the list and null will be returned.
pub fn open(
    arena_alloc: Allocator,
    theme: []const u8,
    diags: *cli.DiagnosticList,
) error{ OutOfMemory, Unexpected }!?OpenedTheme {
    // Absolute themes are loaded a different path.
    if (std.fs.path.isAbsolute(theme)) {
        const file: std.Io.File = try openAbsolute(
            arena_alloc,
            theme,
            diags,
        ) orelse return null;
        return validateOpenedFile(arena_alloc, theme, theme, diags, file, file.stat(global.io()));
    }

    const basename = std.fs.path.basename(theme);
    if (!std.mem.eql(u8, theme, basename)) {
        try diags.append(arena_alloc, .{
            .message = try std.fmt.allocPrintSentinel(
                arena_alloc,
                "theme \"{s}\" cannot include path separators unless it is an absolute path",
                .{theme},
                0,
            ),
        });
        return null;
    }

    // Iterate over the possible locations to try to find the
    // one that exists.
    var it: LocationIterator = .{ .arena_alloc = arena_alloc };
    const cwd = std.Io.Dir.cwd();
    while (try it.next()) |loc| {
        const path = try std.fs.path.join(arena_alloc, &.{ loc.dir, theme });
        if (cwd.openFile(global.io(), path, .{})) |file| {
            return validateOpenedFile(arena_alloc, theme, path, diags, file, file.stat(global.io()));
        } else |err| switch (err) {
            // Not an error, just continue to the next location.
            error.FileNotFound => {},

            // Anything else is an error we log and give up on.
            else => {
                try diags.append(arena_alloc, .{
                    .message = try std.fmt.allocPrintSentinel(
                        arena_alloc,
                        "failed to load theme \"{s}\" from the file \"{s}\": {}",
                        .{ theme, path, err },
                        0,
                    ),
                });

                return null;
            },
        }
    }

    // Unlikely scenario: the theme doesn't exist. In this case, we reset
    // our iterator, reiterate over in order to build a better error message.
    // This does double allocate some memory but for errors I think that's
    // fine.
    it.reset();
    while (try it.next()) |loc| {
        const path = try std.fs.path.join(arena_alloc, &.{ loc.dir, theme });
        try diags.append(arena_alloc, .{
            .message = try std.fmt.allocPrintSentinel(
                arena_alloc,
                "theme \"{s}\" not found, tried path \"{s}\"",
                .{ theme, path },
                0,
            ),
        });
    }

    return null;
}

// This helper owns the descriptor until it returns a validated theme. Every
// failed validation, including failure to allocate its diagnostic, closes it.
fn validateOpenedFile(
    arena_alloc: Allocator,
    theme: []const u8,
    path: []const u8,
    diags: *cli.DiagnosticList,
    file: std.Io.File,
    stat_result: std.Io.File.StatError!std.Io.File.Stat,
) error{OutOfMemory}!?OpenedTheme {
    var transferred = false;
    defer if (!transferred) file.close(global.io());

    const stat = stat_result catch |err| {
        try diags.append(arena_alloc, .{
            .message = try std.fmt.allocPrintSentinel(
                arena_alloc,
                "not reading theme from \"{s}\": {}",
                .{ theme, err },
                0,
            ),
        });
        return null;
    };
    switch (stat.kind) {
        .file => {},
        else => {
            try diags.append(arena_alloc, .{
                .message = try std.fmt.allocPrintSentinel(
                    arena_alloc,
                    "not reading theme from \"{s}\": it is a {s}",
                    .{ theme, @tagName(stat.kind) },
                    0,
                ),
            });
            return null;
        },
    }
    transferred = true;
    return .{ .path = path, .file = file };
}

/// Open the given theme from an absolute path. If there are any errors
/// then messages will be appended to the given error list and null is
/// returned. If a non-null return value is returned, there are never any
/// errors added.
///
/// Due to the way allocations are handled, an Arena allocator (or another
/// similar allocator implementation) should be used. It may not be safe to
/// free the returned allocations.
pub fn openAbsolute(
    arena_alloc: Allocator,
    theme: []const u8,
    diags: *cli.DiagnosticList,
) error{OutOfMemory}!?std.Io.File {
    return std.Io.Dir.openFileAbsolute(global.io(), theme, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => try diags.append(arena_alloc, .{
                .message = try std.fmt.allocPrintSentinel(
                    arena_alloc,
                    "failed to load theme from the path \"{s}\"",
                    .{theme},
                    0,
                ),
            }),
            else => try diags.append(arena_alloc, .{
                .message = try std.fmt.allocPrintSentinel(
                    arena_alloc,
                    "failed to load theme from the path \"{s}\": {}",
                    .{ theme, err },
                    0,
                ),
            }),
        }

        return null;
    };
}

fn testDescriptorOpen(file: std.Io.File) bool {
    return std.c.fcntl(file.handle, std.c.F.GETFD) != -1;
}

fn testRejectDirectory(symlink: bool) !void {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(testing.io, "directory", .default_dir);
    if (symlink) try tmp.dir.symLink(testing.io, "directory", "symlink", .{});

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buffer[0..try tmp.dir.realPath(testing.io, &path_buffer)];
    const path = try std.fs.path.join(alloc, &.{ root, if (symlink) "symlink" else "directory" });
    const file = try std.Io.Dir.openFileAbsolute(testing.io, path, .{});
    // The old implementation leaks this descriptor. Reclaim it even when
    // the regression assertion fails so the test cannot affect later tests.
    defer if (testDescriptorOpen(file)) file.close(testing.io);
    var diags: cli.DiagnosticList = .{};
    try testing.expect(try validateOpenedFile(alloc, path, path, &diags, file, file.stat(testing.io)) == null);
    try testing.expectEqual(@as(usize, 1), diags.items().len);
    try testing.expect(!testDescriptorOpen(file));
}

test "theme file ownership rejects directories" {
    try testRejectDirectory(false);
}

test "theme file ownership rejects symlink directories" {
    try testRejectDirectory(true);
}

test "theme file ownership closes on stat failure" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "theme", .data = "background = #112233\n" });
    const file = try tmp.dir.openFile(testing.io, "theme", .{});
    defer if (testDescriptorOpen(file)) file.close(testing.io);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diags: cli.DiagnosticList = .{};
    try testing.expect(try validateOpenedFile(arena.allocator(), "theme", "theme", &diags, file, error.PermissionDenied) == null);
    try testing.expectEqual(@as(usize, 1), diags.items().len);
    try testing.expect(!testDescriptorOpen(file));
}

test "theme file ownership closes on diagnostic allocation failure" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(testing.io, "directory", .default_dir);
    const file = try tmp.dir.openFile(testing.io, "directory", .{});
    defer if (testDescriptorOpen(file)) file.close(testing.io);
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var diags: cli.DiagnosticList = .{};
    try testing.expectError(error.OutOfMemory, validateOpenedFile(failing.allocator(), "directory", "directory", &diags, file, file.stat(testing.io)));
    try testing.expect(failing.has_induced_failure);
    try testing.expect(!testDescriptorOpen(file));
}

test "theme file ownership transfers regular files to the caller" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "theme", .data = "background = #112233\n" });
    const file = try tmp.dir.openFile(testing.io, "theme", .{});
    defer if (testDescriptorOpen(file)) file.close(testing.io);
    var diags: cli.DiagnosticList = .{};
    const result = (try validateOpenedFile(testing.allocator, "theme", "theme", &diags, file, file.stat(testing.io))).?;
    try testing.expectEqual(file.handle, result.file.handle);
    try testing.expect(testDescriptorOpen(result.file));
    try testing.expectEqualStrings("theme", result.path);
    try testing.expect(diags.empty());
    result.file.close(testing.io);
    try testing.expect(!testDescriptorOpen(file));
}
