const std = @import("std");
const Allocator = std.mem.Allocator;
const global = @import("../global.zig");
const xev = global.xev;
const renderer = @import("../renderer.zig");
const termio = @import("../termio.zig");
const BlockingQueue = @import("../datastruct/main.zig").BlockingQueue;

const log = std.log.scoped(.io_writer);

/// A queue used for storing messages that is periodically drained.
/// Typically used by a multi-threaded application. The capacity is
/// hardcoded to a value that empirically has made sense for Ghostty usage
/// but I'm open to changing it with good arguments.
const Queue = BlockingQueue(termio.Message, 64);

/// The location to where write-related messages are sent.
pub const Mailbox = union(enum) {
    // /// Write messages to an unbounded list backed by an allocator.
    // /// This is useful for single-threaded applications where you're not
    // /// afraid of running out of memory. You should be careful that you're
    // /// processing this in a timely manner though since some heavy workloads
    // /// will produce a LOT of messages.
    // ///
    // /// At the time of authoring this, the primary use case for this is
    // /// testing more than anything, but it probably will have a use case
    // /// in libghostty eventually.
    // unbounded: std.ArrayList(termio.Message),

    /// Write messages to a SPSC queue for multi-threaded applications.
    spsc: struct {
        queue: *Queue,
        wakeup: xev.Async,
    },

    /// Init the SPSC writer.
    pub fn initSPSC(alloc: Allocator) !Mailbox {
        var queue = try Queue.create(alloc);
        errdefer queue.destroy(alloc);

        var wakeup = try xev.Async.init();
        errdefer wakeup.deinit();

        return .{ .spsc = .{ .queue = queue, .wakeup = wakeup } };
    }

    pub fn deinit(self: *Mailbox, alloc: Allocator) void {
        switch (self.*) {
            .spsc => |*v| {
                while (v.queue.pop(global.io())) |msg| msg.deinit();
                v.queue.destroy(alloc);
                v.wakeup.deinit();
            },
        }
    }

    /// Release blocked senders before the consumer stops or joins its reader.
    pub fn close(self: *Mailbox) void {
        switch (self.*) {
            .spsc => |*v| v.queue.close(global.io()),
        }
    }

    /// Sends the given message without notifying there are messages.
    ///
    /// If the optional mutex is given, it must already be LOCKED. If the
    /// send would block, we'll unlock this mutex, resend the message, and
    /// lock it again. This handles an edge case where queues are full.
    /// This may not apply to all writer types.
    pub fn send(
        self: *Mailbox,
        msg: termio.Message,
        mutex: ?*std.Io.Mutex,
    ) void {
        switch (self.*) {
            .spsc => |*mb| send: {
                // Try to write to the queue with an instant timeout. This is the
                // fast path because we can queue without a lock.
                if (mb.queue.push(global.io(), msg, .{ .instant = {} }) > 0) break :send;

                // If we enter this conditional, the queue is full. We wake up
                // the writer thread so that it can process messages to clear up
                // space. However, the writer thread may require the renderer
                // lock so we need to unlock.
                mb.wakeup.notify() catch |err| {
                    log.warn("failed to wake up writer, data will be dropped err={}", .{err});
                    msg.deinit();
                    return;
                };

                // Unlock the renderer state so the writer thread can acquire it.
                // Then try to queue our message before continuing. This is a very
                // slow path because we are having a lot of contention for data.
                // But this only gets triggered in certain pathological cases.
                //
                // Note that writes themselves don't require a lock, but there
                // are other messages in the writer queue (resize, focus) that
                // could acquire the lock. This is why we have to release our lock
                // here.
                if (mutex) |m| m.unlock(global.io());
                defer if (mutex) |m| m.lockUncancelable(global.io());
                if (mb.queue.push(global.io(), msg, .{ .forever = {} }) == 0) msg.deinit();
            },
        }
    }

    /// Notify that there are new messages. This may be a noop depending
    /// on the writer type.
    pub fn notify(self: *Mailbox) void {
        switch (self.*) {
            .spsc => |*v| v.wakeup.notify() catch |err| {
                log.warn("failed to notify writer, data will be dropped err={}", .{err});
            },
        }
    }
};

test "termio mailbox close releases blocked owning sends and rejects later writes" {
    const t = std.testing;
    var mailbox = try Mailbox.initSPSC(t.allocator);
    defer mailbox.deinit(t.allocator);
    for (0..64) |_| mailbox.send(.{ .write_stable = "pending" }, null);
    const Producer = struct {
        mailbox: *Mailbox,
        done: std.Io.Event = .unset,
        fn run(self: *@This()) void {
            const msg = termio.Message.writeReq(std.testing.allocator, @as([]const u8, "x" ** 300)) catch unreachable;
            self.mailbox.send(msg, null);
            self.done.set(std.testing.io);
        }
    };
    var producer: Producer = .{ .mailbox = &mailbox };
    const thread = try std.Thread.spawn(.{}, Producer.run, .{&producer});
    defer {
        const queue = mailbox.spsc.queue;
        queue.mutex.lockUncancelable(t.io);
        queue.closed = true;
        queue.cond_not_full.broadcast(t.io);
        queue.mutex.unlock(t.io);
        thread.join();
    }
    const queue = mailbox.spsc.queue;
    const start = std.Io.Timestamp.now(t.io, .awake);
    var blocked = false;
    while (start.untilNow(t.io, .awake).toMilliseconds() < 1000) {
        queue.mutex.lockUncancelable(t.io);
        blocked = queue.not_full_waiters == 1;
        queue.mutex.unlock(t.io);
        if (blocked) break;
        try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
    }
    try t.expect(blocked);
    mailbox.close();
    try producer.done.waitTimeout(t.io, .{ .duration = .{ .raw = .fromMilliseconds(1000), .clock = .awake } });
    mailbox.send(try termio.Message.writeReq(t.allocator, @as([]const u8, "y" ** 300)), null);
    for (0..64) |_| try t.expect(queue.pop(t.io).? == .write_stable);
    try t.expect(queue.pop(t.io) == null);
}

test "termio mailbox closed and pending owning messages release configurations and grants" {
    const t = std.testing;
    var config = try @import("../config.zig").Config.default(t.allocator);
    defer config.deinit();
    for ([_]bool{ false, true }) |closed| {
        var mailbox = try Mailbox.initSPSC(t.allocator);
        defer mailbox.deinit(t.allocator);
        if (closed) mailbox.close();
        const derived = try t.allocator.create(termio.Termio.DerivedConfig);
        derived.* = try termio.Termio.DerivedConfig.init(t.allocator, &config);
        mailbox.send(.{ .change_config = .{ .alloc = t.allocator, .ptr = derived } }, null);
        mailbox.send(.{ .kitty_clipboard_grant_read = .{ .alloc = t.allocator, .pw = try t.allocator.dupe(u8, "read grant") } }, null);
        mailbox.send(.{ .kitty_clipboard_grant_write = .{ .alloc = t.allocator, .pw = try t.allocator.dupe(u8, "write grant") } }, null);
    }
}
