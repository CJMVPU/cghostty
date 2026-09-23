//! CoreText owns process font services; terminal faces own their references.
const std = @import("std");
pub const Library = struct {
    pub const InitError = error{};
    pub fn init(_: std.mem.Allocator) InitError!Library {
        return .{};
    }
    pub fn deinit(_: *Library) void {}
};
