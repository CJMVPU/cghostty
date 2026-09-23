const std = @import("std");
const args = @import("args.zig");
const Action = @import("ghostty.zig").Action;
const Config = @import("../config/Config.zig");
const configpkg = @import("../config.zig");
const themepkg = @import("../config/theme.zig");
const global = @import("../global.zig");

const ColorScheme = enum { all, dark, light };

pub const Options = struct {
    /// If true, print the full path to the theme.
    path: bool = false,

    /// Accepted for compatibility; output is always plain.
    plain: bool = false,

    /// Specifies the color scheme of the themes to include in the list.
    color: ColorScheme = .all,

    pub fn deinit(self: Options) void {
        _ = self;
    }

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

const ThemeListElement = struct {
    location: themepkg.Location,
    path: []const u8,
    theme: []const u8,

    fn lessThan(_: void, lhs: @This(), rhs: @This()) bool {
        // TODO: use Unicode-aware comparison
        return std.ascii.orderIgnoreCase(lhs.theme, rhs.theme) == .lt;
    }
};

/// List installed and user themes as text. `--path` includes file paths;
/// `--color=dark|light|all` filters by background. `--plain` remains accepted
/// for existing scripts; output is always plain and never edits configuration.
pub fn run(gpa_alloc: std.mem.Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try args.argsIterator(gpa_alloc, global.args());
        defer iter.deinit();
        try args.parse(Options, gpa_alloc, &opts, &iter);
    }

    var arena = std.heap.ArenaAllocator.init(gpa_alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_file: std.Io.File = .stdout();
    var stdout_writer = stdout_file.writer(global.io(), &stdout_buf);
    const stdout = &stdout_writer.interface;

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(global.io(), &stderr_buf);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    const resources_dir = global.resourcesDir().app();
    if (resources_dir == null)
        try stderr.print("Could not find the Ghostty resources directory. Please ensure " ++
            "that Ghostty is installed correctly.\n", .{});

    var count: usize = 0;

    var themes: std.ArrayList(ThemeListElement) = .empty;

    var it: themepkg.LocationIterator = .{ .arena_alloc = arena.allocator() };

    while (try it.next()) |loc| {
        var dir = std.Io.Dir.cwd().openDir(
            global.io(),
            loc.dir,
            .{ .iterate = true },
        ) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => {
                std.debug.print("error trying to open {s}: {}\n", .{ loc.dir, err });
                continue;
            },
        };
        defer dir.close(global.io());

        var walker = dir.iterate();

        while (try walker.next(global.io())) |entry| {
            switch (entry.kind) {
                .file, .sym_link => {
                    if (std.mem.eql(u8, entry.name, ".DS_Store"))
                        continue;
                    count += 1;

                    const path = try std.fs.path.join(alloc, &.{ loc.dir, entry.name });
                    try themes.append(alloc, .{
                        .path = path,
                        .location = loc.location,
                        .theme = try alloc.dupe(u8, entry.name),
                    });
                },
                else => {},
            }
        }
    }

    if (count == 0) {
        try stderr.print("No themes found, check to make sure that the themes were installed correctly.", .{});
        return 1;
    }

    std.mem.sortUnstable(ThemeListElement, themes.items, {}, ThemeListElement.lessThan);

    for (themes.items) |theme| {
        if (!try matchesThemeFile(gpa_alloc, opts.color, theme.path)) {
            continue;
        }
        if (opts.path)
            try stdout.print("{s} ({t}) {s}\n", .{ theme.theme, theme.location, theme.path })
        else
            try stdout.print("{s} ({t})\n", .{ theme.theme, theme.location });
    }

    // Don't forget to flush!
    try stdout.flush();
    return 0;
}

fn matchesThemeFile(alloc: std.mem.Allocator, filter: ColorScheme, path: []const u8) !bool {
    if (filter == .all) return true;
    var config = try Config.default(alloc);
    defer config.deinit();
    try config.loadFile(config._arena.?.allocator(), path);
    return shouldIncludeTheme(filter, config);
}

fn shouldIncludeTheme(theme_filter: ColorScheme, theme_config: Config) bool {
    const rf = @as(f32, @floatFromInt(theme_config.background.r)) / 255.0;
    const gf = @as(f32, @floatFromInt(theme_config.background.g)) / 255.0;
    const bf = @as(f32, @floatFromInt(theme_config.background.b)) / 255.0;
    const luminance = 0.2126 * rf + 0.7152 * gf + 0.0722 * bf;
    const is_dark = luminance < 0.5;
    return (theme_filter == .all) or (theme_filter == .dark and is_dark) or (theme_filter == .light and !is_dark);
}

test "theme filtering starts each file from defaults" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "light", .data = "background = #ffffff\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "default", .data = "foreground = #ffffff\n" });
    const light = try tmp.dir.realPathFileAlloc(testing.io, "light", alloc);
    defer alloc.free(light);
    const default = try tmp.dir.realPathFileAlloc(testing.io, "default", alloc);
    defer alloc.free(default);
    try testing.expect(try matchesThemeFile(alloc, .light, light));
    try testing.expect(!try matchesThemeFile(alloc, .light, default));
    try testing.expect(try matchesThemeFile(alloc, .dark, default));
    try testing.expect(!try matchesThemeFile(alloc, .dark, light));
}
