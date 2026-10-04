const std = @import("std");
const Allocator = std.mem.Allocator;
const args = @import("args.zig");
const Action = @import("ghostty.zig").Action;
const Config = @import("../config.zig").Config;
const global = @import("../global.zig");

pub const Options = struct {
    /// The path of the config file to validate. If this isn't specified,
    /// then the default config file paths will be validated.
    @"config-file": ?[:0]const u8 = null,

    pub fn deinit(self: Options) void {
        _ = self;
    }

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `validate-config` command is used to validate a Ghostty config file.
///
/// When executed without any arguments, this will load the config from the default
/// location.
///
/// Flags:
///
///   * `--config-file`: can be passed to validate a specific target config file in
///     a non-default location
pub fn run(alloc: std.mem.Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try args.argsIterator(alloc, global.args());
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }

    var buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(global.io(), &buffer);
    const stdout = &stdout_writer.interface;
    const result = runInner(alloc, opts, stdout);
    try stdout_writer.end();
    return result;
}

fn runInner(
    alloc: std.mem.Allocator,
    opts: Options,
    stdout: *std.Io.Writer,
) !u8 {
    var cfg = try loadForValidation(alloc, opts, Config.load);
    defer cfg.deinit();

    if (cfg._diagnostics.items().len > 0) {
        for (cfg._diagnostics.items()) |diag| {
            try stdout.print("{f}\n", .{diag});
        }
        return 1;
    }

    return 0;
}

// Keep loading separate from reporting so tests never read personal settings.
fn loadForValidation(
    alloc: Allocator,
    opts: Options,
    comptime load_default: anytype,
) !Config {
    // The normal loader already finalizes its result. Finalization removes the
    // built-in URL rule when disabled, so applying it twice changes user links.
    const config_path = opts.@"config-file" orelse return load_default(alloc);

    var cfg = try Config.default(alloc);
    errdefer cfg.deinit();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_path = buf[0..try std.Io.Dir.cwd().realPathFile(
        global.io(),
        config_path,
        &buf,
    )];
    try cfg.loadFile(alloc, abs_path);
    try cfg.loadRecursiveFiles(alloc);
    try cfg.finalize();

    return cfg;
}

const TestDefaultLoader = struct {
    fn withLinks(alloc: Allocator, custom: bool) !Config {
        var cfg = try Config.default(alloc);
        errdefer cfg.deinit();
        cfg.@"link-url" = false;
        if (custom) try cfg.link.links.append(cfg._arena.?.allocator(), .{
            .regex = "custom-validation-link",
            .action = .{ .open = {} },
            .highlight = .{ .always = {} },
        });
        try cfg.finalize();
        return cfg;
    }

    fn noLinks(alloc: Allocator) !Config {
        return withLinks(alloc, false);
    }

    fn customLinks(alloc: Allocator) !Config {
        return withLinks(alloc, true);
    }

    fn unexpected(_: Allocator) !Config {
        return error.UnexpectedDefaultLoad;
    }
};

test "validate config default finalization preserves empty links" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg = try loadForValidation(arena.allocator(), .{}, TestDefaultLoader.noLinks);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 0), cfg.link.links.items.len);
}

test "validate config default finalization preserves custom links and ownership" {
    var cfg = try loadForValidation(std.testing.allocator, .{}, TestDefaultLoader.customLinks);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 1), cfg.link.links.items.len);
    try std.testing.expectEqualStrings("custom-validation-link", cfg.link.links.items[0].regex);
}

test "validate config explicit file finalization and allocation failures" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config", .data = "link-url = false\n" });
    const path = try tmp.dir.realPathFileAlloc(testing.io, "config", testing.allocator);
    defer testing.allocator.free(path);
    const sentinel = try testing.allocator.dupeZ(u8, path);
    defer testing.allocator.free(sentinel);

    const Check = struct {
        fn run(alloc: Allocator, config_path: [:0]const u8) !void {
            var cfg = try loadForValidation(alloc, .{ .@"config-file" = config_path }, TestDefaultLoader.unexpected);
            defer cfg.deinit();
            try testing.expectEqual(@as(usize, 0), cfg._diagnostics.items().len);
            try testing.expectEqual(@as(usize, 0), cfg.link.links.items.len);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Check.run, .{sentinel});
}
