//! Comment-only editing guide. Runtime defaults remain owned by Config.
const std = @import("std");
const Config = @import("Config.zig");
const Key = @import("key.zig").Key;
const formatter = @import("formatter.zig");
const metadata = @import("template_metadata.zig");
const build_config = @import("../build_config.zig");

pub const marker = "# cghostty configuration guide v1";
const groups = [_][]const u8{
    "1 常规 / General",
    "2 外观 / Appearance",
    "3 窗口与分屏 / Windows and Splits",
    "4 快捷终端 / Quick Terminal",
    "5 输入与快捷键 / Input and Shortcuts",
    "6 终端行为 / Terminal Behavior",
    "7 通知与安全 / Notifications and Security",
    "8 高级 / Advanced",
};

comptime {
    @setEvalBranchQuota(100_000);
    var seen = std.EnumSet(Key).initEmpty();
    for (metadata.entries) |entry| {
        if (seen.contains(entry.key)) @compileError("Duplicate guide entry: " ++ @tagName(entry.key));
        if (entry.group < 1 or entry.group > groups.len) @compileError("Invalid guide category");
        seen.insert(entry.key);
    }
    for (std.meta.fields(Key)) |field| {
        const key: Key = @enumFromInt(field.value);
        // CLI-only switch and internal URL rule list with no implemented parser.
        if (key == .@"config-default-files" or key == .link) continue;
        if (!seen.contains(key)) @compileError("Missing guide entry: " ++ field.name);
    }
}

pub fn generate(alloc: std.mem.Allocator) ![:0]const u8 {
    @setEvalBranchQuota(100_000);
    var config = try Config.default(alloc);
    defer config.deinit();
    var output: std.Io.Writer.Allocating = .init(alloc);
    defer output.deinit();
    const writer = &output.writer;
    try writer.print(marker ++ "\n# cghostty {s} — 用户配置 / User Configuration\n", .{build_config.version_string});
    try writer.writeAll(
        \\# Settings（⌘,）打开此文件。保存后退出并重新启动应用才生效。
        \\# Open with Settings (⌘,). Save, quit, and restart the app to apply changes.
        \\# 下方默认值和示例都是注释；取消示例行开头的 # 才启用设置。
        \\# Defaults and examples below are comments. Remove # from an example to enable it.
        \\# 默认值由当前版本生成，不包含主题或用户覆盖。留空可能表示自动、继承或空列表。
        \\# Defaults reflect this version before themes/user overrides. Unset may mean automatic, inherited, or an empty list.
        \\# 不要取消所有默认值的注释，否则可能覆盖主题。优先修改已有设置，避免重复定义。
        \\# Do not uncomment all defaults: they may override themes. Prefer editing existing settings to avoid duplicates.
        \\# 普通字段通常后者覆盖前者；列表、快捷键和规则可能追加或合并，保持重复项顺序。
        \\# Later scalar values usually win; lists, shortcuts and rules may append or merge. Preserve their order.
        \\# 配置错误时使用上次成功配置；没有可用快照则使用内置默认值，并显示错误窗口。
        \\# Invalid settings use the last successful configuration, or built-in defaults, with an error window.
        \\# Restore Default Settings… 会先备份，再恢复本模板；重启生效。
        \\# Restore Default Settings… backs up the file and restores this guide; restart to apply.
        \\# 完整英文说明：cghostty +show-config --default --docs
        \\# Full English reference: cghostty +show-config --default --docs
        \\
    );
    inline for (groups, 1..) |group, index| {
        try writer.print("\n# ======================================================================\n# {s}\n# ======================================================================\n", .{group});
        inline for (metadata.entries) |entry| {
            if (entry.group == index) {
                try writeEntry(alloc, &config, entry, writer);
            }
        }
    }
    return try alloc.dupeZ(u8, output.written());
}

/// Append documentation for new keys without rewriting user settings or old
/// guide sections. An empty result means opening the file is a read-only step.
pub fn generateSupplement(alloc: std.mem.Allocator, original: []const u8) ![:0]const u8 {
    @setEvalBranchQuota(100_000);
    var present = std.EnumSet(Key).initEmpty();
    var lines = std.mem.splitScalar(u8, original, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "# [")) continue;
        const end = std.mem.indexOfScalarPos(u8, line, 3, ']') orelse continue;
        if (std.meta.stringToEnum(Key, line[3..end])) |key| present.insert(key);
    }
    var config = try Config.default(alloc);
    defer config.deinit();
    var output: std.Io.Writer.Allocating = .init(alloc);
    defer output.deinit();
    inline for (metadata.entries) |entry| {
        if (!present.contains(entry.key)) {
            if (output.written().len == 0) try output.writer.print(
                "# 新增配置说明 / Additional configuration options — cghostty {s}\n",
                .{build_config.version_string},
            );
            try writeEntry(alloc, &config, entry, &output.writer);
        }
    }
    return try alloc.dupeZ(u8, output.written());
}

fn writeEntry(alloc: std.mem.Allocator, config: *const Config, comptime entry: metadata.Entry, writer: *std.Io.Writer) !void {
    const name = @tagName(entry.key);
    const value = @field(config, name);
    const T = @TypeOf(value);
    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try formatter.formatEntry(T, name, value, &buf.writer);
    try writer.print("\n# [{s}] {s} / {s}\n", .{ name, entry.zh, entry.en });
    if (entry.note) |note| try writer.print("# {s}\n", .{note});
    try choices(T, writer);
    const compact = std.mem.trimEnd(u8, buf.written(), " \r\n");
    if (std.mem.endsWith(u8, compact, "=")) {
        try writer.writeAll("# 默认 / Default: 未指定或空值，按自动／继承规则处理。 / Unset or empty; automatic/inherited rules apply.\n");
    } else try writer.writeAll("# 默认 / Default:\n");
    var lines = std.mem.tokenizeScalar(u8, buf.written(), '\n');
    var first: ?[]const u8 = null;
    while (lines.next()) |line| {
        if (first == null) first = line;
        try writer.print("#   {s}\n", .{line});
    }
    if (first == null) try writer.writeAll("#   自动决定 / Automatic\n");
    try writer.writeAll("# 示例（取消下一行的 # 后启用）/ Example (uncomment next line to enable):\n");
    if (entry.example) |example| {
        try writer.print("# {s} = {s}\n", .{ name, example });
    } else if (first) |line| {
        try writer.print("# {s}\n", .{line});
    } else return error.MissingExample;
}

fn choices(comptime Original: type, writer: *std.Io.Writer) !void {
    const T = if (@typeInfo(Original) == .optional) @typeInfo(Original).optional.child else Original;
    if (T == Config.Duration) {
        try writer.writeAll("# 时长必须带单位，例如 750ms、5s。 / Include a duration unit, such as 750ms or 5s.\n");
        return;
    }
    switch (@typeInfo(T)) {
        .bool => try writer.writeAll("# 可选值 / Values: true, false\n"),
        .@"enum" => |info| {
            try writer.writeAll("# 可选值 / Values: ");
            inline for (info.fields, 0..) |field, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.writeAll(field.name);
            }
            try writer.writeAll("\n");
        },
        else => {},
    }
}

test "configuration guide is comment-only and every example parses" {
    const testing = std.testing;
    const data = try generate(testing.allocator);
    defer testing.allocator.free(data);
    var untouched = try Config.default(testing.allocator);
    defer untouched.deinit();
    try untouched.loadData(testing.allocator, data, "/tmp/config.ghostty");
    try testing.expectEqual(@as(usize, 0), untouched._diagnostics.items().len);
    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    var example = false;
    var count: usize = 0;
    while (lines.next()) |line| {
        try testing.expect(std.mem.startsWith(u8, line, "#"));
        if (example) {
            var config = try Config.default(testing.allocator);
            defer config.deinit();
            try config.loadData(testing.allocator, line[2..], "/tmp/config.ghostty");
            if (config._diagnostics.items().len != 0) std.debug.print("Invalid guide example: {s}\n", .{line});
            try testing.expectEqual(@as(usize, 0), config._diagnostics.items().len);
            count += 1;
        }
        example = std.mem.startsWith(u8, line, "# 示例（");
    }
    try testing.expectEqual(metadata.entries.len, count);
}
