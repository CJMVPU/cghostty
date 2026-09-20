const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const internal_os = @import("../os/main.zig");
const global = @import("../global.zig");

const log = std.log.scoped(.config);

/// Default path for the XDG home configuration file. Returned value
/// must be freed by the caller.
pub fn defaultXdgPath(alloc: Allocator) ![]const u8 {
    var environ_map = try global.environMap();
    defer environ_map.deinit();
    return try internal_os.xdg.config(
        global.io(),
        alloc,
        &environ_map,
        .{ .subdir = "cghostty/config.ghostty" },
    );
}

/// Ghostty <1.3.0 default path for the XDG home configuration file.
/// Returned value must be freed by the caller.
pub fn legacyDefaultXdgPath(alloc: Allocator) ![]const u8 {
    var environ_map = try global.environMap();
    defer environ_map.deinit();
    return try internal_os.xdg.config(
        global.io(),
        alloc,
        &environ_map,
        .{ .subdir = "cghostty/config" },
    );
}

/// Preferred default path for the XDG home configuration file.
/// Returned value must be freed by the caller.
pub fn preferredXdgPath(alloc: Allocator) ![]const u8 {
    return preferredPath(alloc, defaultXdgPath, legacyDefaultXdgPath);
}

/// Default path for the macOS Application Support configuration file.
/// Returned value must be freed by the caller.
pub fn defaultAppSupportPath(alloc: Allocator) ![]const u8 {
    return try internal_os.macos.appSupportDir(alloc, "config.ghostty");
}

/// Ghostty <1.3.0 default path for the macOS Application Support
/// configuration file. Returned value must be freed by the caller.
pub fn legacyDefaultAppSupportPath(alloc: Allocator) ![]const u8 {
    return try internal_os.macos.appSupportDir(alloc, "config");
}

/// Preferred default path for the macOS Application Support configuration file.
/// Returned value must be freed by the caller.
pub fn preferredAppSupportPath(alloc: Allocator) ![]const u8 {
    return preferredPath(alloc, defaultAppSupportPath, legacyDefaultAppSupportPath);
}

/// Resolve lazily so an existing modern config does not need a legacy path.
fn preferredPath(
    alloc: Allocator,
    comptime currentPath: fn (Allocator) anyerror![]const u8,
    comptime legacyPath: fn (Allocator) anyerror![]const u8,
) ![]const u8 {
    const current = try currentPath(alloc);
    errdefer alloc.free(current);
    if (isReadableConfig(global.io(), current)) return current;

    const legacy = try legacyPath(alloc);
    if (isReadableConfig(global.io(), legacy)) {
        alloc.free(current);
        return legacy;
    }
    alloc.free(legacy);
    return current;
}

fn isReadableConfig(io: std.Io, path: []const u8) bool {
    const file = open(io, path) catch return false;
    file.close(io);
    return true;
}

/// Returns the path to the preferred default configuration file.
/// This is the file where users should place their configuration.
///
/// This doesn't create or populate the file with any default
/// contents; downstream callers must handle this.
///
/// The returned value must be freed by the caller.
pub fn preferredDefaultFilePath(alloc: Allocator) ![]const u8 {
    // macOS prefers the Application Support directory
    // if it exists.
    const app_support_path = try preferredAppSupportPath(alloc);
    const app_support_file = open(global.io(), app_support_path) catch {
        // Try the XDG path if it exists
        const xdg_path = try preferredXdgPath(alloc);
        const xdg_file = open(global.io(), xdg_path) catch {
            // If neither file exists, use app support
            alloc.free(xdg_path);
            return app_support_path;
        };
        xdg_file.close(global.io());
        alloc.free(app_support_path);
        return xdg_path;
    };
    app_support_file.close(global.io());
    return app_support_path;
}

const OpenFileError = error{
    FileNotFound,
    FileIsEmpty,
    FileOpenFailed,
    NotAFile,
};

/// Opens the file at the given path and returns the file handle
/// if it exists and is non-empty. This also constrains the possible
/// errors to a smaller set that we can explicitly handle.
pub fn open(io: std.Io, path: []const u8) OpenFileError!std.Io.File {
    assert(std.fs.path.isAbsolute(path));

    var file = std.Io.Dir.openFileAbsolute(
        io,
        path,
        .{},
    ) catch |err| switch (err) {
        error.FileNotFound => return OpenFileError.FileNotFound,
        else => {
            log.warn("unexpected file open error path={s} err={}", .{
                path,
                err,
            });
            return OpenFileError.FileOpenFailed;
        },
    };
    errdefer file.close(io);

    const stat = file.stat(io) catch |err| {
        log.warn("error getting file stat path={s} err={}", .{
            path,
            err,
        });
        return OpenFileError.FileOpenFailed;
    };
    switch (stat.kind) {
        .file => {},
        else => return OpenFileError.NotAFile,
    }

    if (stat.size == 0) return OpenFileError.FileIsEmpty;

    return file;
}
