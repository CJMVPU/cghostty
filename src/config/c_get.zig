const std = @import("std");

const key = @import("key.zig");
const Config = @import("Config.zig");
const Color = Config.Color;
const Key = key.Key;
const Value = key.Value;

/// Get a value from the config by key into the given pointer. This is
/// specifically for C-compatible APIs. If you're using Zig, just access
/// the configuration directly.
///
/// The return value is false if the given key is not supported by the
/// C API yet. This is a fixable problem so if it is important to support
/// some key, please open an issue.
pub fn get(config: *const Config, k: Key, ptr_raw: *anyopaque) bool {
    @setEvalBranchQuota(10_000);
    switch (k) {
        inline else => |tag| {
            const value = fieldByKey(config, tag);
            return getValue(ptr_raw, value);
        },
    }
}

/// The exact output storage used by the C getter. Code generators share this
/// contract with getValue so native callers cannot guess a field's ABI type.
/// Optional values normally use their child's storage and signal absence with
/// false; optional strings instead write a nullable pointer and return true.
pub fn CValue(comptime T: type) ?type {
    return switch (T) {
        ?[:0]const u8 => ?[*:0]const u8,
        bool => bool,
        u8, u32 => c_uint,
        i16 => c_short,
        f32, f64 => T,
        else => switch (@typeInfo(T)) {
            .optional => |info| CValue(info.child),
            .@"enum" => [*:0]const u8,
            .@"struct" => |info| blk: {
                if (@hasDecl(T, "cval")) break :blk @typeInfo(@TypeOf(T.cval)).@"fn".return_type.?;
                if (info.layout != .@"packed") break :blk null;
                const Backing = info.backing_integer orelse break :blk null;
                break :blk if (@bitSizeOf(Backing) <= @bitSizeOf(c_uint)) c_uint else null;
            },
            .@"union" => if (@hasDecl(T, "cval")) @typeInfo(@TypeOf(T.cval)).@"fn".return_type.? else null,
            else => null,
        },
    };
}

/// Get the value anytype and put it into the pointer. Returns false if
/// the type is not supported by the C API yet or the value is null.
fn getValue(ptr_raw: *anyopaque, value: anytype) bool {
    const C = CValue(@TypeOf(value)) orelse return false;
    const ptr: *C = @ptrCast(@alignCast(ptr_raw));
    switch (@TypeOf(value)) {
        ?[:0]const u8 => {
            ptr.* = if (value) |slice| @ptrCast(slice.ptr) else null;
        },

        bool => {
            ptr.* = value;
        },

        u8, u32 => {
            ptr.* = @intCast(value);
        },

        i16 => {
            ptr.* = @intCast(value);
        },

        f32, f64 => {
            ptr.* = @floatCast(value);
        },

        else => |T| switch (@typeInfo(T)) {
            .optional => {
                // If an optional has no value we return false.
                const unwrapped = value orelse return false;
                return getValue(ptr_raw, unwrapped);
            },

            .@"enum" => {
                ptr.* = @tagName(value);
            },

            .@"struct" => |info| {
                // If the struct implements cval then we call then.
                if (@hasDecl(T, "cval")) {
                    ptr.* = value.cval();
                    return true;
                }

                // Packed structs that are less than or equal to the
                // size of a C int can be passed directly as their
                // bit representation.
                if (info.layout != .@"packed") return false;
                const Backing = info.backing_integer orelse return false;
                if (@bitSizeOf(Backing) > @bitSizeOf(c_uint)) return false;

                ptr.* = @intCast(@as(Backing, @bitCast(value)));
            },

            .@"union" => {
                if (@hasDecl(T, "cval")) {
                    ptr.* = value.cval();
                    return true;
                }

                return false;
            },

            else => return false,
        },
    }

    return true;
}

/// Get a value from the config by key.
fn fieldByKey(self: *const Config, comptime k: Key) Value(k) {
    const field = comptime field: {
        const fields = std.meta.fields(Config);
        for (fields) |field| {
            if (@field(Key, field.name) == k) {
                break :field field;
            }
        }

        unreachable;
    };

    return @field(self, field.name);
}

test "c_get: reflected storage preserves optional and unsupported semantics" {
    const testing = std.testing;
    try testing.expect(CValue(?i16).? == c_short);
    try testing.expect(CValue(?[:0]const u8).? == ?[*:0]const u8);
    try testing.expect(CValue(Config.Duration).? == usize);
    try testing.expect(CValue(Config.Color).? == Config.Color.C);
    try testing.expect(CValue([]const u8) == null);

    var position: c_short = 42;
    try testing.expect(!getValue(&position, @as(?i16, null)));
    try testing.expectEqual(@as(c_short, 42), position);
    try testing.expect(getValue(&position, @as(?i16, -123)));
    try testing.expectEqual(@as(c_short, -123), position);

    var string: ?[*:0]const u8 = "before";
    try testing.expect(getValue(@ptrCast(&string), @as(?[:0]const u8, null)));
    try testing.expect(string == null);
    try testing.expect(!getValue(&position, @as([]const u8, "unsupported")));
    try testing.expectEqual(@as(c_short, -123), position);
}

test "c_get: u8" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c = try Config.default(alloc);
    defer c.deinit();
    c.@"font-size" = 24;

    var cval: f32 = undefined;
    try testing.expect(get(&c, .@"font-size", &cval));
    try testing.expectEqual(@as(f32, 24), cval);
}

test "c_get: enum" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c = try Config.default(alloc);
    defer c.deinit();
    c.@"window-theme" = .dark;

    var cval: [*:0]u8 = undefined;
    try testing.expect(get(&c, .@"window-theme", @ptrCast(&cval)));

    const str = std.mem.sliceTo(cval, 0);
    try testing.expectEqualStrings("dark", str);
}

test "c_get: color" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c = try Config.default(alloc);
    defer c.deinit();
    c.background = .{ .r = 255, .g = 0, .b = 0 };

    var cval: Color.C = undefined;
    try testing.expect(get(&c, .background, @ptrCast(&cval)));
    try testing.expectEqual(255, cval.r);
    try testing.expectEqual(0, cval.g);
    try testing.expectEqual(0, cval.b);
}

test "c_get: optional" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c = try Config.default(alloc);
    defer c.deinit();

    {
        c.@"unfocused-split-fill" = null;
        var cval: Color.C = undefined;
        try testing.expect(!get(&c, .@"unfocused-split-fill", @ptrCast(&cval)));
    }

    {
        c.@"unfocused-split-fill" = .{ .r = 255, .g = 0, .b = 0 };
        var cval: Color.C = undefined;
        try testing.expect(get(&c, .@"unfocused-split-fill", @ptrCast(&cval)));
        try testing.expectEqual(255, cval.r);
        try testing.expectEqual(0, cval.g);
        try testing.expectEqual(0, cval.b);
    }
}

test "c_get: background-blur" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c = try Config.default(alloc);
    defer c.deinit();

    {
        c.@"background-blur" = .false;
        var cval: i16 = undefined;
        try testing.expect(get(&c, .@"background-blur", @ptrCast(&cval)));
        try testing.expectEqual(0, cval);
    }
    {
        c.@"background-blur" = .true;
        var cval: i16 = undefined;
        try testing.expect(get(&c, .@"background-blur", @ptrCast(&cval)));
        try testing.expectEqual(20, cval);
    }
    {
        c.@"background-blur" = .{ .radius = 42 };
        var cval: i16 = undefined;
        try testing.expect(get(&c, .@"background-blur", @ptrCast(&cval)));
        try testing.expectEqual(42, cval);
    }
    {
        c.@"background-blur" = .@"macos-glass-regular";
        var cval: i16 = undefined;
        try testing.expect(get(&c, .@"background-blur", @ptrCast(&cval)));
        try testing.expectEqual(-1, cval);
    }
    {
        c.@"background-blur" = .@"macos-glass-clear";
        var cval: i16 = undefined;
        try testing.expect(get(&c, .@"background-blur", @ptrCast(&cval)));
        try testing.expectEqual(-2, cval);
    }
}

test "c_get: split-preserve-zoom" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c = try Config.default(alloc);
    defer c.deinit();

    var bits: c_uint = undefined;
    try testing.expect(get(&c, .@"split-preserve-zoom", @ptrCast(&bits)));
    try testing.expectEqual(@as(c_uint, 0), bits);

    c.@"split-preserve-zoom".navigation = true;
    try testing.expect(get(&c, .@"split-preserve-zoom", @ptrCast(&bits)));
    try testing.expectEqual(@as(c_uint, 1), bits);
}
