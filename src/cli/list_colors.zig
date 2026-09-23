const std = @import("std");
const Allocator = std.mem.Allocator;
const Action = @import("ghostty.zig").Action;
const args = @import("args.zig");
const x11_color = @import("../terminal/main.zig").x11_color;
const global = @import("../global.zig");

pub const Options = struct {
    pub fn deinit(self: Options) void {
        _ = self;
    }

    /// Accepted for compatibility; output is always plain.
    plain: bool = false,

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `list-colors` command is used to list all the named RGB colors in
/// Ghostty.
///
/// Flags:
///
///   * `--plain`: accepted for compatibility; output is always plain text.
pub fn run(alloc: Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try args.argsIterator(alloc, global.args());
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }

    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(alloc);
    for (x11_color.map.keys()) |key| try keys.append(alloc, key);

    std.mem.sortUnstable([]const u8, keys.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.ascii.orderIgnoreCase(lhs, rhs) == .lt;
        }
    }.lessThan);

    var stdout: std.Io.File = .stdout();
    {
        var buffer: [4096]u8 = undefined;
        var stdout_writer = stdout.writer(global.io(), &buffer);
        const writer = &stdout_writer.interface;
        for (keys.items) |name| {
            const rgb = x11_color.map.get(name).?;
            try writer.print("{s} = #{x:0>2}{x:0>2}{x:0>2}\n", .{
                name,
                rgb.r,
                rgb.g,
                rgb.b,
            });
        }
        try writer.flush();
    }

    return 0;
}
