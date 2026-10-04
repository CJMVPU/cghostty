//! Headless tests and an opt-in resource probe for the real PTY write path.
//! Run the probe serially with CGHOSTTY_PTY_PROBE_MIB=1, 8, or 32, and
//! CGHOSTTY_PTY_PROBE_MODE=fast, slow, or paused. Payload generation is
//! outside the measured enqueue/drain intervals and is deterministic.
//! Use both -Doptimize=ReleaseFast and -Dtest-optimize=ReleaseFast.
const std = @import("std");
const posix = std.posix;
const c = @import("pty-c");
const xev = @import("../global.zig").xev;
const termio = @import("../termio.zig");
const Pty = @import("../pty.zig").Pty;

const Fixture = struct {
    pty: Pty,
    loop: xev.Loop,
    td: termio.Termio.ThreadData,

    fn init(alloc: std.mem.Allocator) !Fixture {
        var pty = try Pty.open(.{});
        errdefer pty.deinit();
        errdefer _ = posix.system.close(pty.slave);

        var attrs: c.termios = undefined;
        if (c.tcgetattr(pty.slave, &attrs) != 0) return error.GetModeFailed;
        c.cfmakeraw(&attrs);
        if (c.tcsetattr(pty.slave, c.TCSANOW, &attrs) != 0)
            return error.SetModeFailed;
        for ([_]posix.fd_t{ pty.master, pty.slave }) |fd| {
            const flags = posix.system.fcntl(fd, posix.F.GETFL);
            if (flags == -1 or posix.system.fcntl(
                fd,
                posix.F.SETFL,
                flags | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })),
            ) == -1) return error.SetNonblockingFailed;
        }

        return .{
            .pty = pty,
            .loop = try xev.Loop.init(.{}),
            // queueWrite only uses loop and backend. Other fields belong to
            // the subprocess/read/render lifecycle, which this fixture skips.
            .td = .{
                .alloc = alloc,
                .loop = undefined,
                .renderer_state = undefined,
                .surface_mailbox = undefined,
                .mailbox = undefined,
                .backend = .{
                    .start = undefined,
                    .write_stream = xev.Stream.initFd(pty.master),
                    .process = null,
                    .read_thread = undefined,
                    .read_thread_pipe = -1,
                    .read_thread_fd = -1,
                    .termios_timer = undefined,
                },
            },
        };
    }

    fn deinit(self: *Fixture, alloc: std.mem.Allocator) void {
        // Pending requests can point into the pool. Once the loop is gone
        // no callbacks can touch them, including early-error cleanup.
        self.loop.deinit();
        self.td.backend.write_pool.deinit(alloc);
        self.td.backend.write_stream.deinit();
        _ = posix.system.close(self.pty.slave);
        self.pty.deinit();
    }

    fn write(self: *Fixture, alloc: std.mem.Allocator, bytes: []const u8, linefeed: bool) !void {
        self.td.loop = &self.loop;
        var exec: termio.Exec = undefined; // queueWrite does not inspect self.
        try exec.queueWrite(alloc, &self.td, bytes, linefeed);
    }

    fn pending(self: *const Fixture) usize {
        var total: usize = 0;
        var req = self.td.backend.write_queue.head;
        while (req) |r| : (req = r.next) total += 1;
        return total;
    }

    fn drain(self: *Fixture, expected: []const u8, slow: bool) !void {
        const t = std.testing;
        const start: std.Io.Timestamp = .now(t.io, .awake);
        var received: usize = 0;
        var since_pause: usize = 0;
        var buf: [65536]u8 = undefined;
        while (received < expected.len) {
            try self.loop.run(.no_wait);
            const len = if (slow) 4096 - since_pause else buf.len;
            const result = posix.system.read(self.pty.slave, &buf, len);
            switch (posix.errno(result)) {
                .SUCCESS => {
                    const n: usize = @intCast(result);
                    try t.expect(n > 0);
                    try t.expect(received + n <= expected.len);
                    try t.expectEqualSlices(u8, expected[received..][0..n], buf[0..n]);
                    received += n;
                    since_pause += n;
                },
                .AGAIN, .INTR => {},
                else => return error.ReadFailed,
            }
            // Pace bytes consumed rather than loop ticks. The writer may
            // need many ticks to submit 4 KiB using the baseline 64B writes;
            // sleeping per tick would give different rates across revisions.
            if (slow and since_pause == 4096) {
                try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
                since_pause = 0;
            }
            if (start.untilNow(t.io, .awake).toMilliseconds() > 60_000)
                return error.DrainTimedOut;
        }
        // The final kernel read can precede the writer completion callback.
        try self.loop.run(.no_wait);
        try t.expectEqual(@as(usize, 0), self.pending());
    }
};

test "PTY write ordered buffers preserve CRLF and bracketed paste" {
    const t = std.testing;
    var fixture = try Fixture.init(t.allocator);
    defer fixture.deinit(t.allocator);

    var text: [137]u8 = undefined;
    @memset(&text, 'x');
    text[62] = '\r';
    text[63] = '\r';
    text[136] = '\r';
    var expected: std.Io.Writer.Allocating = .init(t.allocator);
    defer expected.deinit();
    try expected.writer.writeAll("\x1b[200~");
    for (text) |ch| {
        try expected.writer.writeByte(ch);
        if (ch == '\r') try expected.writer.writeByte('\n');
    }
    try expected.writer.writeAll("\x1b[201~\x1b[A");

    try fixture.write(t.allocator, "\x1b[200~", false);
    try fixture.write(t.allocator, &text, true);
    try fixture.write(t.allocator, "\x1b[201~", false);
    try fixture.write(t.allocator, "\x1b[A", false);
    try fixture.drain(expected.written(), false);
}

test "PTY write exit discards later input and teardown releases pending input" {
    const t = std.testing;
    var fixture = try Fixture.init(t.allocator);
    defer fixture.deinit(t.allocator);
    try fixture.write(t.allocator, "first", false);
    const before = fixture.pending();
    fixture.td.backend.exited = true;
    try fixture.write(t.allocator, "discard", false);
    try t.expectEqual(before, fixture.pending());
    // Leave the first write pending: deinit must not run callbacks pointing
    // into already-freed write state, and testing.allocator catches leaks.
}

test "PTY write allocation failures release pending storage on teardown" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        struct {
            fn run(alloc: std.mem.Allocator) !void {
                var fixture = try Fixture.init(alloc);
                defer fixture.deinit(alloc);
                // Enough data to grow the request pool across several pages.
                const text = [_]u8{'\r'} ** 4096;
                try fixture.write(alloc, &text, true);
            }
        }.run,
        .{},
    );
}

test "PTY write pressure probe" {
    const t = std.testing;
    const size_env = posix.system.getenv("CGHOSTTY_PTY_PROBE_MIB") orelse
        return error.SkipZigTest;
    const mib = try std.fmt.parseInt(usize, std.mem.span(size_env), 10);
    if (mib == 0 or mib > 32) return error.InvalidProbeSize;
    const mode = if (posix.system.getenv("CGHOSTTY_PTY_PROBE_MODE")) |v|
        std.mem.span(v)
    else
        "fast";
    if (!std.mem.eql(u8, mode, "fast") and
        !std.mem.eql(u8, mode, "slow") and
        !std.mem.eql(u8, mode, "paused")) return error.InvalidProbeMode;

    const payload = try t.allocator.alloc(u8, mib * 1024 * 1024);
    defer t.allocator.free(payload);
    for (payload, 0..) |*byte, i| byte.* = @intCast(i % 251);

    var counter = t.FailingAllocator.init(t.allocator, .{});
    const alloc = counter.allocator();
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit(alloc);
    const start: std.Io.Timestamp = .now(t.io, .awake);
    try fixture.write(alloc, payload, false);
    const enqueue_ns = start.untilNow(t.io, .awake).nanoseconds;
    const initial_requests = fixture.pending();
    const allocated_bytes = counter.allocated_bytes;

    var paused_requests: usize = 0;
    var paused_loop_tick_max_ns: i96 = 0;
    if (std.mem.eql(u8, mode, "paused")) {
        // Measure nonblocking loop ticks while the slave is paused. This is
        // a headless event-loop measurement, not a UI/control-message result.
        for (0..50) |_| {
            const tick_start: std.Io.Timestamp = .now(t.io, .awake);
            try fixture.loop.run(.no_wait);
            paused_loop_tick_max_ns = @max(
                paused_loop_tick_max_ns,
                tick_start.untilNow(t.io, .awake).nanoseconds,
            );
            try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
        }
        paused_requests = fixture.pending();
    }
    const drain_start: std.Io.Timestamp = .now(t.io, .awake);
    try fixture.drain(payload, std.mem.eql(u8, mode, "slow"));
    const drain_ns = drain_start.untilNow(t.io, .awake).nanoseconds;
    std.debug.print(
        "\nRESOURCE_METRIC pty_bytes={d} mode={s} initial_requests={d} paused_requests={d} pool_allocated_bytes={d} retained_bytes={d} enqueue_ns={d} drain_ns={d} paused_loop_tick_max_ns={d}\n",
        .{ payload.len, mode, initial_requests, paused_requests, allocated_bytes, counter.allocated_bytes - counter.freed_bytes, enqueue_ns, drain_ns, paused_loop_tick_max_ns },
    );
}
