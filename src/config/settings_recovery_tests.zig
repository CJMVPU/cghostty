const std = @import("std");
const Config = @import("Config.zig");
const settings = @import("settings.zig");
const os = @import("../os/main.zig");

/// Real theme files exercise conditional finalization, rather than merely
/// replacing the validity decision with an injected boolean.
const Themes = struct {
    directory: os.TempDir,
    arena: std.heap.ArenaAllocator,
    valid: []const u8,
    invalid_dark: []const u8,

    fn init() !Themes {
        var directory = try os.TempDir.init();
        errdefer directory.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        const names = [_][]const u8{ "light", "dark", "broken-dark" };
        const contents = [_][]const u8{
            "background = #112233\n",
            "background = #445566\n",
            "background = invalid-color\n",
        };
        var paths: [names.len][]const u8 = undefined;
        for (names, contents, &paths) |name, content, *path| {
            var file = try directory.dir.createFile(std.testing.io, name, .{});
            defer file.close(std.testing.io);
            var buffer: [256]u8 = undefined;
            var writer = file.writer(std.testing.io, &buffer);
            try writer.interface.writeAll(content);
            try writer.end();
            var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const len = try directory.dir.realPathFile(std.testing.io, name, &path_buffer);
            path.* = try alloc.dupe(u8, path_buffer[0..len]);
        }
        const valid = try std.fmt.allocPrint(alloc, "light:{s},dark:{s}", .{ paths[0], paths[1] });
        const invalid_dark = try std.fmt.allocPrint(alloc, "light:{s},dark:{s}", .{ paths[0], paths[2] });
        return .{
            .directory = directory,
            .arena = arena,
            .valid = valid,
            .invalid_dark = invalid_dark,
        };
    }

    fn deinit(self: *Themes) void {
        self.directory.deinit();
        self.arena.deinit();
    }

    fn record(self: *Themes, current_theme: []const u8, previous_theme: []const u8) ![]const u8 {
        return std.json.Stringify.valueAlloc(self.arena.allocator(), .{
            .schema = 1,
            .current = .{ .values = .{ .title = "Current", .theme = current_theme } },
            .previous = .{ .values = .{ .title = "Previous", .theme = previous_theme } },
        }, .{});
    }
};

test "settings recovery validates dark current before selecting previous" {
    var themes = try Themes.init();
    defer themes.deinit();
    var config = try Config.default(std.testing.allocator);
    defer config.deinit();
    const record = try themes.record(themes.invalid_dark, themes.valid);
    try std.testing.expectEqual(settings.RecoverySource.previous, try settings.recoverySource(std.testing.allocator, record, "/tmp/settings.json"));
    try settings.loadRecord(&config, std.testing.allocator, record, "/tmp/settings.json");
    try config.finalize();
    try std.testing.expectEqualStrings("Previous", config.title.?);
    try std.testing.expectEqual(@as(usize, 1), config._diagnostics.items().len);
    var dark = (try config.changeConditionalState(.{ .theme = .dark })).?;
    defer dark.deinit();
    try std.testing.expectEqual(Config.Color{ .r = 0x44, .g = 0x55, .b = 0x66 }, dark.background);
    try std.testing.expectEqual(@as(usize, 1), dark._diagnostics.items().len);
    var light = (try dark.changeConditionalState(.{ .theme = .light })).?;
    defer light.deinit();
    try std.testing.expectEqual(@as(usize, 1), light._diagnostics.items().len);
}

test "settings recovery rejects invalid dark in both stored generations" {
    var themes = try Themes.init();
    defer themes.deinit();
    var config = try Config.default(std.testing.allocator);
    defer config.deinit();
    const record = try themes.record(themes.invalid_dark, themes.invalid_dark);
    try std.testing.expectEqual(settings.RecoverySource.defaults, try settings.recoverySource(std.testing.allocator, record, "/tmp/settings.json"));
    try settings.loadRecord(&config, std.testing.allocator, record, "/tmp/settings.json");
    try config.finalize();
    try std.testing.expectEqual(@as(?[:0]const u8, null), config.title);
    try std.testing.expect(config.theme == null);
    try std.testing.expect(!config._diagnostics.empty());
}

test "settings recovery keeps current when light and dark are valid" {
    var themes = try Themes.init();
    defer themes.deinit();
    var config = try Config.default(std.testing.allocator);
    defer config.deinit();
    const record = try themes.record(themes.valid, themes.invalid_dark);
    try std.testing.expectEqual(settings.RecoverySource.current, try settings.recoverySource(std.testing.allocator, record, "/tmp/settings.json"));
    try settings.loadRecord(&config, std.testing.allocator, record, "/tmp/settings.json");
    try config.finalize();
    try std.testing.expectEqualStrings("Current", config.title.?);
    try std.testing.expect(config._diagnostics.empty());
    try std.testing.expectEqual(Config.Color{ .r = 0x11, .g = 0x22, .b = 0x33 }, config.background);
}

test "settings recovery leaves selected input unfinalized for CLI overrides" {
    var themes = try Themes.init();
    defer themes.deinit();
    var config = try Config.default(std.testing.allocator);
    defer config.deinit();
    const record = try themes.record(themes.invalid_dark, themes.valid);
    try settings.loadRecord(&config, std.testing.allocator, record, "/tmp/settings.json");
    try std.testing.expectEqualStrings("Previous", config.title.?);
    try config.loadData(std.testing.allocator, "title = CLI\nbackground = #abcdef\n", "/tmp/cli.conf");
    try config.finalize();
    try std.testing.expectEqualStrings("CLI", config.title.?);
    try std.testing.expectEqual(Config.Color{ .r = 0xab, .g = 0xcd, .b = 0xef }, config.background);
    var dark = (try config.changeConditionalState(.{ .theme = .dark })).?;
    defer dark.deinit();
    try std.testing.expectEqual(Config.Color{ .r = 0xab, .g = 0xcd, .b = 0xef }, dark.background);
}
