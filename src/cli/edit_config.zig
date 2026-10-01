const std = @import("std");
const args = @import("args.zig");
const Allocator = std.mem.Allocator;
const Action = @import("ghostty.zig").Action;
const global = @import("../global.zig");

pub const Options = struct {
    pub fn deinit(self: Options) void {
        _ = self;
    }

    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// Settings are managed in cghostty's independent Settings window (Cmd+,).
/// This legacy command prints the new entry point. It no longer creates or
/// opens a separate configuration file, or launches $EDITOR / $VISUAL.
pub fn run(alloc: Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();
    var iter = try args.argsIterator(alloc, global.args());
    defer iter.deinit();
    try args.parse(Options, alloc, &opts, &iter);

    var buffer: [1024]u8 = undefined;
    var output = std.Io.File.stdout().writer(global.io(), &buffer);
    try output.interface.writeAll(
        "请在 cghostty 中选择 Settings…（⌘,）打开设置窗口。设置由应用内部保存，保存后重启生效。\n" ++
            "Open Settings (Cmd+,) in cghostty. Settings are stored internally; restart after saving.\n",
    );
    try output.interface.flush();
    return 0;
}
