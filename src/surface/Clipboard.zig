//! Clipboard request policy, confirmation, ownership and protocol replies.
//! This synchronous adapter borrows Surface only for the duration of a call.
//! Queueing and scrolling remain Surface-owned services.
const Self = @This();
const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const Surface = @import("../Surface.zig");
const apprt = @import("../apprt.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const global = @import("../global.zig");
const input = @import("../input.zig");
const log = std.log.scoped(.clipboard);

surface: *Surface,
queue_io: *const fn (*Surface, termio.Message, termio.Termio.MutexState) void,
scroll_bottom: *const fn (*Surface) anyerror!void,
set_clipboard: *const fn (*Surface, apprt.Clipboard, []const apprt.ClipboardContent, bool) anyerror!void,
request_clipboard: *const fn (*Surface, apprt.Clipboard, apprt.ClipboardRequest) anyerror!apprt.ClipboardReadResult,

/// The payload for completing a clipboard request with
/// completeClipboardRequest.
pub const CompleteClipboard = struct {
    /// The representations the apprt could serve for the request's MIME
    /// types. These are immediately copied as needed so they only need
    /// to live for the duration of the completion call. Requesters that
    /// only carry text (paste, OSC 52) use the first text-like
    /// representation.
    contents: []const terminal.clipboard.Content = &.{},

    /// The listing of MIME types available on the clipboard, only
    /// gathered when the request asked for it.
    available: []const []const u8 = &.{},

    /// True if any clipboard confirmation prompt was already answered
    /// by the user, skipping further prompts:
    ///
    ///   - For "regular" pasting this means that unsafe pastes are
    ///     allowed. Unsafe data is defined as data that contains
    ///     newlines, though this definition may change later to detect
    ///     other scenarios.
    ///
    ///   - For OSC 52 and Kitty clipboard protocol reads and writes no
    ///     prompt is shown to the user when this is true.
    confirmed: bool = false,

    /// True if the user asked to remember their decision. This is only
    /// honored by request types that support session grants (Kitty
    /// clipboard protocol requests carrying a password).
    remember: bool = false,
};

/// Call this to complete a clipboard request sent to apprt. This should
/// only be called once for each request.
///
/// If `complete.confirmed` is false then this may return either an
/// UnsafePaste or UnauthorizedPaste error, depending on the type of
/// clipboard request. The request state remains alive in that case so
/// the apprt can run its confirmation flow.
pub fn completeClipboardRequest(
    ctx: Self,
    req: apprt.ClipboardRequest,
    complete: CompleteClipboard,
) !void {
    const self = ctx.surface;
    switch (req) {
        .paste => try ctx.completeClipboardPaste(
            clipboardTextContent(complete.contents) orelse "",
            complete.confirmed,
        ),

        .list => |clipboard| if (!try ctx.completeClipboardPasteEvent(
            clipboard,
            complete.available,
        )) {
            log.debug("mode 5522 paste event was not written", .{});
        },

        .osc_52_read => |clipboard| try ctx.completeClipboardReadOSC52(
            clipboardTextContent(complete.contents) orelse "",
            clipboard,
            complete.confirmed,
        ),

        .osc_52_write => |clipboard| {
            // The write API wants sentinel-terminated data; the write
            // text round-tripped through the apprt confirmation flow as
            // a plain representation.
            const data = try self.alloc.dupeZ(
                u8,
                clipboardTextContent(complete.contents) orelse "",
            );
            defer self.alloc.free(data);
            try ctx.set_clipboard(self, clipboard, &.{.{
                .mime = "text/plain",
                .data = data,
            }}, !complete.confirmed);
        },

        .kitty_read => |kitty| {
            // If we need confirmation we return an error without
            // consuming the request state; the apprt keeps it alive
            // for the confirmation flow. A session grant carried by
            // the request skips the prompt, and a request with no
            // data types is exempt from prompting entirely; see
            // readPromptExempt.
            if (self.config.clipboard_read == .ask and
                !complete.confirmed and
                !kitty.granted and
                !terminal.kitty.clipboard.readPromptExempt(kitty.mimes.len))
            {
                return error.UnauthorizedPaste;
            }

            // Past the confirmation check the request is consumed:
            // every path from here, including errors, must destroy it.
            defer kitty.destroy();

            // Record a session grant when the user asked to remember
            // their decision and the request carried a usable
            // password. The grants live with the terminal state on
            // the IO thread.
            if (complete.remember and kitty.pw.len > 0) {
                const pw = try self.alloc.dupe(u8, kitty.pw);
                ctx.queue_io(self, .{ .kitty_clipboard_grant_read = .{
                    .alloc = self.alloc,
                    .pw = pw,
                } }, .unlocked);
            }

            try ctx.completeKittyClipboardRead(
                kitty,
                complete.contents,
                complete.available,
            );
        },

        .kitty_write => |kitty| {
            // If we need confirmation we return an error without
            // consuming the request state; the apprt keeps it alive
            // for the confirmation flow. A session grant carried by
            // the request skips the prompt.
            if (self.config.clipboard_write == .ask and
                !complete.confirmed and
                !kitty.granted)
            {
                return error.UnauthorizedPaste;
            }

            // Past the confirmation check the request is consumed:
            // every path from here, including errors, must destroy it.
            defer kitty.destroy();

            // Record a session grant when the user asked to remember
            // their decision and the request carried a usable
            // password. The grants live with the terminal state on
            // the IO thread.
            if (complete.remember and kitty.pw.len > 0) {
                const pw = try self.alloc.dupe(u8, kitty.pw);
                ctx.queue_io(self, .{ .kitty_clipboard_grant_write = .{
                    .alloc = self.alloc,
                    .pw = pw,
                } }, .unlocked);
            }

            // Apply the committed representations carried by the
            // request itself; any contents echoed back by the apprt
            // are only what its confirmation prompt displayed. An
            // empty commit clears the clipboard, which the apprt
            // write API expresses as a single empty text entry.
            ctx.set_clipboard(
                self,
                kitty.location,
                if (kitty.contents.len > 0) kitty.contents else &.{.{
                    .mime = "text/plain",
                    .data = "",
                }},
                false,
            ) catch |err| {
                log.err("error setting clipboard err={}", .{err});
                try ctx.kittyClipboardStatus(
                    .write,
                    kitty.id,
                    kitty.terminator,
                    .EIO,
                );
                return;
            };

            try ctx.kittyClipboardStatus(
                .write,
                kitty.id,
                kitty.terminator,
                .DONE,
            );
        },
    }
}

/// The first text-like representation of the contents, if any.
fn clipboardTextContent(contents: []const terminal.clipboard.Content) ?[]const u8 {
    for (contents) |content| {
        if (terminal.clipboard.isTextMime(content.mime)) return content.data;
    }
    return null;
}

/// Deny an in-flight clipboard request. This consumes the request: for
/// request types whose protocol expects an answer, the denial reply is
/// written to the pty.
pub fn denyClipboardRequest(ctx: Self, req: apprt.ClipboardRequest) void {
    switch (req) {
        // A denied paste simply doesn't happen.
        .paste, .list => {},

        // OSC 52 has no error responses, but the client is waiting on
        // a reply, so a denied read is answered with empty contents.
        .osc_52_read => |clipboard| ctx.completeClipboardReadOSC52(
            "",
            clipboard,
            true,
        ) catch |err| {
            log.warn("error replying to OSC 52 clipboard read err={}", .{err});
        },

        // A denied write simply doesn't happen.
        .osc_52_write => {},

        // The Kitty clipboard protocol reports denial explicitly.
        .kitty_read => |kitty| {
            defer kitty.destroy();
            ctx.kittyClipboardStatus(
                .read,
                kitty.id,
                kitty.terminator,
                .EPERM,
            ) catch |err| {
                log.warn("error replying to kitty clipboard read err={}", .{err});
            };
        },

        .kitty_write => |kitty| {
            defer kitty.destroy();
            ctx.kittyClipboardStatus(
                .write,
                kitty.id,
                kitty.terminator,
                .EPERM,
            ) catch |err| {
                log.warn("error replying to kitty clipboard write err={}", .{err});
            };
        },
    }
}

/// This starts a clipboard request, with some basic validation. For example,
/// an OSC 52 request is not actually requested if OSC 52 is disabled.
///
/// The result reports whether the request was started; requests that
/// weren't started never complete. Callers own reacting to that, e.g.
/// performable paste keybinds pass through and Kitty clipboard reads
/// answer the program.
pub fn startClipboardRequest(
    ctx: Self,
    loc: apprt.Clipboard,
    req: apprt.ClipboardRequest,
) !apprt.ClipboardReadResult {
    const self = ctx.surface;
    const effective_req: apprt.ClipboardRequest = switch (req) {
        .paste => |clipboard| effective: {
            // Snapshot the mode before asking the apprt for clipboard data.
            // Event pastes request only a MIME listing, while ordinary
            // pastes request the text representation as before.
            self.render.state.mutex.lockUncancelable(global.io());
            const event = self.io.termio.terminal.modes.get(.kitty_paste_events);
            self.render.state.mutex.unlock(global.io());

            break :effective if (event)
                .{ .list = clipboard }
            else
                req;
        },
        else => req,
    };

    switch (effective_req) {
        .paste, .list => {}, // always allowed
        .osc_52_read => if (self.config.clipboard_read == .deny) {
            log.info(
                "application attempted to read clipboard, but 'clipboard-read' is set to deny",
                .{},
            );
            return .unsupported;
        },

        // The clipboard access policies were already applied by
        // kittyClipboardRead and kittyClipboardWrite, which own
        // replying on denial.
        .kitty_read, .kitty_write => {},

        // OSC 52 writes don't travel through this function; they go
        // straight to the apprt setClipboard API.
        .osc_52_write => unreachable,
    }

    return try ctx.request_clipboard(self, loc, effective_req);
}

pub fn completeClipboardPaste(
    ctx: Self,
    data: []const u8,
    allow_unsafe: bool,
) !void {
    const self = ctx.surface;
    if (data.len == 0) return;

    const encode_opts: input.paste.Options = encode_opts: {
        self.render.state.mutex.lockUncancelable(global.io());
        defer self.render.state.mutex.unlock(global.io());
        const opts: input.paste.Options = .fromTerminal(&self.io.termio.terminal);

        // If we have paste protection enabled, we detect unsafe pastes and return
        // an error. The error approach allows apprt to attempt to complete the paste
        // before falling back to requesting confirmation.
        //
        // We do not do this for bracketed pastes because bracketed pastes are
        // by definition safe since they're framed.
        const unsafe = unsafe: {
            // If we've disabled paste protection then we always allow the paste.
            if (!self.config.clipboard_paste_protection) break :unsafe false;

            // If we're allowed to paste unsafe data then we always allow the paste.
            // This is set during confirmation usually.
            if (allow_unsafe) break :unsafe false;

            if (opts.bracketed) {
                // If we're bracketed and the paste contains and ending
                // bracket then something naughty might be going on and we
                // never trust it.
                if (std.mem.indexOf(u8, data, "\x1B[201~") != null) break :unsafe true;

                // If we are bracketed and configured to trust that then the
                // paste is not unsafe.
                if (self.config.clipboard_paste_bracketed_safe) break :unsafe false;
            }

            break :unsafe !input.paste.isSafe(data);
        };

        if (unsafe) {
            log.info("potentially unsafe paste detected, rejecting until confirmation", .{});
            return error.UnsafePaste;
        }

        // With the lock held, we must scroll to the bottom.
        // We always scroll to the bottom for these inputs.
        ctx.scroll_bottom(self) catch |err| {
            log.warn("error scrolling to bottom err={}", .{err});
        };

        break :encode_opts opts;
    };

    // Encode the data. In most cases this doesn't require any
    // copies, so we optimize for that case.
    var data_duped: ?[]u8 = null;
    const vecs = input.paste.encode(data, encode_opts) catch |err| switch (err) {
        error.MutableRequired => vecs: {
            const buf: []u8 = try self.alloc.dupe(u8, data);
            errdefer self.alloc.free(buf);
            data_duped = buf;
            break :vecs input.paste.encode(buf, encode_opts);
        },
    };
    defer if (data_duped) |v| {
        // This code path means the data did require a copy and mutation.
        // We must free it.
        self.alloc.free(v);
    };

    for (vecs) |vec| if (vec.len > 0) {
        ctx.queue_io(self, try termio.Message.writeReq(
            self.alloc,
            vec,
        ), .unlocked);
    };
}

/// Send a Kitty clipboard-protocol paste event when mode 5522 is enabled.
/// The event only lists the available MIME types; it does not read any of
/// their data. The shared terminal paste implementation generates and records
/// the one-time password used by the program's follow-up OSC 5522 read.
fn completeClipboardPasteEvent(
    ctx: Self,
    clipboard: apprt.Clipboard,
    available: []const []const u8,
) !bool {
    const self = ctx.surface;
    if (self.readonly) return false;

    const kitty_clipboard = terminal.kitty.clipboard;
    const location: terminal.clipboard.Location = switch (clipboard) {
        .standard => .standard,
        .selection => .selection,
        .primary => .primary,
    };

    // The protocol implementation caps listings at this size too. Cap here
    // so the temporary Content array stays on the stack.
    var contents_buf: [kitty_clipboard.max_listing_mimes]terminal.clipboard.Content = undefined;
    const contents_len = @min(available.len, contents_buf.len);
    for (available[0..contents_len], contents_buf[0..contents_len]) |mime, *content| {
        content.* = .{ .mime = mime, .data = "" };
    }

    var aw: std.Io.Writer.Allocating = .init(self.alloc);
    defer aw.deinit();

    self.render.state.mutex.lockUncancelable(global.io());
    defer self.render.state.mutex.unlock(global.io());

    const pasted = try terminal.paste.paste(.{
        .terminal = &self.io.termio.terminal,
        .alloc = self.alloc,
        .writer = &aw.writer,
        .kitty_clipboard = .{
            .grants = &self.io.termio.terminal_stream.handler.kitty_clipboard_grants,
            .io = global.io(),
        },
    }, .{
        .source = .{ .clipboard = location },
        .contents = .{ .memory = contents_buf[0..contents_len] },
        // A paste event discloses no clipboard data, so unsafe-text
        // confirmation does not apply. If mode 5522 is reset, the empty
        // stand-in representations cause the shared helper to write nothing.
        .allow_unsafe = true,
    });
    if (!pasted) return false;

    ctx.queue_io(self, .{ .write_alloc = .{
        .alloc = self.alloc,
        .data = try aw.toOwnedSlice(),
    } }, .locked);
    return true;
}

fn completeClipboardReadOSC52(
    ctx: Self,
    data: []const u8,
    clipboard_type: apprt.Clipboard,
    confirmed: bool,
) !void {
    const self = ctx.surface;
    // We should never get here if clipboard-read is set to deny
    assert(self.config.clipboard_read != .deny);

    // If clipboard-read is set to ask and we haven't confirmed with the user,
    // do that now
    if (self.config.clipboard_read == .ask and !confirmed) {
        return error.UnauthorizedPaste;
    }

    // Even if the clipboard data is empty we reply, since presumably
    // the client app is expecting a reply. We first allocate our buffer.
    // This must hold the base64 encoded data PLUS the OSC code surrounding it.
    const enc = std.base64.standard.Encoder;
    const size = enc.calcSize(data.len);
    const buf = try self.alloc.alloc(u8, size + 9); // const for OSC
    errdefer self.alloc.free(buf);

    const kind: u8 = switch (clipboard_type) {
        .standard => 'c',
        .selection => 's',
        .primary => 'p',
    };

    // Wrap our data with the OSC code
    const prefix = try std.fmt.bufPrint(buf, "\x1b]52;{c};", .{kind});
    assert(prefix.len == 7);
    buf[buf.len - 2] = '\x1b';
    buf[buf.len - 1] = '\\';

    // Do the base64 encoding
    const encoded = enc.encode(buf[prefix.len..], data);
    assert(encoded.len == size);

    ctx.queue_io(self, .{ .write_alloc = .{
        .alloc = self.alloc,
        .data = buf,
    } }, .unlocked);
}

/// Handle a Kitty clipboard protocol (OSC 5522) read request forwarded
/// by the IO thread. This takes ownership of the request state.
pub fn kittyClipboardRead(
    ctx: Self,
    req: *apprt.ClipboardRequest.KittyRead,
) !void {
    const self = ctx.surface;
    // A read denied by policy answers EPERM so clients degrade
    // gracefully instead of waiting on a response that never comes.
    if (self.config.clipboard_read == .deny) {
        defer req.destroy();
        log.info("application attempted to read clipboard, but 'clipboard-read' is set to deny", .{});
        try ctx.kittyClipboardStatus(.read, req.id, req.terminator, .EPERM);
        return;
    }

    const result = ctx.startClipboardRequest(
        req.location,
        .{ .kitty_read = req },
    ) catch |err| {
        defer req.destroy();
        ctx.kittyClipboardStatus(.read, req.id, req.terminator, .EIO) catch {};
        return err;
    };

    switch (result) {
        // The request completes asynchronously.
        .started => {},

        // The clipboard has nothing we can serve, which is a
        // successful read that serves no representations. This never
        // prompts even under an ask policy since there are no contents
        // to disclose.
        .unavailable => {
            defer req.destroy();
            try ctx.completeKittyClipboardRead(req, &.{}, &.{});
        },

        // The apprt can't serve this clipboard at all, e.g. an
        // unsupported primary selection.
        .unsupported => {
            defer req.destroy();
            try ctx.kittyClipboardStatus(.read, req.id, req.terminator, .ENOSYS);
        },
    }
}

/// Handle a committed Kitty clipboard protocol (OSC 5522) write
/// transaction forwarded by the IO thread. This takes ownership of the
/// request state.
pub fn kittyClipboardWrite(
    ctx: Self,
    req: *apprt.ClipboardRequest.KittyWrite,
) !void {
    const self = ctx.surface;
    // A write denied by policy answers EPERM so clients degrade
    // gracefully instead of waiting on a response that never comes.
    // The IO thread already fails transactions that begin under a
    // deny policy, but the policy may have changed mid-transaction.
    if (self.config.clipboard_write == .deny) {
        defer req.destroy();
        log.info("application attempted to write clipboard, but 'clipboard-write' is set to deny", .{});
        try ctx.kittyClipboardStatus(.write, req.id, req.terminator, .EPERM);
        return;
    }

    const result = ctx.startClipboardRequest(
        req.location,
        .{ .kitty_write = req },
    ) catch |err| {
        defer req.destroy();
        ctx.kittyClipboardStatus(.write, req.id, req.terminator, .EIO) catch {};
        return err;
    };

    switch (result) {
        // The request completes asynchronously.
        .started => {},

        // The apprt can't write this clipboard at all, e.g. an
        // unsupported primary selection. Writes carry their own
        // contents so there is no meaningful unavailable state; treat
        // it the same.
        .unavailable, .unsupported => {
            defer req.destroy();
            try ctx.kittyClipboardStatus(.write, req.id, req.terminator, .ENOSYS);
        },
    }
}

/// Reply to a Kitty clipboard request with a single status packet.
fn kittyClipboardStatus(
    ctx: Self,
    op: terminal.kitty.clipboard.Operation,
    id: []const u8,
    terminator: terminal.osc.Terminator,
    status: terminal.kitty.clipboard.Status,
) error{ OutOfMemory, WriteFailed }!void {
    const self = ctx.surface;
    var aw: std.Io.Writer.Allocating = .init(self.alloc);
    defer aw.deinit();
    try (terminal.kitty.clipboard.Response{
        .op = op,
        .status = status,
        .id = id,
        .terminator = terminator,
    }).encode(&aw.writer);

    ctx.queue_io(self, .{ .write_alloc = .{
        .alloc = self.alloc,
        .data = try aw.toOwnedSlice(),
    } }, .unlocked);
}

/// Complete a Kitty clipboard protocol read with the clipboard
/// contents.
fn completeKittyClipboardRead(
    ctx: Self,
    req: *const apprt.ClipboardRequest.KittyRead,
    contents: []const terminal.clipboard.Content,
    available: []const []const u8,
) !void {
    const self = ctx.surface;
    const kitty_clipboard = terminal.kitty.clipboard;

    // Serve the requested representations in request order under their
    // requested names. Text-like MIME aliases all match the canonical
    // text representation, since that is the only name the apprt
    // serves text under. Requested types without a representation are
    // simply never served, which is how the protocol communicates an
    // unavailable representation.
    var contents_buf: [kitty_clipboard.max_read_mimes]terminal.clipboard.Content = undefined;
    var contents_len: usize = 0;
    for (req.mimes) |mime| {
        const data: []const u8 = data: {
            for (contents) |content| {
                if (std.mem.eql(u8, content.mime, mime)) break :data content.data;
                if (terminal.clipboard.isTextMime(mime) and
                    terminal.clipboard.isTextMime(content.mime))
                {
                    break :data content.data;
                }
            }

            continue;
        };

        contents_buf[contents_len] = .{ .mime = mime, .data = data };
        contents_len += 1;
    }

    // Encode the full success sequence: the OK packet, the targets
    // listing if it was requested, DATA chunks for each served
    // representation, and the final DONE packet.
    var aw: std.Io.Writer.Allocating = .init(self.alloc);
    defer aw.deinit();
    try (kitty_clipboard.ReadSuccess{
        .primary = req.location == .primary,
        .id = req.id,
        .list = req.list,
        .available = available,
        .contents = contents_buf[0..contents_len],
        .terminator = req.terminator,
    }).encode(&aw.writer);

    ctx.queue_io(self, .{ .write_alloc = .{
        .alloc = self.alloc,
        .data = try aw.toOwnedSlice(),
    } }, .unlocked);
}

const TestHost = struct {
    fn context(surface: *Surface) Self {
        return .{
            .surface = surface,
            .queue_io = queue,
            .scroll_bottom = scroll,
            .set_clipboard = set,
            .request_clipboard = requestClipboard,
        };
    }

    fn set(_: *Surface, _: apprt.Clipboard, _: []const apprt.ClipboardContent, _: bool) !void {
        unreachable;
    }

    fn requestClipboard(_: *Surface, _: apprt.Clipboard, _: apprt.ClipboardRequest) !apprt.ClipboardReadResult {
        unreachable;
    }

    fn queue(surface: *Surface, message: termio.Message, _: termio.Termio.MutexState) void {
        surface.id += 1;
        message.deinit();
    }

    fn scroll(_: *Surface) !void {
        unreachable;
    }

    fn readRequest() !*apprt.ClipboardRequest.KittyRead {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer arena.deinit();
        const request = try arena.allocator().create(apprt.ClipboardRequest.KittyRead);
        request.* = .{
            .arena = arena,
            .location = .standard,
            .mimes = &.{"text/plain"},
            .list = false,
            .id = "test",
            .pw = "",
            .name = "test",
            .granted = false,
            .terminator = .st,
        };
        return request;
    }
};

test "clipboard confirmation retains request until completion" {
    const testing = std.testing;
    const surface = try testing.allocator.create(Surface);
    defer testing.allocator.destroy(surface);
    surface.alloc = testing.allocator;
    surface.config.clipboard_read = .ask;
    surface.id = 0;
    const ctx = TestHost.context(surface);
    const request = try TestHost.readRequest();
    try testing.expectError(error.UnauthorizedPaste, ctx.completeClipboardRequest(.{ .kitty_read = request }, .{}));
    try testing.expectEqualStrings("text/plain", request.mimes[0]);
    try testing.expectEqual(@as(u64, 0), surface.id);
    // Completion consumes the arena and the queued buffer exactly once.
    try ctx.completeClipboardRequest(.{ .kitty_read = request }, .{
        .confirmed = true,
        .contents = &.{.{ .mime = "text/plain", .data = "confirmed" }},
    });
    try testing.expectEqual(@as(u64, 1), surface.id);
}

test "clipboard denial consumes kitty request and queues a reply" {
    const testing = std.testing;
    const surface = try testing.allocator.create(Surface);
    defer testing.allocator.destroy(surface);
    surface.alloc = testing.allocator;
    surface.id = 0;
    const ctx = TestHost.context(surface);
    ctx.denyClipboardRequest(.{ .kitty_read = try TestHost.readRequest() });
    try testing.expectEqual(@as(u64, 1), surface.id);
}

test "clipboard denied OSC52 read does not access runtime" {
    const testing = std.testing;
    const surface = try testing.allocator.create(Surface);
    defer testing.allocator.destroy(surface);
    surface.config.clipboard_read = .deny;
    const ctx = TestHost.context(surface);
    try testing.expectEqual(apprt.ClipboardReadResult.unsupported, try ctx.startClipboardRequest(.standard, .{ .osc_52_read = .standard }));
}
