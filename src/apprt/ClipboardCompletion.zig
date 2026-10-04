//! Borrowed C clipboard payload conversion and the asynchronous request handoff.
//! Kept separate from embedded exports so allocation failures can be tested
//! with the no-window runtime and the real clipboard protocol handler.
const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../apprt.zig");
const terminal = @import("../terminal/main.zig");
const CoreSurface = @import("../Surface.zig");
const log = std.log.scoped(.embedded_window);

pub const Content = extern struct {
    mime: [*:0]const u8,
    data: [*]const u8,
    len: usize,
};

// ghostty_clipboard_complete_s
//
// The payload for completing a clipboard read request. See
// Surface.CompleteClipboard for the field documentation.
pub const Complete = extern struct {
    contents: ?[*]const Content,
    contents_len: usize,
    available: ?[*]const [*:0]const u8,
    available_len: usize,
    confirmed: bool,
    remember: bool,
};

// ghostty_clipboard_confirm_s
//
// The payload of a clipboard read confirmation request: the
// would-be completion contents plus the information shown in the
// permission prompt. All memory is borrowed for the duration of
// the confirm_read_clipboard callback.
pub const Confirm = extern struct {
    contents: ?[*]const Content,
    contents_len: usize,
    available: ?[*]const [*:0]const u8,
    available_len: usize,

    /// The human friendly name of the requesting program for the
    /// prompt, null when the protocol doesn't carry one.
    name: ?[*:0]const u8,

    /// True when the user's decision may be remembered as a
    /// session grant, reported back through the completion's
    /// remember field.
    can_remember: bool,
};

pub fn completeRequest(
    self: anytype,
    complete: *const Complete,
    state: *apprt.ClipboardRequest,
) void {
    const alloc = self.app.core_app.alloc;

    // Convert the C representations to the core types. Everything
    // remains borrowed from the caller for the duration of the call.
    var stack = std.heap.stackFallback(1024, alloc);
    const conv_alloc = stack.get();

    const raw_contents: []const Content =
        if (complete.contents) |v| v[0..complete.contents_len] else &.{};
    const contents = conv_alloc.alloc(
        terminal.clipboard.Content,
        raw_contents.len,
    ) catch |err| {
        log.warn("clipboard completion conversion rejected err={}", .{err});
        // Conversion failed before the core could consume the request. Denial
        // releases the Kitty arena and answers waiting protocol clients.
        self.core_surface.denyClipboardRequest(state.*);
        alloc.destroy(state);
        return;
    };
    defer conv_alloc.free(contents);
    for (raw_contents, contents) |raw, *content| content.* = .{
        .mime = std.mem.sliceTo(raw.mime, 0),
        .data = raw.data[0..raw.len],
    };

    const raw_available: []const [*:0]const u8 =
        if (complete.available) |v| v[0..complete.available_len] else &.{};
    const available = conv_alloc.alloc(
        []const u8,
        raw_available.len,
    ) catch |err| {
        log.warn("clipboard completion conversion rejected err={}", .{err});
        // Conversion failed before the core could consume the request. Denial
        // releases the Kitty arena and answers waiting protocol clients.
        self.core_surface.denyClipboardRequest(state.*);
        alloc.destroy(state);
        return;
    };
    defer conv_alloc.free(available);
    for (raw_available, available) |raw, *mime| {
        mime.* = std.mem.sliceTo(raw, 0);
    }

    // Attempt to complete the request, but we may request
    // confirmation.
    self.core_surface.completeClipboardRequest(state.*, .{
        .contents = contents,
        .available = available,
        .confirmed = complete.confirmed,
        .remember = complete.remember,
    }) catch |err| switch (err) {
        error.UnsafePaste,
        error.UnauthorizedPaste,
        => {
            // Session grant information for the permission prompt,
            // carried only by Kitty clipboard protocol requests.
            const name: ?[*:0]const u8, const can_remember: bool = switch (state.*) {
                inline .kitty_read, .kitty_write => |kitty| .{
                    if (kitty.name.len > 0) kitty.name.ptr else null,
                    kitty.pw.len > 0,
                },
                else => .{ null, false },
            };

            self.app.opts.confirm_read_clipboard(
                self.userdata,
                &.{
                    .contents = complete.contents,
                    .contents_len = complete.contents_len,
                    .available = complete.available,
                    .available_len = complete.available_len,
                    .name = name,
                    .can_remember = can_remember,
                },
                state,
                state.*,
            );

            return;
        },

        else => log.err("error completing clipboard request err={}", .{err}),
    };

    // We don't defer this because the clipboard confirmation route
    // preserves the clipboard request.
    alloc.destroy(state);
}

const ClipboardFailureTest = struct {
    const Clipboard = @import("../surface/Clipboard.zig");
    const Core = struct {
        alloc: Allocator,
    };
    const AppState = struct {
        core_app: *Core,
        opts: struct {
            confirm_read_clipboard: *const fn (?*anyopaque, *const Confirm, *apprt.ClipboardRequest, apprt.ClipboardRequestType) callconv(.c) void = confirm,
        } = .{},
    };
    const Host = struct {
        app: *AppState,
        core_surface: Clipboard,
        userdata: ?*anyopaque = null,
    };

    fn confirm(_: ?*anyopaque, _: *const Confirm, _: *apprt.ClipboardRequest, _: apprt.ClipboardRequestType) callconv(.c) void {
        unreachable;
    }

    fn queue(surface: *CoreSurface, message: @import("../termio.zig").Message, _: @import("../termio.zig").Termio.MutexState) void {
        defer message.deinit();
        if (surface.id == 0) {
            std.testing.expect(std.mem.indexOf(u8, message.write_alloc.data, ":status=EPERM:id=allocation-test") != null) catch @panic("missing clipboard failure reply");
        } else {
            std.testing.expect(std.mem.startsWith(u8, message.write_alloc.data, "\x1b]52;c;")) catch @panic("subsequent clipboard request failed");
        }
        surface.id += 1;
    }

    fn scroll(_: *CoreSurface) !void {
        unreachable;
    }
    fn set(_: *CoreSurface, _: apprt.Clipboard, _: []const apprt.ClipboardContent, _: bool) !void {
        unreachable;
    }
    fn request(_: *CoreSurface, _: apprt.Clipboard, _: apprt.ClipboardRequest) !apprt.ClipboardReadResult {
        unreachable;
    }

    fn run(comptime write: bool, allocation: usize) !void {
        const t = std.testing;
        var counter = t.FailingAllocator.init(t.allocator, .{});
        const alloc = counter.allocator();
        const surface = try t.allocator.create(CoreSurface);
        defer t.allocator.destroy(surface);
        surface.alloc = t.allocator; // Reply allocation can still succeed.
        surface.id = 0;
        var core: Core = .{ .alloc = alloc };
        var app: AppState = .{ .core_app = &core };
        var host: Host = .{
            .app = &app,
            .core_surface = .{
                .surface = surface,
                .queue_io = queue,
                .scroll_bottom = scroll,
                .set_clipboard = set,
                .request_clipboard = request,
            },
        };

        var arena = std.heap.ArenaAllocator.init(alloc);
        const arena_alloc = arena.allocator();
        const state = try alloc.create(apprt.ClipboardRequest);
        if (write) {
            const committed = try arena_alloc.alloc(apprt.ClipboardContent, 64);
            @memset(committed, .{ .mime = "text/plain", .data = "x" });
            const kitty = try arena_alloc.create(apprt.ClipboardRequest.KittyWrite);
            kitty.* = .{
                .arena = arena,
                .location = .standard,
                .contents = committed,
                .id = "allocation-test",
                .pw = "",
                .name = "",
                .granted = false,
                .terminator = .st,
            };
            state.* = .{ .kitty_write = kitty };
        } else {
            const kitty = try arena_alloc.create(apprt.ClipboardRequest.KittyRead);
            kitty.* = .{
                .arena = arena,
                .location = .standard,
                .mimes = &.{"text/plain"},
                .list = true,
                .id = "allocation-test",
                .pw = "",
                .name = "",
                .granted = false,
                .terminator = .st,
            };
            state.* = .{ .kitty_read = kitty };
        }
        // Keep the failing regression leak-free while exercising the old path.
        // A reply means the real clipboard handler consumed this arena.
        defer if (surface.id == 0) arena.deinit();

        const contents = [_]Content{.{ .mime = "text/plain", .data = "x", .len = 1 }} ** 64;
        const available = [_][*:0]const u8{"text/plain"} ** 65;
        counter.fail_index = counter.alloc_index + allocation;
        completeRequest(&host, &.{
            .contents = &contents,
            .contents_len = contents.len,
            .available = &available,
            .available_len = available.len,
            .confirmed = true,
            .remember = false,
        }, state);
        try t.expect(counter.has_induced_failure);
        try t.expectEqual(@as(u64, 1), surface.id);
        try t.expectEqual(counter.allocated_bytes, counter.freed_bytes);

        // Recovering allocation capacity allows the next request to complete.
        counter.fail_index = std.math.maxInt(usize);
        surface.config.clipboard_read = .allow;
        const next = try alloc.create(apprt.ClipboardRequest);
        next.* = .{ .osc_52_read = .standard };
        completeRequest(&host, &.{
            .contents = &contents,
            .contents_len = contents.len,
            .available = &available,
            .available_len = available.len,
            .confirmed = true,
            .remember = false,
        }, next);
        try t.expectEqual(@as(u64, 2), surface.id);
        try t.expectEqual(counter.allocated_bytes, counter.freed_bytes);
    }
};

test "clipboard conversion failure consumes read and write requests and replies once" {
    for (0..2) |allocation| {
        try ClipboardFailureTest.run(false, allocation);
        try ClipboardFailureTest.run(true, allocation);
    }
}
