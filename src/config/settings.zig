//! Presentation data for the native settings window. Defaults, types and enum
//! choices remain owned by Config, while labels reuse the configuration guide.
const std = @import("std");
const Config = @import("Config.zig");
const metadata = @import("template_metadata.zig");
const formatter = @import("formatter.zig");

/// Application settings reject values that normal CLI finalization clamps.
/// The catalog exports these same bounds to native editors.
const NumericConstraint = struct {
    minimum: ?f64 = null,
    maximum: ?f64 = null,
    exclusiveMinimum: bool = false,
    allowZero: bool = false,
    components: []const []const u8 = &.{},

    fn validate(self: NumericConstraint, value: f64) !void {
        if (!std.math.isFinite(value)) return error.NonFiniteNumber;
        if (self.allowZero and value == 0) return;
        if (self.minimum) |minimum| {
            if (value < minimum or (self.exclusiveMinimum and value == minimum)) return error.NumberBelowMinimum;
        }
        if (self.maximum) |maximum| {
            if (value > maximum) return error.NumberAboveMaximum;
        }
    }
};

fn numericConstraint(key: []const u8) ?NumericConstraint {
    const constraints = [_]struct { key: []const u8, bounds: NumericConstraint }{
        .{ .key = "font-size", .bounds = .{ .minimum = 0, .exclusiveMinimum = true } },
        .{ .key = "window-width", .bounds = .{ .minimum = 10, .allowZero = true } },
        .{ .key = "window-height", .bounds = .{ .minimum = 4, .allowZero = true } },
        .{ .key = "background-opacity", .bounds = .{ .minimum = 0, .maximum = 1 } },
        .{ .key = "cursor-opacity", .bounds = .{ .minimum = 0, .maximum = 1 } },
        .{ .key = "faint-opacity", .bounds = .{ .minimum = 0, .maximum = 1 } },
        .{ .key = "unfocused-split-opacity", .bounds = .{ .minimum = 0.15, .maximum = 1 } },
        .{ .key = "font-thicken-strength", .bounds = .{ .minimum = 0, .maximum = 255 } },
        .{ .key = "minimum-contrast", .bounds = .{ .minimum = 1, .maximum = 21 } },
        .{ .key = "mouse-scroll-multiplier", .bounds = .{ .minimum = 0.01, .maximum = 10000, .components = &.{ "precision", "discrete" } } },
    };
    for (constraints) |entry| {
        if (std.mem.eql(u8, key, entry.key)) return entry.bounds;
    }
    return null;
}

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
            .numericConstraint = numericConstraint(name),
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
                    validateScalar(alloc, key, trimmed[equal + 1 ..]) catch |err| {
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
            validateScalar(alloc, key, line) catch |err| {
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
fn validateScalar(alloc: std.mem.Allocator, key: []const u8, raw: []const u8) !void {
    @setEvalBranchQuota(100_000);
    var value = std.mem.trim(u8, raw, " \t");
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
    if (value.len == 0) return;
    const bounds = numericConstraint(key);
    if (std.mem.eql(u8, key, "mouse-scroll-multiplier")) {
        var multiplier: Config.MouseScrollMultiplier = .default;
        try multiplier.parseCLI(alloc, value);
        try bounds.?.validate(multiplier.precision);
        try bounds.?.validate(multiplier.discrete);
        return;
    }
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
                if (bounds) |constraint| try constraint.validate(number);
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

/// Shared by CLI loading and native startup. Invalid denotes a malformed
/// record or allocation failure at the C boundary, not a recovery choice.
pub const RecoverySource = enum(c_int) {
    invalid = -1,
    current = 0,
    previous = 1,
    defaults = 2,
};

const Selection = struct { source: RecoverySource, config: ?Config = null };

fn selectRecord(alloc: std.mem.Allocator, data: []const u8, source: []const u8) !Selection {
    const Record = struct { schema: u32, current: Input, previous: ?Input = null };
    const parsed = try std.json.parseFromSlice(Record, alloc, data, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (parsed.value.schema != 1) return error.UnsupportedSettingsVersion;
    if (try checkedInput(alloc, parsed.value.current, source)) |candidate| {
        return .{ .source = .current, .config = candidate };
    }
    if (parsed.value.previous) |previous| {
        if (try checkedInput(alloc, previous, source)) |candidate| {
            return .{ .source = .previous, .config = candidate };
        }
    }
    return .{ .source = .defaults };
}

/// Inspect the supplied immutable record; never reopen its storage path.
pub fn recoverySource(alloc: std.mem.Allocator, data: []const u8, source: []const u8) !RecoverySource {
    var selection = try selectRecord(alloc, data, source);
    defer if (selection.config) |*config| config.deinit();
    return selection.source;
}

pub fn loadRecord(config: *Config, alloc: std.mem.Allocator, data: []const u8, source: []const u8) !void {
    const selection = try selectRecord(alloc, data, source);
    if (selection.config) |candidate| {
        config.deinit();
        config.* = candidate;
    }
    switch (selection.source) {
        .current => {},
        .previous => try addRecoveryDiagnostic(config, "Invalid settings; using the previous successful settings."),
        .defaults => try addRecoveryDiagnostic(config, "Invalid settings; using built-in defaults. Open Settings to repair."),
        .invalid => unreachable,
    }
}

fn addRecoveryDiagnostic(config: *Config, comptime message: []const u8) !void {
    try config.addDiagnosticFmt(message, .{});
    const diagnostics = config._diagnostics.items();
    // Recovery warnings cannot be repaired by replaying the chosen input. Keep
    // them when finalization loads a theme and when appearance changes replay.
    try config._replay_steps.append(config.arenaAlloc(), .{ .diagnostic = diagnostics[diagnostics.len - 1] });
}

fn checkedInput(alloc: std.mem.Allocator, input: Input, source: []const u8) !?Config {
    var candidate = try Config.default(alloc);
    errdefer candidate.deinit();
    applyInput(&candidate, alloc, input, source) catch |err| {
        if (err == error.OutOfMemory) return err;
        candidate.deinit();
        return null;
    };
    // Validate both appearances with the conditional state set before parsing.
    // A fresh parse also covers conditional values in imported layers. Keep
    // the selected input unfinalized so CLI overrides precede theme loading.
    for ([_]@import("conditional.zig").State.Theme{ .light, .dark }) |theme| {
        var checked = try Config.default(alloc);
        defer checked.deinit();
        checked._conditional_state.theme = theme;
        applyInput(&checked, alloc, input, source) catch |err| {
            if (err == error.OutOfMemory) return err;
            candidate.deinit();
            return null;
        };
        try checked.finalize();
        if (!checked._diagnostics.empty()) {
            candidate.deinit();
            return null;
        }
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

test "settings numeric constraints reject clamped contrast and scroll values" {
    const t = std.testing;
    for ([_][]const u8{ "0.99", "21.01", "100", "nan", "inf" }) |value| {
        var config = try Config.default(t.allocator);
        defer config.deinit();
        const data = try std.json.Stringify.valueAlloc(t.allocator, .{ .values = .{ .@"minimum-contrast" = value } }, .{});
        defer t.allocator.free(data);
        try loadInput(&config, t.allocator, data, "/tmp/settings");
        try t.expect(!config._diagnostics.empty());
    }
    for ([_][]const u8{ "0.009", "10001", "nan", "inf", "precision:0.009", "discrete:10001", "precision:nan", "discrete:inf" }) |value| {
        var config = try Config.default(t.allocator);
        defer config.deinit();
        const data = try std.json.Stringify.valueAlloc(t.allocator, .{ .values = .{ .@"mouse-scroll-multiplier" = value } }, .{});
        defer t.allocator.free(data);
        try loadInput(&config, t.allocator, data, "/tmp/settings");
        try t.expect(!config._diagnostics.empty());
    }
}

test "settings numeric constraints preserve inclusive boundaries and CLI clamping" {
    const t = std.testing;
    for ([_][]const u8{ "1", "21" }) |value| {
        try validateScalar(t.allocator, "minimum-contrast", value);
    }
    for ([_][]const u8{ "0.01", "10000", "precision:0.01,discrete:10000", "precision:10000,discrete:0.01" }) |value| {
        try validateScalar(t.allocator, "mouse-scroll-multiplier", value);
    }
    try validateScalar(t.allocator, "background-image-opacity", "2");
    var config = try Config.default(t.allocator);
    defer config.deinit();
    try config.loadData(t.allocator, "minimum-contrast = 100\nmouse-scroll-multiplier = precision:0.001,discrete:20000", "/tmp/explicit-cli.conf");
    try config.finalize();
    try t.expect(config._diagnostics.empty());
    try t.expectEqual(@as(f64, 21), config.@"minimum-contrast");
    try t.expectEqual(@as(f64, 0.01), config.@"mouse-scroll-multiplier".precision);
    try t.expectEqual(@as(f64, 10000), config.@"mouse-scroll-multiplier".discrete);
}

test {
    _ = @import("settings_recovery_tests.zig");
}

test "settings recovery propagates allocation failure before choosing defaults" {
    const t = std.testing;
    const parsed = try std.json.parseFromSlice(Input, t.allocator, "{\"values\":{\"title\":\"Current\"}}", .{});
    defer parsed.deinit();
    // Measure default initialization separately. With no imported layers, the
    // next allocation in checkedInput is applyInput's owned key-order copy.
    var probe = t.FailingAllocator.init(t.allocator, .{});
    var defaults = try Config.default(probe.allocator());
    const default_allocations = probe.alloc_index;
    try applyInput(&defaults, probe.allocator(), parsed.value, "/tmp/settings.json");
    const candidate_allocations = probe.alloc_index;
    defaults.deinit();
    // Fail the key-order copy in both the selected input and a validation
    // appearance, checking each catch without probing unrelated parser paths.
    for ([_]usize{ default_allocations, candidate_allocations + default_allocations }) |index| {
        var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = index });
        try t.expectError(error.OutOfMemory, checkedInput(failing.allocator(), parsed.value, "/tmp/settings.json"));
        try t.expect(failing.has_induced_failure);
    }
}
