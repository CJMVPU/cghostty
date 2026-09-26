//! Editing guide with tracing explicitly disabled in newly generated files.
//! Supplements remain comment-only. Runtime defaults remain owned by Config.
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
        if (!Config.isUserConfigKey(field.name) or key == .@"config-default-files" or key == .link) continue;
        if (!seen.contains(key)) @compileError("Missing guide entry: " ++ field.name);
    }
}

pub fn generate(alloc: std.mem.Allocator) ![:0]const u8 {
    return generateGuide(alloc, true);
}

/// Appending a guide must not override existing settings.
pub fn generateComments(alloc: std.mem.Allocator) ![:0]const u8 {
    return generateGuide(alloc, false);
}

fn generateGuide(alloc: std.mem.Allocator, explicit_trace_default: bool) ![:0]const u8 {
    @setEvalBranchQuota(100_000);
    var config = try Config.default(alloc);
    defer config.deinit();
    var output: std.Io.Writer.Allocating = .init(alloc);
    defer output.deinit();
    const writer = &output.writer;
    try writer.print(marker ++ "\n# cghostty {s} — 用户配置 / User Configuration\n", .{build_config.version_string});
    try writer.writeAll(
        \\# 中文说明
        \\# Settings（⌘,）打开此文件；修改后保存、退出并重新启动应用。
        \\# 取消示例行开头的 # 启用设置，优先修改已有设置，避免重复定义。
        \\# 默认值不含主题或用户覆盖；完整快捷键和命令面板默认值见末尾附录。
        \\# 新模板显式关闭 render-trace；其他示例及附录均为注释。
        \\# 列表和规则可能追加或合并，请保留顺序。配置无效时回退到上次成功配置或内置默认值。
        \\# Restore Default Settings… 会先备份再恢复模板。详细说明：cghostty +show-config --default --docs
        \\#
        \\# English guide
        \\# Open with Settings (⌘,); save, quit, and restart the app to apply changes.
        \\# Uncomment an example to enable it. Edit existing settings first to avoid duplicates.
        \\# Defaults exclude theme/user overrides; full key bindings and command entries are in the appendix.
        \\# New templates explicitly disable render-trace; other examples and appendix entries are comments.
        \\# Lists and rules may append or merge: preserve their order. Invalid settings fall back to the last good config or defaults.
        \\# Restore Default Settings… backs up the file before restoring the guide. Details: cghostty +show-config --default --docs
        \\
    );
    inline for (groups, 1..) |group, index| {
        try writer.print("\n# ======================================================================\n# {s}\n# ======================================================================\n", .{group});
        inline for (metadata.entries) |entry| {
            if (entry.group == index) {
                try writeEntry(alloc, &config, entry, writer, explicit_trace_default);
            }
        }
    }
    try writeAppendices(alloc, &config, &output.writer, .initFull(), "");
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
    var missing = std.EnumSet(Key).initEmpty();
    inline for (metadata.entries) |entry| {
        if (!present.contains(entry.key)) {
            missing.insert(entry.key);
            if (output.written().len == 0) try output.writer.print(
                "# 新增配置说明 / Additional configuration options — cghostty {s}\n",
                .{build_config.version_string},
            );
            try writeEntry(alloc, &config, entry, &output.writer, false);
        }
    }
    try writeAppendices(alloc, &config, &output.writer, missing, original);
    return try alloc.dupeZ(u8, output.written());
}

const appendix_keys = [_]Key{ .keybind, .@"command-palette-entry" };

fn hasAppendix(key: Key) bool {
    for (appendix_keys) |candidate| if (key == candidate) return true;
    return false;
}

fn writeEntry(alloc: std.mem.Allocator, config: *const Config, comptime entry: metadata.Entry, writer: *std.Io.Writer, explicit_trace_default: bool) !void {
    const name = @tagName(entry.key);
    const value = @field(config, name);
    const T = @TypeOf(value);
    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try formatter.formatEntry(T, name, value, &buf.writer);
    var lines = std.mem.tokenizeScalar(u8, buf.written(), '\n');
    const first = lines.next();
    const default_value = if (first) |line|
        std.mem.trim(u8, line[(std.mem.indexOfScalar(u8, line, '=') orelse return error.MissingExample) + 1 ..], " \r\n")
    else
        "";

    try writer.print("\n# [{s}] {s} / {s}\n# 默认 / Default: ", .{ name, entry.zh, entry.en });
    if (comptime hasAppendix(entry.key)) {
        try writer.print("完整列表见附录 [{s}]。 / Full list in appendix [{s}].", .{ name, name });
    } else if (default_value.len == 0) {
        try writer.writeAll("未指定或空值，按自动／继承规则处理。 / Unset or empty; automatic/inherited rules apply.");
    } else try writer.writeAll(default_value);
    try choices(T, writer);
    try writer.writeAll("\n# 示例 / Example:\n");
    // New files explicitly disable tracing; supplements never change settings.
    if (entry.key == .@"render-trace" and explicit_trace_default) {
        try writer.print("{s} = {s}\n", .{ name, if (config.@"render-trace") "true" else "false" });
    } else if (entry.example) |example| {
        try writer.print("# {s} = {s}\n", .{ name, example });
    } else if (first) |line| {
        try writer.print("# {s}\n", .{line});
    } else return error.MissingExample;
}

/// Keep enum choices discoverable without adding another line to each entry.
fn choices(comptime Original: type, writer: *std.Io.Writer) !void {
    const T = if (@typeInfo(Original) == .optional) @typeInfo(Original).optional.child else Original;
    switch (@typeInfo(T)) {
        .@"enum" => |info| {
            try writer.writeAll("；可选 / Values: ");
            inline for (info.fields, 0..) |field, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.writeAll(field.name);
            }
        },
        else => {},
    }
}

fn writeAppendices(alloc: std.mem.Allocator, config: *const Config, writer: *std.Io.Writer, keys: std.EnumSet(Key), original: []const u8) !void {
    var heading_written = false;
    inline for (appendix_keys) |key| {
        const name = @tagName(key);
        const heading = "# 附录 [" ++ name ++ "]";
        // A partially removed main entry can be supplemented without copying
        // its existing appendix a second time.
        const present = std.mem.startsWith(u8, original, heading) or
            std.mem.indexOf(u8, original, "\n" ++ heading) != null;
        if (keys.contains(key) and !present) {
            if (!heading_written) {
                try writer.writeAll("\n# ======================================================================\n# 附录 / Appendix — 完整默认值 / Complete defaults\n# 以下均为注释，仅供参考。 / Commented reference values only.\n# ======================================================================\n");
                heading_written = true;
            }
            try writer.print("\n" ++ heading ++ " / Appendix [{s}]\n", .{name});
            var buf: std.Io.Writer.Allocating = .init(alloc);
            defer buf.deinit();
            try formatter.formatEntry(@TypeOf(@field(config, name)), name, @field(config, name), &buf.writer);
            var lines = std.mem.tokenizeScalar(u8, buf.written(), '\n');
            while (lines.next()) |line| try writer.print("# {s}\n", .{line});
        }
    }
}

test "configuration guide explicitly disables tracing and every example parses" {
    const testing = std.testing;
    const data = try generate(testing.allocator);
    defer testing.allocator.free(data);
    var untouched = try Config.default(testing.allocator);
    defer untouched.deinit();
    try untouched.loadData(testing.allocator, data, "/tmp/config.ghostty");
    try testing.expectEqual(@as(usize, 0), untouched._diagnostics.items().len);
    try testing.expect(!untouched.@"render-trace");
    try testing.expectEqual(.classic, untouched.@"cursor-effect-mode");
    try testing.expect(std.mem.indexOf(u8, data, "；可选 / Values: classic, responsive, instant") != null);
    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    var example = false;
    var count: usize = 0;
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "render-trace = false")) {
            try testing.expect(example);
            count += 1;
            example = false;
            continue;
        }
        try testing.expect(std.mem.startsWith(u8, line, "#"));
        if (example) {
            var config = try Config.default(testing.allocator);
            defer config.deinit();
            try config.loadData(testing.allocator, line[2..], "/tmp/config.ghostty");
            if (config._diagnostics.items().len != 0) std.debug.print("Invalid guide example: {s}\n", .{line});
            try testing.expectEqual(@as(usize, 0), config._diagnostics.items().len);
            count += 1;
        }
        example = std.mem.eql(u8, line, "# 示例 / Example:");
    }
    try testing.expectEqual(metadata.entries.len, count);
    const supplement = try generateSupplement(testing.allocator, "render-trace = true\n");
    defer testing.allocator.free(supplement);
    try untouched.loadData(testing.allocator, "render-trace = true\ncursor-effect-mode = instant\n", "/tmp/config.ghostty");
    try untouched.loadData(testing.allocator, supplement, "/tmp/config.ghostty");
    try testing.expect(untouched.@"render-trace");
    try testing.expectEqual(.instant, untouched.@"cursor-effect-mode");
}

test "configuration guide compact entries and grouped language introduction" {
    const t = std.testing;
    const data = try generate(t.allocator);
    defer t.allocator.free(data);
    const chinese = std.mem.indexOf(u8, data, "# 中文说明\n").?;
    const english = std.mem.indexOf(u8, data, "# English guide\n").?;
    const body = std.mem.indexOf(u8, data, "# [command]").?;
    try t.expect(chinese < english and english < body);
    try t.expect(std.mem.indexOf(u8, data[chinese..english], "# Open with") == null);
    try t.expect(std.mem.indexOf(u8, data[english..body], "# 取消示例") == null);
    const command_end = std.mem.indexOfPos(u8, data, body, "\n\n").?;
    try t.expectEqualStrings(
        "# [command] 新终端启动命令／Shell / Terminal shell or command\n" ++
            "# 默认 / Default: 未指定或空值，按自动／继承规则处理。 / Unset or empty; automatic/inherited rules apply.\n" ++
            "# 示例 / Example:\n" ++
            "# command = /bin/zsh",
        data[body..command_end],
    );
    const appendix = std.mem.indexOf(u8, data, "# 附录 / Appendix").?;
    var blocks = std.mem.splitSequence(u8, data[body..appendix], "\n\n");
    var entries: usize = 0;
    while (blocks.next()) |block| {
        if (!std.mem.startsWith(u8, block, "# [")) continue;
        var lines = std.mem.tokenizeScalar(u8, block, '\n');
        _ = lines.next().?;
        try t.expect(std.mem.startsWith(u8, lines.next().?, "# 默认 / Default:"));
        try t.expectEqualStrings("# 示例 / Example:", lines.next().?);
        const example = lines.next().?;
        try t.expect(std.mem.startsWith(u8, example, "# ") or std.mem.eql(u8, example, "render-trace = false"));
        try t.expect(lines.next() == null);
        entries += 1;
    }
    try t.expectEqual(metadata.entries.len, entries);
    try t.expect(std.mem.indexOf(u8, data, "# [palette]") == null);
    try t.expect(std.mem.indexOf(u8, data, "# palette =") == null);
    try t.expect(std.mem.indexOf(u8, data, "#   command =") == null);
}

test "configuration guide appendix preserves every list default as comments" {
    const t = std.testing;
    const data = try generate(t.allocator);
    defer t.allocator.free(data);
    const start = std.mem.indexOf(u8, data, "# 附录 / Appendix").?;
    var config = try Config.default(t.allocator);
    defer config.deinit();
    inline for (appendix_keys) |key| {
        const name = @tagName(key);
        const heading = "# 附录 [" ++ name ++ "]";
        const a = std.mem.indexOf(u8, data, heading).?;
        const b = std.mem.indexOfPos(u8, data, a + heading.len, "\n# 附录 [") orelse data.len;
        try t.expect(a > start);
        var expected: std.Io.Writer.Allocating = .init(t.allocator);
        defer expected.deinit();
        try formatter.formatEntry(@TypeOf(@field(config, name)), name, @field(config, name), &expected.writer);
        var actual: std.Io.Writer.Allocating = .init(t.allocator);
        defer actual.deinit();
        var lines = std.mem.tokenizeScalar(u8, data[a..b], '\n');
        _ = lines.next(); // Appendix heading.
        while (lines.next()) |line| {
            try t.expect(std.mem.startsWith(u8, line, "# " ++ name ++ " = "));
            try actual.writer.print("{s}\n", .{line[2..]});
        }
        try t.expectEqualStrings(expected.written(), actual.written());
    }
}

test "configuration guide supplements stay compact and never duplicate existing appendices" {
    const t = std.testing;
    const data = try generateComments(t.allocator);
    defer t.allocator.free(data);
    const none = try generateSupplement(t.allocator, data);
    defer t.allocator.free(none);
    try t.expectEqual(@as(usize, 0), none.len);
    const start = std.mem.indexOf(u8, data, "\n# [keybind]").?;
    const end = std.mem.indexOfPos(u8, data, start + 1, "\n# [").?;
    const incomplete = try std.mem.concat(t.allocator, u8, &.{ data[0..start], data[end..] });
    defer t.allocator.free(incomplete);
    const supplement = try generateSupplement(t.allocator, incomplete);
    defer t.allocator.free(supplement);
    try t.expect(std.mem.indexOf(u8, supplement, "# [keybind]") != null);
    try t.expect(std.mem.indexOf(u8, supplement, "# 附录 [keybind]") == null);
    const existing = "render-trace = true\nfont-size = 19\nkeybind = super+t=unbind\n";
    const full_supplement = try generateSupplement(t.allocator, existing);
    defer t.allocator.free(full_supplement);
    try t.expect(std.mem.indexOf(u8, full_supplement, "# 附录 [keybind]") != null);
    var config = try Config.default(t.allocator);
    defer config.deinit();
    try config.loadData(t.allocator, existing, "/tmp/config.ghostty");
    try config.loadData(t.allocator, full_supplement, "/tmp/config.ghostty");
    try t.expect(config.@"render-trace");
    try t.expectEqual(@as(f32, 19), config.@"font-size");
    try t.expectEqual(@as(usize, 0), config._diagnostics.items().len);
    var lines = std.mem.tokenizeScalar(u8, full_supplement, '\n');
    while (lines.next()) |line| try t.expect(std.mem.startsWith(u8, line, "#"));
}
