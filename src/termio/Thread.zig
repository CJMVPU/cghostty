//! Represents the "writer" thread for terminal IO. The reader side is
//! handled by the Termio struct itself and dependent on the underlying
//! implementation (i.e. if its a pty, manual, etc.).
//!
//! The writer thread does handle writing bytes to the pty but also handles
//! different events such as starting synchronized output, changing some
//! modes (like linefeed), etc. The goal is to offload as much from the
//! reader thread as possible since it is the hot path in parsing VT
//! sequences and updating terminal state.
//!
//! This thread state can only be used by one thread at a time.
pub const Thread = @This();

const std = @import("std");
const SurfaceFault = @import("../SurfaceFault.zig");
const global = @import("../global.zig");
const xev = global.xev;
const internal_os = @import("../os/main.zig");
const termio = @import("../termio.zig");
const renderer = @import("../renderer.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.io_thread);

/// This stores the information that is coalesced.
const Coalesce = struct {
    /// The number of milliseconds to coalesce certain messages like resize for.
    /// Not all message types are coalesced.
    const min_ms = 25;

    resize: ?renderer.Size = null,
};

/// The number of milliseconds before we reset the synchronized output flag
/// if the running program hasn't already.
const sync_reset_ms = 1000;

/// The number of milliseconds between each movement during selection scrolling.
const selection_scroll_ms = 15;

/// Allocator used for some state
alloc: std.mem.Allocator,

/// The main event loop for the thread. The user data of this loop
/// is always the allocator used to create the loop. This is a convenience
/// so that users of the loop always have an allocator.
loop: xev.Loop,

/// The completion to use for the wakeup async handle that is present
/// on the termio.Writer.
wakeup_c: xev.Completion = .{},

/// This can be used to stop the thread on the next loop iteration.
stop: xev.Async,
stop_c: xev.Completion = .{},

/// This is used for timer-based selection scrolling.
scroll: xev.Timer,
scroll_c: xev.Completion = .{},
scroll_active: bool = false,

/// This is used to coalesce resize events.
coalesce: xev.Timer,
coalesce_c: xev.Completion = .{},
coalesce_cancel_c: xev.Completion = .{},
coalesce_data: Coalesce = .{},

/// This timer is used to reset synchronized output modes so that
/// the terminal doesn't freeze with a bad actor.
sync_reset: xev.Timer,
sync_reset_c: xev.Completion = .{},
sync_reset_cancel_c: xev.Completion = .{},

flags: packed struct {
    /// This is set to true only when an abnormal exit is detected. It
    /// tells our mailbox system to drain and ignore all messages.
    drain: bool = false,

    /// True if linefeed mode is enabled. This is duplicated here so that the
    /// write thread doesn't need to grab a lock to check this on every write.
    linefeed_mode: bool = false,
} = .{},

/// Initialize the thread. This does not START the thread. This only sets
/// up all the internal state necessary prior to starting the thread. It
/// is up to the caller to start the thread with the threadMain entrypoint.
pub fn init(
    alloc: Allocator,
) !Thread {
    // Create our event loop.
    var loop = try xev.Loop.init(.{});
    errdefer loop.deinit();

    // This async handle is used to stop the loop and force the thread to end.
    var stop_h = try xev.Async.init();
    errdefer stop_h.deinit();

    // This timer is used for selection scrolling.
    var scroll_h = try xev.Timer.init();
    errdefer scroll_h.deinit();

    // This timer is used to coalesce resize events.
    var coalesce_h = try xev.Timer.init();
    errdefer coalesce_h.deinit();

    // This timer is used to reset synchronized output modes.
    var sync_reset_h = try xev.Timer.init();
    errdefer sync_reset_h.deinit();

    return Thread{
        .alloc = alloc,
        .loop = loop,
        .stop = stop_h,
        .scroll = scroll_h,
        .coalesce = coalesce_h,
        .sync_reset = sync_reset_h,
    };
}

/// Clean up the thread. This is only safe to call once the thread
/// completes executing; the caller must join prior to this.
pub fn deinit(self: *Thread) void {
    self.scroll.deinit();
    self.coalesce.deinit();
    self.sync_reset.deinit();
    self.stop.deinit();
    self.loop.deinit();
}

/// The main entrypoint for the thread.
pub fn threadMain(self: *Thread, io: *termio.Termio) void {
    defer io.mailbox.close();
    // Call child function so we can use errors...
    self.threadMain_(io) catch |err| {
        log.warn("error in io thread err={}", .{err});

        // Presentation belongs to Surface/native UI. This payload owns no
        // resources and is safe to discard if the surface closes before delivery.
        _ = io.surface_mailbox.push(.{
            .surface_fault = SurfaceFault.init(err),
        }, .{ .forever = {} });
    };

    // threadMain_ owns stack-backed backend completions. After it returns,
    // never run that loop again: startup can fail after registering process,
    // timer, and write callbacks, and their data has already been cleaned up.
    // Use a fresh loop containing only mailbox disposal and the stop signal.
    if (!self.loop.stopped()) {
        const drain_loop = xev.Loop.init(.{}) catch |err| {
            log.err("failed to create IO drain loop err={}", .{err});
            return;
        };
        self.loop.deinit();
        self.loop = drain_loop;
        self.flags.drain = true;
        self.wakeup_c = .{};
        self.stop_c = .{};
        var cb: CallbackData = .{ .self = self, .io = io };
        io.mailbox.spsc.wakeup.wait(&self.loop, &self.wakeup_c, CallbackData, &cb, wakeupCallback);
        self.stop.wait(&self.loop, &self.stop_c, CallbackData, &cb, stopCallback);
        // Requests can predate wakeup registration. Dispose them before waiting.
        self.drainMailbox(&cb) catch unreachable;
        self.loop.run(.until_done) catch |err| {
            log.err("failed to run IO drain loop err={}", .{err});
        };
    }
}

fn threadMain_(self: *Thread, io: *termio.Termio) !void {
    defer log.debug("IO thread exited", .{});

    // Right now, on Darwin, `std.Thread.setName` can only name the current
    // thread, and we have no way to get the current thread from within it,
    // so instead we use this code to name the thread instead.
    internal_os.macos.pthread_setname_np(&"io".*);

    // Get the mailbox. This must be an SPSC mailbox for threading.
    const mailbox = switch (io.mailbox) {
        .spsc => |*v| v,
        // else => return error.TermioUnsupportedMailbox,
    };

    // This is the data sent to xev callbacks. We want a pointer to both
    // ourselves and the thread data so we can thread that through (pun intended).
    var cb: CallbackData = .{ .self = self, .io = io };

    // Run our thread start/end callbacks. This allows the implementation
    // to hook into the event loop as needed. The thread data is created
    // on the stack here so that it has a stable pointer throughout the
    // lifetime of the thread.
    try io.threadEnter(self, &cb.data);
    defer cb.data.deinit();
    defer io.threadExit(&cb.data);
    // The reader may finish parsing a buffered DSR after the loop stops.
    // Cancel its sends before threadExit joins it, including error unwinds.
    defer io.mailbox.close();

    // Start the async handlers.
    mailbox.wakeup.wait(&self.loop, &self.wakeup_c, CallbackData, &cb, wakeupCallback);
    self.stop.wait(&self.loop, &self.stop_c, CallbackData, &cb, stopCallback);

    // Run
    log.debug("starting IO thread", .{});
    defer log.debug("starting IO thread shutdown", .{});
    try self.loop.run(.until_done);
}

/// This is the data passed to xev callbacks on the thread.
const CallbackData = struct {
    self: *Thread,
    io: *termio.Termio,
    data: termio.Termio.ThreadData = undefined,
};

/// Drain the mailbox, handling all the messages in our terminal implementation.
fn drainMailbox(
    self: *Thread,
    cb: *CallbackData,
) !void {
    // We assert when starting the thread that this is the state
    const mailbox = cb.io.mailbox.spsc.queue;
    const io = cb.io;

    // If we're draining, we just drain the mailbox and return.
    if (self.flags.drain) {
        while (mailbox.pop(global.io())) |msg| msg.deinit();
        return;
    }

    // pop releases the queue lock before handling each message. A failed
    // message must not leave the rest waiting for an already-coalesced wakeup.
    var redraw: bool = false;
    var first_error: ?anyerror = null;
    while (mailbox.pop(global.io())) |message| {
        redraw = true;
        log.debug("mailbox message={s}", .{@tagName(message)});
        self.handleMailboxMessage(cb, message) catch |err| {
            if (first_error == null) first_error = err;
        };
    }

    // Notify once for the batch, including changes processed after a failure.
    if (redraw) io.renderer_wakeup.notify() catch |err| {
        if (first_error == null) first_error = err;
    };
    if (first_error) |err| return err;
}

fn handleMailboxMessage(
    self: *Thread,
    cb: *CallbackData,
    message: termio.Message,
) !void {
    const io = cb.io;
    const data = &cb.data;
    switch (message) {
        .color_scheme_report => |v| try io.colorSchemeReport(data, v.force),
        .visibility_report => |v| try io.visibilityReport(
            data,
            v.visible,
            v.force,
        ),
        .crash => @panic("crash request, crashing intentionally"),
        .change_config => |config| {
            defer config.alloc.destroy(config.ptr);
            try io.changeConfig(config.ptr);
        },
        .resize => |v| self.handleResize(cb, v),
        .size_report => |v| try io.sizeReport(data, v),
        .clear_screen => |v| try io.clearScreen(data, v.history),
        .scroll_viewport => |v| io.scrollViewport(v),
        .selection_scroll => |v| {
            if (v) {
                self.startScrollTimer(cb);
            } else {
                self.stopScrollTimer();
            }
        },
        .jump_to_prompt => |v| try io.jumpToPrompt(v),
        .kitty_clipboard_grant_read => |v| {
            defer v.alloc.free(v.pw);
            try io.kittyClipboardGrant(v.pw, .read);
        },
        .kitty_clipboard_grant_write => |v| {
            defer v.alloc.free(v.pw);
            try io.kittyClipboardGrant(v.pw, .write);
        },
        .start_synchronized_output => self.startSynchronizedOutput(cb),
        .linefeed_mode => |v| self.flags.linefeed_mode = v,
        .focused => |v| try io.focusGained(data, v),
        .write_small => |v| try io.queueWrite(
            data,
            v.data[0..v.len],
            self.flags.linefeed_mode,
        ),
        .write_stable => |v| try io.queueWrite(
            data,
            v,
            self.flags.linefeed_mode,
        ),
        .write_alloc => |v| try io.queueWriteOwned(
            data,
            v,
            self.flags.linefeed_mode,
        ),
    }
}

fn startSynchronizedOutput(self: *Thread, cb: *CallbackData) void {
    self.sync_reset.reset(
        &self.loop,
        &self.sync_reset_c,
        &self.sync_reset_cancel_c,
        sync_reset_ms,
        CallbackData,
        cb,
        syncResetCallback,
    );
}

fn handleResize(self: *Thread, cb: *CallbackData, resize: renderer.Size) void {
    self.coalesce_data.resize = resize;

    // If the timer is already active we just return. In the future we want
    // to reset the timer up to a maximum wait time but for now this ensures
    // relatively smooth resizing.
    if (self.coalesce_c.state() == .active) return;

    self.coalesce.reset(
        &self.loop,
        &self.coalesce_c,
        &self.coalesce_cancel_c,
        Coalesce.min_ms,
        CallbackData,
        cb,
        coalesceCallback,
    );
}

fn syncResetCallback(
    cb_: ?*CallbackData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch |err| switch (err) {
        error.Canceled => return .disarm,
        else => {
            log.warn("error during sync reset callback err={}", .{err});
            return .disarm;
        },
    };

    const cb = cb_ orelse return .disarm;
    cb.io.resetSynchronizedOutput();
    return .disarm;
}

fn coalesceCallback(
    cb_: ?*CallbackData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch |err| switch (err) {
        error.Canceled => {},
        else => {
            log.warn("error during coalesce callback err={}", .{err});
            return .disarm;
        },
    };

    const cb = cb_ orelse return .disarm;

    if (cb.self.coalesce_data.resize) |v| {
        cb.self.coalesce_data.resize = null;
        cb.io.resize(&cb.data, v) catch |err| {
            log.warn("error during resize err={}", .{err});
        };
    }

    return .disarm;
}

fn wakeupCallback(
    cb_: ?*CallbackData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch |err| {
        log.err("error in wakeup err={}", .{err});
        return .rearm;
    };

    // When we wake up, we check the mailbox. Mailbox producers should
    // wake up our thread after publishing.
    const cb = cb_ orelse return .rearm;
    cb.self.drainMailbox(cb) catch |err|
        log.err("error draining mailbox err={}", .{err});

    return .rearm;
}

fn stopCallback(
    cb_: ?*CallbackData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch unreachable;
    cb_.?.self.loop.stop();
    return .disarm;
}

fn startScrollTimer(self: *Thread, cb: *CallbackData) void {
    self.scroll_active = true;

    switch (self.scroll_c.state()) {
        // If it is already active, e.g. startScrollTimer is called multiple
        // times, then we just return. We can't simply check `scroll_active`
        // because its possible that `stopScrollTimer` was called but there
        // was no loop tick between then and now to halt out completion.
        .active => return,

        // If the completion is not active then we need to start it.
        .dead => self.scroll.run(
            &self.loop,
            &self.scroll_c,
            selection_scroll_ms,
            CallbackData,
            cb,
            selectionScrollCallback,
        ),
    }
}

fn stopScrollTimer(self: *Thread) void {
    // This will stop the scrolling on the next iteration.
    self.scroll_active = false;
}

fn selectionScrollCallback(
    cb_: ?*CallbackData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch |err| switch (err) {
        error.Canceled => {},
        else => {
            log.warn("error during selection scroll callback err={}", .{err});
            return .disarm;
        },
    };

    const cb = cb_ orelse return .disarm;
    const self = cb.self;

    // Send the tick to the main surface
    _ = cb.io.surface_mailbox.push(
        .{ .selection_scroll_tick = self.scroll_active },
        .{ .instant = {} },
    );

    if (self.scroll_active) self.scroll.run(
        &self.loop,
        &self.scroll_c,
        selection_scroll_ms,
        CallbackData,
        cb,
        selectionScrollCallback,
    );

    return .disarm;
}

/// A mailbox/loop fixture without a child or renderer. Writes are queued
/// against an unused descriptor; these tests inspect the FIFO and never run
/// its write completions. Only initialized resources are destroyed.
const DrainTest = struct {
    worker: Thread = undefined,
    io: termio.Termio = undefined,
    cb: CallbackData = undefined,

    fn init(self: *DrainTest, write_alloc: Allocator) !void {
        const alloc = std.testing.allocator;
        self.worker = try Thread.init(alloc);
        errdefer self.worker.deinit();
        self.io.mailbox = try termio.Mailbox.initSPSC(alloc);
        errdefer self.io.mailbox.deinit(alloc);
        self.io.renderer_wakeup = try xev.Async.init();
        self.io.alloc = write_alloc;
        self.cb = .{
            .self = &self.worker,
            .io = &self.io,
            .data = .{
                .alloc = write_alloc,
                .loop = &self.worker.loop,
                .renderer_state = undefined,
                .surface_mailbox = undefined,
                .mailbox = &self.io.mailbox,
                .backend = .{
                    .start = undefined,
                    .write_stream = xev.Stream.initFd(-1),
                    .process = null,
                    .read_thread = undefined,
                    .read_thread_pipe = -1,
                    .read_thread_fd = -1,
                    .termios_timer = undefined,
                },
            },
        };
    }

    fn deinit(self: *DrainTest) void {
        self.worker.deinit();
        self.cb.data.backend.deinitWrites(self.io.alloc);
        self.io.renderer_wakeup.deinit();
        self.io.mailbox.deinit(std.testing.allocator);
    }
};

test "IO mailbox drain continues controls and releases owners after write allocation failure" {
    const t = std.testing;
    var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    var owners = t.FailingAllocator.init(t.allocator, .{});
    var fixture: DrainTest = .{};
    try fixture.init(failing.allocator());
    defer fixture.deinit();
    for ([_]bool{ false, true }) |linefeed| {
        fixture.io.mailbox.send(try termio.Message.writeReq(
            owners.allocator(),
            @as([]const u8, "pending" ** 32),
        ), null);
        fixture.io.mailbox.send(.{ .linefeed_mode = linefeed }, null);
    }

    // One wakeup services this batch. AsyncMachPort coalesces notifications
    // before drainMailbox runs, so returning early cannot rely on a second
    // wakeup to handle the remaining messages.
    try t.expectError(error.OutOfMemory, fixture.worker.drainMailbox(&fixture.cb));
    try t.expect(fixture.worker.flags.linefeed_mode);
    try t.expect(fixture.io.mailbox.spsc.queue.pop(t.io) == null);
    try t.expectEqual(owners.allocated_bytes, owners.freed_bytes);
}

test "IO mailbox drain preserves write FIFO and intervening linefeed modes" {
    const t = std.testing;
    var owners = t.FailingAllocator.init(t.allocator, .{});
    var fixture: DrainTest = .{};
    try fixture.init(t.allocator);
    var live = true;
    defer if (live) fixture.deinit();
    fixture.io.mailbox.send(.{ .write_stable = "first\r" }, null);
    fixture.io.mailbox.send(.{ .linefeed_mode = true }, null);
    fixture.io.mailbox.send(try termio.Message.writeReq(t.allocator, @as([]const u8, "\rA")), null);
    fixture.io.mailbox.send(try termio.Message.writeReq(
        owners.allocator(),
        @as([]const u8, "owned" ** 20),
    ), null);

    try fixture.worker.drainMailbox(&fixture.cb);
    var output: std.Io.Writer.Allocating = .init(t.allocator);
    defer output.deinit();
    var req = fixture.cb.data.backend.write_queue.head;
    while (req) |r| : (req = r.next) try output.writer.writeAll(r.full_write_buffer.slice);
    try t.expectEqualStrings("first\r\r\nA" ++ "owned" ** 20, output.written());
    try t.expect(fixture.io.mailbox.spsc.queue.pop(t.io) == null);
    fixture.deinit();
    live = false;
    try t.expectEqual(owners.allocated_bytes, owners.freed_bytes);
}

test "IO owned write adopts large mailbox buffer without a second allocation" {
    const t = std.testing;
    for ([_]bool{ false, true }) |linefeed| {
        var owners = t.FailingAllocator.init(t.allocator, .{});
        var writes = t.FailingAllocator.init(t.allocator, .{});
        var fixture: DrainTest = .{};
        try fixture.init(writes.allocator());
        defer fixture.deinit();

        // Reserve all three requests before measuring payload allocations.
        try fixture.cb.data.backend.write_pool.addCapacity(writes.allocator(), 3);
        // Keep the first request pending to check FIFO around the frame.
        fixture.io.mailbox.send(.{ .write_stable = "first" }, null);
        try fixture.worker.drainMailbox(&fixture.cb);
        const before = writes.allocated_bytes;
        const bytes = try owners.allocator().alloc(u8, 1024 * 1024);
        @memset(bytes, 'a');
        @memcpy(bytes[0..6], "\x1b[200~");
        @memcpy(bytes[bytes.len - 6 ..], "\x1b[201~");
        fixture.io.mailbox.send(.{ .linefeed_mode = linefeed }, null);
        fixture.io.mailbox.send(.{ .write_alloc = .{ .alloc = owners.allocator(), .data = bytes } }, null);
        fixture.io.mailbox.send(.{ .write_stable = "\x1b[A" }, null);
        try fixture.worker.drainMailbox(&fixture.cb);

        std.debug.print("\nOWNED_WRITE_METRIC source_bytes={d} linefeed={} io_extra_allocated_bytes={d}\n", .{
            bytes.len, linefeed, writes.allocated_bytes - before,
        });
        try t.expectEqual(before, writes.allocated_bytes);
        const first = fixture.cb.data.backend.write_queue.head.?;
        const frame = first.next.?;
        try t.expectEqual(bytes.ptr, frame.full_write_buffer.slice.ptr);
        try t.expectEqual(@as(usize, 0), owners.freed_bytes);
        try t.expectEqualStrings("first", first.full_write_buffer.slice);
        try t.expectEqualStrings("\x1b[200~", frame.full_write_buffer.slice[0..6]);
        try t.expectEqualStrings("\x1b[201~", frame.full_write_buffer.slice[bytes.len - 6 ..]);
        try t.expectEqualStrings("\x1b[A", frame.next.?.full_write_buffer.slice);
        try t.expect(frame.next.?.next == null);
    }
}

test "IO owned write CRLF expansion and inline copies release the original allocator" {
    const t = std.testing;
    for ([_]usize{ 39, 128 }) |len| {
        var owners = t.FailingAllocator.init(t.allocator, .{});
        var writes = t.FailingAllocator.init(t.allocator, .{});
        var fixture: DrainTest = .{};
        try fixture.init(writes.allocator());
        defer fixture.deinit();
        const bytes = try owners.allocator().alloc(u8, len);
        @memset(bytes, if (len == 39) 'a' else '\r');
        fixture.io.mailbox.send(.{ .linefeed_mode = true }, null);
        fixture.io.mailbox.send(.{ .write_alloc = .{ .alloc = owners.allocator(), .data = bytes } }, null);
        try fixture.worker.drainMailbox(&fixture.cb);
        try t.expectEqual(owners.allocated_bytes, owners.freed_bytes);
        const output = fixture.cb.data.backend.write_queue.head.?.full_write_buffer.slice;
        try t.expectEqual(if (len == 39) len else len * 2, output.len);
        for (output, 0..) |byte, i| try t.expectEqual(
            if (len == 39) @as(u8, 'a') else if (i % 2 == 0) @as(u8, '\r') else @as(u8, '\n'),
            byte,
        );
    }
}

test "IO owned write completion frees the source allocator exactly once" {
    const t = std.testing;
    for ([_]?xev.WriteError{ null, error.Canceled, error.Unexpected }) |err| {
        var owners = t.FailingAllocator.init(t.allocator, .{});
        var fixture: DrainTest = .{};
        try fixture.init(t.allocator);
        defer fixture.deinit();
        fixture.io.mailbox.send(try termio.Message.writeReq(owners.allocator(), @as([]const u8, "frame" ** 128)), null);
        try fixture.worker.drainMailbox(&fixture.cb);
        try t.expectEqual(@as(usize, 0), owners.freed_bytes);
        // Match libxev: pop before the shared success/error cleanup callback.
        // No loop runs here, so it cannot later invoke this completion.
        const req = fixture.cb.data.backend.write_queue.pop().?;
        const w: *termio.Exec.ThreadData.Write = @ptrCast(@alignCast(req.userdata.?));
        if (err) |failure| {
            try t.expectError(failure, w.complete(failure));
        } else {
            try t.expectEqual(owners.allocated_bytes, try w.complete(owners.allocated_bytes));
        }
        try t.expectEqual(owners.allocated_bytes, owners.freed_bytes);
    }
}

test "IO owned write empty exited and closed paths release mailbox ownership" {
    const t = std.testing;
    for (0..3) |mode| {
        var owners = t.FailingAllocator.init(t.allocator, .{});
        var fixture: DrainTest = .{};
        try fixture.init(t.allocator);
        defer fixture.deinit();
        if (mode == 1) fixture.cb.data.backend.exited = true;
        if (mode == 2) fixture.io.mailbox.close();
        const bytes = try owners.allocator().alloc(u8, if (mode == 0) 0 else 128);
        @memset(bytes, 'x');
        fixture.io.mailbox.send(.{ .write_alloc = .{ .alloc = owners.allocator(), .data = bytes } }, null);
        try fixture.worker.drainMailbox(&fixture.cb);
        try t.expect(fixture.cb.data.backend.write_queue.head == null);
        try t.expectEqual(owners.allocated_bytes, owners.freed_bytes);
    }
}

test "IO owned write allocation failures release source and replacement buffers" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(alloc: Allocator) !void {
            var fixture: DrainTest = .{};
            try fixture.init(alloc);
            defer fixture.deinit();
            for ([_][]const u8{ "owned" ** 128, "\r" ** 128, "inline" }) |input| {
                const owner = std.testing.allocator;
                fixture.io.mailbox.send(.{ .linefeed_mode = true }, null);
                fixture.io.mailbox.send(.{ .write_alloc = .{ .alloc = owner, .data = try owner.dupe(u8, input) } }, null);
                try fixture.worker.drainMailbox(&fixture.cb);
            }
        }
    }.run, .{});
}
