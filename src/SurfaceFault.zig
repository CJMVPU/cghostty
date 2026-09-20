//! A terminal IO failure delivered by value to the app thread. No allocations,
//! borrowed thread data, or native presentation objects cross the mailbox.
const SurfaceFault = @This();
const std = @import("std");
const terminal = @import("terminal/main.zig");
const lib = @import("lib/main.zig");

kind: Kind,
err: anyerror,

pub const Kind = enum(c_int) {
    pty_unavailable,
    input_failed,
    io_failed,

    test "ghostty.h SurfaceFault.Kind" {
        try lib.checkGhosttyHEnum(Kind, "GHOSTTY_SURFACE_FAULT_");
    }
};

pub const C = extern struct {
    kind: Kind,
    error_code: [*:0]const u8,
};

pub fn init(err: anyerror) SurfaceFault {
    return .{
        .kind = switch (err) {
            error.OpenptyFailed => .pty_unavailable,
            error.InputNotFound, error.InputFailed => .input_failed,
            else => .io_failed,
        },
        .err = err,
    };
}

pub fn cval(self: SurfaceFault) C {
    // Error names have static lifetime, independent of the thread or this value.
    // The native adapter still copies the code when accepting the callback.
    return .{ .kind = self.kind, .error_code = @errorName(self.err).ptr };
}

/// Surface-owned fallback when the native runtime cannot display the fault.
/// The caller must hold the renderer state lock and request a render afterwards.
pub fn renderFallback(self: SurfaceFault, t: *terminal.Terminal) !void {
    t.modes.set(.cursor_visible, false);
    t.eraseDisplay(.complete, false);
    t.setCursorPos(1, 1);
    try t.setAttribute(.{ .unset = {} });
    try t.printString("Terminal IO failed: ");
    try t.printString(@errorName(self.err));
    try t.printString("\r\n\r\n");
    try t.printString(switch (self.kind) {
        .pty_unavailable => "No terminal devices are available. Close unused terminal sessions and try again.",
        .input_failed => "A configured input file could not be opened, read, or sent to the terminal. Check the input setting and file permissions.",
        .io_failed => "The terminal IO could not start or continue. Check available system resources and the error code above.",
    });
    try t.printString("\r\n\r\nClose this terminal and open a new one after correcting the problem.");
}

test "SurfaceFault classification and stable C error code" {
    const testing = std.testing;
    try testing.expectEqual(Kind.pty_unavailable, init(error.OpenptyFailed).kind);
    try testing.expectEqual(Kind.input_failed, init(error.InputNotFound).kind);
    try testing.expectEqual(Kind.input_failed, init(error.InputFailed).kind);
    const value = init(error.OutOfMemory).cval();
    try testing.expectEqual(Kind.io_failed, value.kind);
    try testing.expectEqualStrings("OutOfMemory", std.mem.span(value.error_code));
}

test "SurfaceFault fallback replaces screen and hides cursor" {
    const testing = std.testing;
    inline for (.{ error.OpenptyFailed, error.InputNotFound, error.OutOfMemory }) |err| {
        var t = try terminal.Terminal.init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
        defer t.deinit(testing.allocator);
        try t.printString("OLD CONTENT");
        try init(err).renderFallback(&t);
        const text = try t.plainString(testing.allocator);
        defer testing.allocator.free(text);
        try testing.expect(std.mem.indexOf(u8, text, "OLD CONTENT") == null);
        try testing.expect(std.mem.indexOf(u8, text, @errorName(err)) != null);
        try testing.expect(std.mem.indexOf(u8, text, "Close this terminal") != null);
        try testing.expect(!t.modes.get(.cursor_visible));
    }
}
