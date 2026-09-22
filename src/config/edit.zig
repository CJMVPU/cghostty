const std = @import("std");
const Allocator = std.mem.Allocator;
const file_load = @import("file_load.zig");
const global = @import("../global.zig");

const template = @import("template.zig");

/// Prepare the sole Application Support configuration only when explicitly edited.
pub fn openPath(alloc: Allocator) ![:0]const u8 {
    const path = try file_load.defaultPath(alloc);
    defer alloc.free(path);
    return try openPathAt(alloc, path);
}

/// Existing settings retain their exact byte order. The guide is appended once,
/// after a private backup; atomic replacement never exposes a partial template.
pub fn openPathAt(alloc: Allocator, path: []const u8) ![:0]const u8 {
    const io = global.io();
    if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
    const existing = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (existing) |file| file.close(io);
    const stat: ?std.Io.File.Stat = if (existing) |file| try file.stat(io) else null;
    if (stat) |info| if (info.kind != .file) return error.NotAFile;
    const original = if (existing != null) try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) else try alloc.dupe(u8, "");
    defer alloc.free(original);
    var lines = std.mem.splitScalar(u8, original, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trimEnd(u8, line, "\r"), template.marker)) return try alloc.dupeZ(u8, path);
    }

    // Resolve an existing symlink so editing preserves both the link and its target.
    var resolved: [std.fs.max_path_bytes]u8 = undefined;
    const target = if (existing != null)
        resolved[0..try std.Io.Dir.cwd().realPathFile(io, path, &resolved)]
    else
        path;
    const guide = try template.generate(alloc);
    defer alloc.free(guide);
    if (existing != null) {
        var name_buf: [@import("../os/file.zig").random_basename_len]u8 = undefined;
        const name = try @import("../os/file.zig").randomBasename(&name_buf);
        const backup = try std.fmt.allocPrint(alloc, "{s}.before-guide-{s}.bak", .{ target, name });
        defer alloc.free(backup);
        var copy = try std.Io.Dir.cwd().createFileAtomic(io, backup, .{ .permissions = .fromMode(0o600) });
        defer copy.deinit(io);
        var buf: [4096]u8 = undefined;
        var writer = copy.file.writer(io, &buf);
        try writer.interface.writeAll(original);
        try writer.end();
        try copy.link(io);
    }
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, target, .{
        .replace = existing != null,
        .permissions = if (stat) |info| info.permissions else .fromMode(0o600),
    });
    defer atomic.deinit(io);
    var buffer: [4096]u8 = undefined;
    var writer = atomic.file.writer(io, &buffer);
    if (original.len > 0) {
        try writer.interface.writeAll(original);
        try writer.interface.writeAll("\n\n");
    }
    try writer.interface.writeAll(guide);
    try writer.end();
    if (stat) |before| {
        // Refuse to overwrite edits made while preparing the guide.
        const current = try std.Io.Dir.openFileAbsolute(io, path, .{});
        defer current.close(io);
        const after = try current.stat(io);
        if (before.inode != after.inode or before.size != after.size or !std.meta.eql(before.mtime, after.mtime)) return error.ConfigurationChanged;
        try atomic.replace(io);
    } else try atomic.link(io);
    return try alloc.dupeZ(u8, path);
}

test "opening user configuration preserves contents and rejects directories" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var td = try @import("../os/main.zig").TempDir.init();
    defer td.deinit();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = buf[0..try td.dir.realPath(testing.io, &buf)];
    const path = try std.fs.path.join(alloc, &.{ base, "settings", "config.ghostty" });
    defer alloc.free(path);

    const created = try openPathAt(alloc, path);
    defer alloc.free(created);
    try testing.expectEqualStrings(path, created);
    const initial = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, alloc, .unlimited);
    defer alloc.free(initial);
    try testing.expect(std.mem.startsWith(u8, initial, template.marker));

    const contents = "# Keep my settings\nfont-size = 19\n";
    {
        var file = try std.Io.Dir.createFileAbsolute(testing.io, path, .{});
        defer file.close(testing.io);
        var buffer: [256]u8 = undefined;
        var writer = file.writer(testing.io, &buffer);
        try writer.interface.writeAll(contents);
        try writer.end();
    }
    const reopened = try openPathAt(alloc, path);
    defer alloc.free(reopened);
    const actual = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, alloc, .unlimited);
    defer alloc.free(actual);
    try testing.expect(std.mem.startsWith(u8, actual, contents));
    try testing.expect(std.mem.indexOf(u8, actual, template.marker) != null);
    const again = try openPathAt(alloc, path);
    defer alloc.free(again);
    const unchanged = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, alloc, .unlimited);
    defer alloc.free(unchanged);
    try testing.expectEqualStrings(actual, unchanged);
    var parent = try std.Io.Dir.cwd().openDir(testing.io, std.fs.path.dirname(path).?, .{ .iterate = true });
    defer parent.close(testing.io);
    var iter = parent.iterate();
    var backups: usize = 0;
    while (try iter.next(testing.io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".bak")) continue;
        const saved = try parent.readFileAlloc(testing.io, entry.name, alloc, .unlimited);
        defer alloc.free(saved);
        try testing.expectEqualStrings(contents, saved);
        backups += 1;
    }
    try testing.expectEqual(@as(usize, 1), backups);
    try testing.expectError(error.NotAFile, openPathAt(alloc, base));
}
