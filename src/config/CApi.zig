const std = @import("std");
const inputpkg = @import("../input.zig");
const global = @import("../global.zig");
const String = @import("../main_c.zig").String;

const Config = @import("Config.zig");
const c_get = @import("c_get.zig");
const Key = @import("key.zig").Key;

const log = std.log.scoped(.config);

/// Create a new configuration filled with the initial default values.
export fn ghostty_config_new() ?*Config {
    const result = global.alloc().create(Config) catch |err| {
        log.err("error allocating config err={}", .{err});
        return null;
    };

    result.* = Config.default(global.alloc()) catch |err| {
        log.err("error creating config err={}", .{err});
        global.alloc().destroy(result);
        return null;
    };

    return result;
}

export fn ghostty_config_free(ptr: ?*Config) void {
    if (ptr) |v| {
        v.deinit();
        global.alloc().destroy(v);
    }
}

/// Deep clone the configuration.
export fn ghostty_config_clone(self: *Config) ?*Config {
    const result = global.alloc().create(Config) catch |err| {
        log.err("error allocating config err={}", .{err});
        return null;
    };

    result.* = self.clone(global.alloc()) catch |err| {
        log.err("error cloning config err={}", .{err});
        global.alloc().destroy(result);
        return null;
    };

    return result;
}

/// Check using the same iterator as the CLI parser, without parsing twice on
/// normal application startup. On allocation failure retain the full load path.
export fn ghostty_config_has_cli_args() bool {
    var it = @import("../cli/args.zig").argsIterator(global.alloc(), global.args()) catch return true;
    defer it.deinit();
    return it.next() != null;
}

/// Load the configuration from the CLI args.
export fn ghostty_config_load_cli_args(self: *Config) void {
    self.loadCliArgs(global.alloc()) catch |err| {
        log.err("error loading config err={}", .{err});
    };
}

/// Load the configuration from the default file locations. This
/// is usually done first. The default file locations are locations
/// such as the home directory.
export fn ghostty_config_load_default_files(self: *Config) void {
    self.loadDefaultFiles(global.alloc()) catch |err| {
        log.err("error loading config err={}", .{err});
    };
}

/// Load the configuration from a specific file path.
/// The path must be null-terminated.
export fn ghostty_config_load_file(self: *Config, path: [*:0]const u8) void {
    const path_slice = std.mem.span(path);
    self.loadFile(global.alloc(), path_slice) catch |err| {
        log.err("error loading config from file path={s} err={}", .{ path_slice, err });
    };
}

/// Load a saved configuration without reopening the user's file.
export fn ghostty_config_load_data(self: *Config, data: [*]const u8, len: usize, path: [*:0]const u8) void {
    self.loadData(global.alloc(), data[0..len], std.mem.span(path)) catch |err| {
        self.addDiagnosticFmt("unable to read saved configuration: {}", .{err}) catch {};
    };
}

/// Set the initial branch before loading input. Used to validate both theme
/// branches without changing the configuration returned to the running app.
export fn ghostty_config_set_initial_theme(self: *Config, dark: bool) void {
    self._conditional_state.theme = if (dark) .dark else .light;
}

export fn ghostty_config_default_path() String {
    const path = @import("file_load.zig").defaultPath(global.alloc()) catch return .empty;
    return .fromSlice(path);
}

/// Load the configuration from the user-specified configuration
/// file locations in the previously loaded configuration. This will
/// recursively continue to load up to a built-in limit.
export fn ghostty_config_load_recursive_files(self: *Config) void {
    self.loadRecursiveFiles(global.alloc()) catch |err| {
        log.err("error loading config err={}", .{err});
    };
}

export fn ghostty_config_finalize(self: *Config) void {
    self.finalize() catch |err| {
        log.err("error finalizing config err={}", .{err});
    };
}

export fn ghostty_config_get(
    self: *Config,
    ptr: *anyopaque,
    key_str: [*]const u8,
    len: usize,
) bool {
    @setEvalBranchQuota(10_000);
    const key = std.meta.stringToEnum(Key, key_str[0..len]) orelse return false;
    return c_get.get(self, key, ptr);
}

export fn ghostty_config_trigger(
    self: *Config,
    str: [*]const u8,
    len: usize,
) inputpkg.Binding.Trigger.C {
    return config_trigger_(self, str[0..len]) catch |err| err: {
        log.err("error finding trigger err={}", .{err});
        break :err .{};
    };
}

fn config_trigger_(
    self: *Config,
    str: []const u8,
) !inputpkg.Binding.Trigger.C {
    const action = try inputpkg.Binding.Action.parse(str);
    const trigger: inputpkg.Binding.Trigger = self.keybind.set.getTrigger(action) orelse .{};
    return trigger.cval();
}

export fn ghostty_config_diagnostics_count(self: *Config) u32 {
    return @intCast(self._diagnostics.items().len);
}

export fn ghostty_config_get_diagnostic(self: *Config, idx: u32) Diagnostic {
    const items = self._diagnostics.items();
    if (idx >= items.len) return .{};
    const message = self._diagnostics.precompute.messages.items[idx];
    const item = items[idx];
    var result: Diagnostic = .{ .message = message.ptr, .key = item.key.ptr, .detail = item.message.ptr };
    switch (item.location) {
        .none => {},
        .cli => |index| {
            result.source = "cli";
            result.source_len = 3;
            result.line = index;
        },
        .file => |file| {
            result.source = file.path.ptr;
            result.source_len = file.path.len;
            result.line = file.line;
        },
    }
    return result;
}

export fn ghostty_settings_catalog() String {
    return .fromSlice(@import("settings.zig").catalog(global.alloc()) catch return .empty);
}

export fn ghostty_settings_load(self: *Config, data: [*]const u8, len: usize, source: [*:0]const u8) bool {
    @import("settings.zig").loadInput(self, global.alloc(), data[0..len], std.mem.span(source)) catch |err| {
        self.addDiagnosticFmt("Unable to parse application settings: {s}", .{@errorName(err)}) catch return false;
    };
    return true;
}

/// Verify migration preserved every public setting after detaching includes.
export fn ghostty_settings_equal(a: *Config, b: *Config) bool {
    @setEvalBranchQuota(100_000);
    inline for (@import("template_metadata.zig").entries) |entry| {
        if (comptime entry.key == .@"config-file" or entry.key == .@"config-default-files") continue;
        if (a.changed(b, entry.key)) return false;
    }
    return true;
}

/// Text for one setting, using the same formatter as the configuration guide.
/// The caller owns the returned string. This is a display API, not a serializer
/// for replacing a user's file (which may contain comments and ordered rules).
export fn ghostty_config_format_entry(self: *Config, key_str: [*]const u8, len: usize) String {
    @setEvalBranchQuota(100_000);
    inline for (@import("template_metadata.zig").entries) |entry| {
        const name = @tagName(entry.key);
        if (std.mem.eql(u8, name, key_str[0..len])) {
            var output: std.Io.Writer.Allocating = .init(global.alloc());
            defer output.deinit();
            @import("formatter.zig").formatEntry(@TypeOf(@field(self, name)), name, @field(self, name), &output.writer) catch return .empty;
            return .fromSlice(global.alloc().dupeZ(u8, output.written()) catch return .empty);
        }
    }
    return .empty;
}

/// Borrowed immutable bytes, valid for the process lifetime. Native settings
/// use the embedded face even when it is not installed as a system font.
export fn ghostty_settings_font_data(len: *usize) [*]const u8 {
    const data = @import("../font/embedded.zig").default_font;
    len.* = data.len;
    return data.ptr;
}

/// Sync with ghostty_diagnostic_s
const Diagnostic = extern struct {
    message: [*:0]const u8 = "",
    key: [*:0]const u8 = "",
    detail: [*:0]const u8 = "",
    source: ?[*]const u8 = null,
    source_len: usize = 0,
    line: usize = 0,
};

test "ghostty_config_get: bool" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.maximize = true;

    var out = false;
    const key = "maximize";
    try testing.expect(ghostty_config_get(&cfg, &out, key, key.len));
    try testing.expect(out);
}

test "ghostty_config_get: enum" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.@"window-theme" = .dark;

    var out: [*:0]const u8 = undefined;
    const key = "window-theme";
    try testing.expect(ghostty_config_get(&cfg, @ptrCast(&out), key, key.len));
    const str = std.mem.sliceTo(out, 0);
    try testing.expectEqualStrings("dark", str);
}

test "ghostty_config_get: optional null returns false" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.@"unfocused-split-fill" = null;

    var out: Config.Color.C = undefined;
    const key = "unfocused-split-fill";
    try testing.expect(!ghostty_config_get(&cfg, @ptrCast(&out), key, key.len));
}

test "ghostty_config_get: unknown key returns false" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();

    var out = false;
    const key = "not-a-real-key";
    try testing.expect(!ghostty_config_get(&cfg, &out, key, key.len));
}

test "ghostty_config_get: optional string null returns true" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.title = null;

    var out: ?[*:0]const u8 = undefined;
    const key = "title";
    try testing.expect(ghostty_config_get(&cfg, @ptrCast(&out), key, key.len));
    try testing.expect(out == null);
}

test "ghostty_config_get: float" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.@"background-opacity" = 0.42;

    var out: f64 = 0;
    const key = "background-opacity";
    try testing.expect(ghostty_config_get(&cfg, &out, key, key.len));
    try testing.expectApproxEqAbs(@as(f64, 0.42), out, 0.000001);
}

test "ghostty_config_get: struct cval conversion" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.background = .{ .r = 12, .g = 34, .b = 56 };

    var out: Config.Color.C = undefined;
    const key = "background";
    try testing.expect(ghostty_config_get(&cfg, @ptrCast(&out), key, key.len));
    try testing.expectEqual(@as(u8, 12), out.r);
    try testing.expectEqual(@as(u8, 34), out.g);
    try testing.expectEqual(@as(u8, 56), out.b);
}

test "ghostty_config_trigger: default keybind" {
    const testing = std.testing;

    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();

    // Default commands should be fetchable through config_trigger_
    {
        const trigger = try config_trigger_(&cfg, "open_config");
        try testing.expectEqual(.unicode, trigger.tag);
        try testing.expectEqual(@as(u32, ','), trigger.key.unicode);
    }
    // Performable bindings are not tracked in the reverse map,
    // so config_trigger_ should return a default (empty) trigger.
    const next = try config_trigger_(&cfg, "navigate_search:next");
    try testing.expectEqual(.physical, next.tag);
    try testing.expectEqual(.unidentified, next.key.physical);

    const prev = try config_trigger_(&cfg, "navigate_search:previous");
    try testing.expectEqual(.physical, prev.tag);
    try testing.expectEqual(.unidentified, prev.key.physical);
    {
        const trigger = try config_trigger_(&cfg, "adjust_selection:left");
        try testing.expectEqual(.physical, trigger.tag);
        try testing.expectEqual(.unidentified, trigger.key.physical);
    }
}

test "structured diagnostics preserve keys and file locations" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    try cfg._diagnostics.append(cfg._arena.?.allocator(), .{
        .location = .{ .file = .{ .path = "/tmp/theme:custom", .line = 7 } },
        .key = "font-family-bold",
        .message = "cannot open /tmp/font-family:custom",
    });
    const result = ghostty_config_get_diagnostic(&cfg, 0);
    try testing.expectEqualStrings("font-family-bold", std.mem.span(result.key));
    try testing.expectEqualStrings("cannot open /tmp/font-family:custom", std.mem.span(result.detail));
    try testing.expectEqualStrings("/tmp/theme:custom", result.source.?[0..result.source_len]);
    try testing.expectEqual(@as(usize, 7), result.line);
    try testing.expectEqualStrings("", std.mem.span(ghostty_config_get_diagnostic(&cfg, 1).key));
}
