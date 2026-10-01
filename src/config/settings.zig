//! Presentation data for the native settings window. Defaults, types and enum
//! choices remain owned by Config, while labels reuse the configuration guide.
const std = @import("std");
const Config = @import("Config.zig");
const metadata = @import("template_metadata.zig");
const formatter = @import("formatter.zig");

pub fn catalog(alloc: std.mem.Allocator) ![:0]const u8 {
    @setEvalBranchQuota(200_000);
    var config = try Config.default(alloc);
    defer config.deinit();
    var output: std.Io.Writer.Allocating = .init(alloc);
    defer output.deinit();
    try output.writer.writeByte('[');
    var first = true;
    inline for (metadata.entries) |entry| {
        const name = @tagName(entry.key);
        // The application owns persistence. File layering is migration-only.
        if (comptime std.mem.eql(u8, name, "config-file") or std.mem.eql(u8, name, "config-default-files")) continue;
        if (!first) try output.writer.writeByte(',');
        first = false;
        var value: std.Io.Writer.Allocating = .init(alloc);
        defer value.deinit();
        const Original = @TypeOf(@field(config, name));
        const T = if (@typeInfo(Original) == .optional) @typeInfo(Original).optional.child else Original;
        try formatter.formatEntry(Original, name, @field(config, name), &value.writer);
        const kind = switch (@typeInfo(T)) {
            .bool => "bool",
            .int => "integer",
            .float => "number",
            .@"enum" => "enum",
            else => "text",
        };
        const flags = comptime flagNames(T);
        const choices = comptime choicesFor(T);
        try std.json.Stringify.value(.{
            .key = name,
            .group = entry.group,
            .title = entry.en,
            .note = entry.note orelse "",
            .kind = kind,
            .choices = choices,
            .flags = flags,
            .multiline = std.mem.indexOf(u8, @typeName(T), "Repeatable") != null or std.mem.eql(u8, name, "keybind") or std.mem.eql(u8, name, "key-remap"),
            .defaults = value.written(),
            .example = entry.example orelse "",
        }, .{}, &output.writer);
    }
    try output.writer.writeByte(']');
    return alloc.dupeZ(u8, output.written());
}

// Flag names are derived from the same packed boolean structures the parser uses.
fn flagNames(comptime T: type) []const []const u8 {
    const info = @typeInfo(T);
    if (info != .@"struct") return &.{};
    if (info.@"struct".layout != .@"packed") return &.{};
    const fields = info.@"struct".fields;
    for (fields) |field| if (field.type != bool) return &.{};
    var names: [fields.len][]const u8 = undefined;
    for (fields, 0..) |field, i| names[i] = field.name;
    const result = names;
    return &result;
}

fn choicesFor(comptime T: type) []const []const u8 {
    return switch (@typeInfo(T)) {
        .bool => &.{ "true", "false" },
        .@"enum" => |info| blk: {
            var result: [info.fields.len][]const u8 = undefined;
            for (info.fields, 0..) |field, i| result[i] = field.name;
            const values = result;
            break :blk &values;
        },
        else => &.{},
    };
}

test "settings catalog uses core defaults and excludes file management" {
    const t = std.testing;
    const data = try catalog(t.allocator);
    defer t.allocator.free(data);
    const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, data, .{});
    defer parsed.deinit();
    var width = false;
    for (parsed.value.array.items) |item| {
        const key = item.object.get("key").?.string;
        try t.expect(!std.mem.eql(u8, key, "config-file"));
        if (std.mem.eql(u8, key, "window-width")) {
            width = true;
            try t.expectEqualStrings("window-width = 157\n", item.object.get("defaults").?.string);
        }
    }
    try t.expect(width);
}

/// Schema 1 is shared with SettingsStore. Values are kept separate from
/// imported layers so UI edits can replace repeatable entries without losing
/// unrelated settings or re-reading legacy files.
const Input = struct {
    layers: []const struct { text: []const u8, source: []const u8 } = &.{},
    values: std.json.ArrayHashMap([]const u8) = .{},
};

pub fn loadInput(config: *Config, alloc: std.mem.Allocator, data: []const u8, source: []const u8) !void {
    const parsed = try std.json.parseFromSlice(Input, alloc, data, .{});
    defer parsed.deinit();
    try applyInput(config, alloc, parsed.value, source);
}

fn applyInput(config: *Config, alloc: std.mem.Allocator, input: Input, source: []const u8) !void {
    for (input.layers) |layer| {
        if (!std.fs.path.isAbsolute(layer.source)) return error.InvalidSettingsSource;
        var filtered: std.Io.Writer.Allocating = .init(alloc);
        defer filtered.deinit();
        var lines = std.mem.splitScalar(u8, layer.text, '\n');
        while (lines.next()) |line| {
            if (line.len > @import("../cli/args.zig").LineIterator.MAX_LINE_SIZE - 2) return error.SettingTooLong;
            const trimmed = std.mem.trim(u8, line, " \t\r\xef\xbb\xbf");
            if (!std.mem.startsWith(u8, trimmed, "#")) {
                if (std.mem.indexOfScalar(u8, trimmed, '=')) |equal| {
                    const key = std.mem.trim(u8, trimmed[0..equal], " \t");
                    if (std.mem.eql(u8, key, "config-file") or std.mem.eql(u8, key, "config-default-files") or input.values.map.contains(key)) continue;
                    validateScalar(key, trimmed[equal + 1 ..]) catch |err| {
                        try config.addDiagnosticFmt("{s}: {s}", .{ key, @errorName(err) });
                        continue;
                    };
                }
            }
            try filtered.writer.print("{s}\n", .{line});
        }
        try config.loadData(alloc, filtered.written(), layer.source);
    }
    var overrides: std.Io.Writer.Allocating = .init(alloc);
    defer overrides.deinit();
    // JSONEncoder writes sorted keys. Sort again for other producers, keeping
    // order deterministic for settings with interactions.
    const keys = try alloc.dupe([]const u8, input.values.map.keys());
    defer alloc.free(keys);
    std.mem.sort([]const u8, keys, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    for (keys) |key| {
        const Key = @import("key.zig").Key;
        _ = std.meta.stringToEnum(Key, key) orelse return error.UnknownSetting;
        if (!Config.isUserConfigKey(key) or std.mem.eql(u8, key, "config-file") or std.mem.eql(u8, key, "config-default-files")) return error.UnknownSetting;
        const value = input.values.map.get(key).?;
        if (std.mem.indexOfAny(u8, value, "\x00\r") != null) return error.InvalidSettingValue;
        if (std.mem.eql(u8, key, "keybind") and value.len > 0) try overrides.writer.writeAll("keybind = clear\n");
        var lines = std.mem.splitScalar(u8, value, '\n');
        while (lines.next()) |line| {
            if (line.len + key.len + 3 > @import("../cli/args.zig").LineIterator.MAX_LINE_SIZE - 2) return error.SettingTooLong;
            validateScalar(key, line) catch |err| {
                try config.addDiagnosticFmt("{s}: {s}", .{ key, @errorName(err) });
                continue;
            };
            try overrides.writer.print("{s} = {s}\n", .{ key, line });
        }
    }
    try config.loadData(alloc, overrides.written(), source);
}

/// Reject values that finalization would otherwise silently clamp. This also
/// keeps CLI readers and recovery of a damaged internal record safe.
fn validateScalar(key: []const u8, raw: []const u8) !void {
    @setEvalBranchQuota(100_000);
    var value = std.mem.trim(u8, raw, " \t");
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
    if (value.len == 0) return;
    inline for (metadata.entries) |entry| {
        const name = @tagName(entry.key);
        const Original = @FieldType(Config, name);
        const T = if (@typeInfo(Original) == .optional) @typeInfo(Original).optional.child else Original;
        if (comptime @typeInfo(T) == .float or @typeInfo(T) == .int) {
            if (std.mem.eql(u8, key, name)) {
                const number: f64 = switch (@typeInfo(T)) {
                    .float => try std.fmt.parseFloat(T, value),
                    .int => @floatFromInt(try std.fmt.parseInt(T, value, 10)),
                    else => unreachable,
                };
                if (!std.math.isFinite(number)) return error.NonFiniteNumber;
                if (comptime std.mem.eql(u8, name, "font-size")) {
                    if (number <= 0) return error.FontSizeMustBePositive;
                }
                if (comptime std.mem.eql(u8, name, "window-width")) {
                    if (number != 0 and number < 10) return error.WindowWidthMustBeAtLeast10;
                }
                if (comptime std.mem.eql(u8, name, "window-height")) {
                    if (number != 0 and number < 4) return error.WindowHeightMustBeAtLeast4;
                }
                if (comptime std.mem.eql(u8, name, "background-opacity") or std.mem.eql(u8, name, "cursor-opacity") or std.mem.eql(u8, name, "faint-opacity")) {
                    if (number < 0 or number > 1) return error.OpacityMustBeBetweenZeroAndOne;
                }
                if (comptime std.mem.eql(u8, name, "unfocused-split-opacity")) {
                    if (number < 0.15 or number > 1) return error.SplitOpacityMustBeBetweenPoint15AndOne;
                }
                return;
            }
        }
    }
}

/// Returns false only when no internal settings exist yet. Once migrated,
/// errors must not silently switch the CLI back to the retired legacy file.
pub fn loadStored(config: *Config, alloc: std.mem.Allocator) !bool {
    const global = @import("../global.zig");
    const source = try @import("../os/main.zig").macos.appSupportDir(alloc, "Settings/settings.json");
    defer alloc.free(source);
    const data = std.Io.Dir.cwd().readFileAlloc(global.io(), source, alloc, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer alloc.free(data);
    try loadRecord(config, alloc, data, source);
    return true;
}

pub fn loadRecord(config: *Config, alloc: std.mem.Allocator, data: []const u8, source: []const u8) !void {
    const Record = struct { schema: u32, current: Input, previous: ?Input = null };
    const parsed = try std.json.parseFromSlice(Record, alloc, data, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (parsed.value.schema != 1) return error.UnsupportedSettingsVersion;
    if (try checkedInput(alloc, parsed.value.current, source)) |candidate| {
        config.deinit();
        config.* = candidate;
        return;
    }
    if (parsed.value.previous) |previous| {
        if (try checkedInput(alloc, previous, source)) |candidate| {
            config.deinit();
            config.* = candidate;
            try config.addDiagnosticFmt("Invalid settings; using the previous successful settings.", .{});
            return;
        }
    }
    try config.addDiagnosticFmt("Invalid settings; using built-in defaults. Open Settings to repair.", .{});
}

fn checkedInput(alloc: std.mem.Allocator, input: Input, source: []const u8) !?Config {
    var candidate = try Config.default(alloc);
    errdefer candidate.deinit();
    applyInput(&candidate, alloc, input, source) catch {
        candidate.deinit();
        return null;
    };
    // Validate a clone: callers still finalize after their CLI overrides and
    // must not load a theme twice into the configuration that they will use.
    var checked = try candidate.clone(alloc);
    defer checked.deinit();
    try checked.finalize();
    if (!checked._diagnostics.empty()) {
        candidate.deinit();
        return null;
    }
    return candidate;
}

test "settings storage replaces imported values and detaches includes" {
    const t = std.testing;
    var config = try Config.default(t.allocator);
    defer config.deinit();
    try loadInput(&config, t.allocator,
        \\{"layers":[{"source":"/tmp/legacy.conf","text":"title = Keep\nfont-family = Menlo\nfont-family = Monaco\nconfig-file = /missing/retired.conf"}],"values":{"font-family":"LXGW WenKai Mono\nMenlo","window-width":"158"}}
    , "/tmp/settings");
    try config.finalize();
    try t.expect(config._diagnostics.empty());
    try t.expectEqualStrings("Keep", config.title.?);
    try t.expectEqual(@as(u32, 158), config.@"window-width");
    try t.expectEqual(@as(usize, 0), config.@"config-file".value.items.len);
    var value: std.Io.Writer.Allocating = .init(t.allocator);
    defer value.deinit();
    try formatter.formatEntry(@TypeOf(config.@"font-family"), "font-family", config.@"font-family", &value.writer);
    try t.expectEqualStrings("font-family = LXGW WenKai Mono\nfont-family = Menlo\n", value.written());
}

test "settings storage rejects unknown keys and long lines" {
    const t = std.testing;
    var config = try Config.default(t.allocator);
    defer config.deinit();
    try t.expectError(error.UnknownSetting, loadInput(&config, t.allocator, "{\"values\":{\"config-file\":\"/tmp/other\"}}", "/tmp/settings"));
    try t.expectError(error.UnknownSetting, loadInput(&config, t.allocator, "{\"values\":{\"unknown-setting\":\"x\"}}", "/tmp/settings"));
    const long = "{\"values\":{\"title\":\"" ++ "a" ** 4096 ++ "\"}}";
    try t.expectError(error.SettingTooLong, loadInput(&config, t.allocator, long, "/tmp/settings"));
}

test "settings storage CLI uses previous record on invalid current input" {
    const t = std.testing;
    var config = try Config.default(t.allocator);
    defer config.deinit();
    try loadRecord(&config, t.allocator,
        \\{"schema":1,"revision":"ignored-by-core","current":{"values":{"title":"Partial","background-opacity":"broken"}},"previous":{"values":{"title":"Previous","background-opacity":"0.7"}}}
    , "/tmp/settings.json");
    try config.finalize();
    try t.expectEqualStrings("Previous", config.title.?);
    try t.expectEqual(@as(f64, 0.7), config.@"background-opacity");
    try t.expect(!config._diagnostics.empty());
}
