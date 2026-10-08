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
        self.td.backend.deinitWrites(alloc);
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
    try fixture.write(t.allocator, &([_]u8{'x'} ** 32768), false);
    const before = fixture.pending();
    fixture.td.backend.exited = true;
    try fixture.write(t.allocator, "discard", false);
    try t.expectEqual(before, fixture.pending());
    // Leave both inline and owned writes pending: deinit must not run
    // callbacks into freed state, and testing.allocator catches leaks.
}

test "PTY write allocation failures release pending storage on teardown" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        struct {
            fn run(alloc: std.mem.Allocator) !void {
                var fixture = try Fixture.init(alloc);
                defer fixture.deinit(alloc);
                // Allocation failures include owned-buffer creation and
                // request-pool creation after the buffer was allocated.
                const text = [_]u8{'\r'} ** 4096;
                try fixture.write(alloc, &text, true);
                try fixture.write(alloc, &text, false);
            }
        }.run,
        .{},
    );
}

test "PTY write large payload remains ordered across partial writes" {
    const t = std.testing;
    var fixture = try Fixture.init(t.allocator);
    defer fixture.deinit(t.allocator);
    const bytes = try t.allocator.alloc(u8, 65536);
    defer t.allocator.free(bytes);
    for (bytes, 0..) |*byte, i| byte.* = @intCast(i % 251);
    var expected: std.Io.Writer.Allocating = .init(t.allocator);
    defer expected.deinit();
    try expected.writer.writeAll(bytes);
    try expected.writer.writeAll("\x1b[A");
    try fixture.write(t.allocator, bytes, false);
    try fixture.write(t.allocator, "\x1b[A", false);
    try t.expectEqual(@as(usize, 2), fixture.pending());
    // Input may be freed or changed as soon as queueWrite returns.
    @memset(bytes, 0);
    try fixture.drain(expected.written(), false);
}

test "PTY write owned payload retains its original allocator across partial writes" {
    const t = std.testing;
    var owners = t.FailingAllocator.init(t.allocator, .{});
    var fixture = try Fixture.init(t.allocator);
    defer fixture.deinit(t.allocator);
    const bytes = try owners.allocator().alloc(u8, 65536);
    var transferred = false;
    defer if (!transferred) owners.allocator().free(bytes);
    for (bytes, 0..) |*byte, i| byte.* = @intCast(i % 251);
    var expected: std.Io.Writer.Allocating = .init(t.allocator);
    defer expected.deinit();
    try expected.writer.writeAll(bytes);
    try expected.writer.writeAll("\x1b[A");
    fixture.td.loop = &fixture.loop;
    var exec: termio.Exec = undefined;
    transferred = true; // queueWriteOwned consumes input even if it fails.
    try exec.queueWriteOwned(t.allocator, &fixture.td, .{ .alloc = owners.allocator(), .data = bytes }, false);
    try fixture.write(t.allocator, "\x1b[A", false);
    try t.expectEqual(@as(usize, 0), owners.freed_bytes);
    try t.expectEqual(bytes.ptr, fixture.td.backend.write_queue.head.?.full_write_buffer.slice.ptr);
    try t.expectEqual(@as(usize, 2), fixture.pending());
    try fixture.drain(expected.written(), false);
    try t.expectEqual(owners.allocated_bytes, owners.freed_bytes);
}

test "PTY write dense CRLF expands owned buffer without reordering" {
    const t = std.testing;
    var fixture = try Fixture.init(t.allocator);
    defer fixture.deinit(t.allocator);
    const text = [_]u8{'\r'} ** 32768;
    const expected = try t.allocator.alloc(u8, text.len * 2 + 1);
    defer t.allocator.free(expected);
    for (0..text.len) |i| {
        expected[i * 2] = '\r';
        expected[i * 2 + 1] = '\n';
    }
    expected[expected.len - 1] = 'x';
    try fixture.write(t.allocator, &text, true);
    try fixture.write(t.allocator, "x", false);
    try t.expectEqual(@as(usize, 2), fixture.pending());
    try fixture.drain(expected, false);
}

test "PTY write short and empty input need no owned allocation after warmup" {
    const t = std.testing;
    var counter = t.FailingAllocator.init(t.allocator, .{});
    const alloc = counter.allocator();
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit(alloc);
    try fixture.write(alloc, "a", false);
    try fixture.drain("a", false);
    counter.fail_index = counter.alloc_index;
    try fixture.write(alloc, "", true);
    try fixture.write(alloc, "\r", true);
    try fixture.drain("\r\n", false);
    try t.expect(!counter.has_induced_failure);
}

test "PTY write completion errors release owned storage before returning error" {
    const t = std.testing;
    for ([_]xev.WriteError{ error.Canceled, error.Unexpected }) |err| {
        var counter = t.FailingAllocator.init(t.allocator, .{});
        const alloc = counter.allocator();
        var fixture = try Fixture.init(alloc);
        defer fixture.deinit(alloc);
        try fixture.write(alloc, &([_]u8{'x'} ** 32768), false);
        const freed_before = counter.freed_bytes;
        // libxev removes the request before invoking the real ttyWrite
        // callback, which calls this same complete method for every result.
        // No loop runs in this test, so it cannot later touch this request.
        const req = fixture.td.backend.write_queue.pop().?;
        const w: *termio.Exec.ThreadData.Write = @ptrCast(@alignCast(req.userdata.?));
        try t.expectError(err, w.complete(err));
        try t.expectEqual(freed_before + 32768, counter.freed_bytes);
        try t.expectEqual(@as(usize, 0), fixture.pending());
    }
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
        "\nRESOURCE_METRIC pty_bytes={d} mode={s} initial_requests={d} paused_requests={d} write_allocated_bytes={d} retained_bytes={d} enqueue_ns={d} drain_ns={d} paused_loop_tick_max_ns={d}\n",
        .{ payload.len, mode, initial_requests, paused_requests, allocated_bytes, counter.allocated_bytes - counter.freed_bytes, enqueue_ns, drain_ns, paused_loop_tick_max_ns },
    );
}

const InitialInput = @import("InitialInput.zig");

/// Real source descriptor, PTY and event loop. Only the source continuation
/// mailbox is registered; it advances under the same callback boundaries as
/// the production writer. A paused consumer still leaves loop controls usable.
const SourceFixture = struct {
    fixture: Fixture = undefined,
    io: termio.Termio = undefined,
    app: @import("../apprt.zig").App = .{},
    app_queue: *@import("../App.zig").Mailbox.Queue = undefined,
    wakeup_c: xev.Completion = .{},

    fn init(self: *SourceFixture, alloc: std.mem.Allocator, inputs: []const InitialInput.Input) !void {
        self.fixture = try Fixture.init(alloc);
        errdefer self.fixture.deinit(alloc);
        self.io.mailbox = try termio.Mailbox.initSPSC(alloc);
        errdefer self.io.mailbox.deinit(alloc);
        self.app_queue = try @import("../App.zig").Mailbox.Queue.create(alloc);
        errdefer self.app_queue.destroy(alloc);
        self.io.fault = .{};
        self.io.surface_mailbox = .{ .surface = undefined, .app = .{ .rt_app = &self.app, .mailbox = self.app_queue } };
        self.fixture.td.loop = &self.fixture.loop;
        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        const a = arena.allocator();
        const input = try a.create(InitialInput);
        // Ownership of descriptors transfers only after the final allocation.
        const copied = try a.dupe(InitialInput.Input, inputs);
        for (inputs) |item| switch (item) {
            .string => {},
            .file => |file| {
                const flags = posix.system.fcntl(file.handle, posix.F.GETFL);
                if (flags == -1 or posix.system.fcntl(file.handle, posix.F.SETFL, flags | @as(u32, @bitCast(posix.O{ .NONBLOCK = true }))) == -1)
                    return error.SetNonblockingFailed;
            },
        };
        input.* = .{
            .arena = arena,
            .input = .{},
            .inputs = copied,
            .io = &self.io,
            .td = &self.fixture.td,
        };
        self.fixture.td.backend.initial_input = input;
        self.io.mailbox.spsc.wakeup.wait(&self.fixture.loop, &self.wakeup_c, SourceFixture, self, continuation);
    }

    fn continuation(self_: ?*SourceFixture, _: *xev.Loop, _: *xev.Completion, result: xev.Async.WaitError!void) xev.CallbackAction {
        _ = result catch return .disarm;
        const self = self_.?;
        if (self.fixture.td.backend.initial_input) |input| input.drive() catch |err| self.io.reportFault(err);
        return .rearm;
    }

    fn start(self: *SourceFixture) !void {
        try self.fixture.td.backend.initial_input.?.drive();
    }

    fn deinit(self: *SourceFixture, alloc: std.mem.Allocator) void {
        self.fixture.deinit(alloc);
        self.io.mailbox.deinit(alloc);
        self.app_queue.destroy(alloc);
    }
};

test "PTY source bounds read ahead and preserves subsequent paste ordering" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = try t.allocator.alloc(u8, 1024 * 1024);
    defer t.allocator.free(bytes);
    for (bytes, 0..) |*b, i| b.* = @intCast(i % 251);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "source", .data = bytes });
    const file = try tmp.dir.openFile(t.io, "source", .{});
    var transferred = false;
    defer if (!transferred) file.close(t.io);
    var source: SourceFixture = .{};
    try source.init(t.allocator, &.{ .{ .string = "before" }, .{ .file = file }, .{ .string = "after" } });
    transferred = true;
    defer source.deinit(t.allocator);
    try source.start();
    // The ordinary paste is prepared and owned just as before; it cannot
    // enter the PTY queue ahead of any configured source.
    const paste = try t.allocator.dupe(u8, "\rkey\x1b[A");
    var exec: termio.Exec = undefined;
    try exec.queueWriteOwned(t.allocator, &source.fixture.td, .{ .alloc = t.allocator, .data = paste }, true);
    const start: std.Io.Timestamp = .now(t.io, .awake);
    while (source.fixture.td.backend.initial_input.?.file_bytes == 0) {
        try source.fixture.loop.run(.no_wait);
        if (start.untilNow(t.io, .awake).toMilliseconds() > 1000) return error.SourceTimedOut;
    }
    const input = source.fixture.td.backend.initial_input.?;
    try t.expectEqual(InitialInput.chunk_size, input.buffer.?.len);
    try t.expectEqual(InitialInput.chunk_size, input.file_bytes);
    // With the slave unread, PTY backpressure leaves exactly one source
    // request and no read of the next chunk, even as the loop keeps ticking.
    for (0..100) |_| try source.fixture.loop.run(.no_wait);
    try t.expectEqual(InitialInput.chunk_size, input.file_bytes);
    try t.expectEqual(@as(usize, 1), source.fixture.pending());
    try t.expect(source.fixture.td.backend.deferred_head != null);
    // A real ioctl remains usable while the input writer is blocked.
    try source.fixture.pty.setSize(.{ .ws_col = 120, .ws_row = 40 });
    try t.expectEqual(@as(u16, 120), (try source.fixture.pty.getSize()).ws_col);
    var expected: std.Io.Writer.Allocating = .init(t.allocator);
    defer expected.deinit();
    try expected.writer.writeAll("before");
    try expected.writer.writeAll(bytes);
    try expected.writer.writeAll("after\r\nkey\x1b[A");
    try source.fixture.drain(expected.written(), true);
    try t.expect(source.fixture.td.backend.initial_input == null);
    try t.expect(!source.io.fault.failed());
}

test "PTY source accepts opened streams and leaves stop responsive" {
    const t = std.testing;
    const pipe = try @import("../os/main.zig").pipe();
    defer _ = posix.system.close(pipe[1]);
    var transferred = false;
    defer if (!transferred) {
        _ = posix.system.close(pipe[0]);
    };
    var source: SourceFixture = .{};
    try source.init(t.allocator, &.{.{ .file = .{ .handle = pipe[0], .flags = .{ .nonblocking = true } } }});
    transferred = true;
    defer source.deinit(t.allocator);
    try source.start();
    // There are no source bytes yet, and ordinary input waits behind it.
    try source.fixture.write(t.allocator, "pending", false);
    try source.fixture.loop.run(.no_wait);
    try t.expectEqual(@as(usize, 0), source.fixture.pending());
    var stop = try xev.Async.init();
    defer stop.deinit();
    var completion: xev.Completion = .{};
    var stopped = false;
    stop.wait(&source.fixture.loop, &completion, bool, &stopped, struct {
        fn callback(value: ?*bool, loop: *xev.Loop, _: *xev.Completion, result: xev.Async.WaitError!void) xev.CallbackAction {
            _ = result catch unreachable;
            value.?.* = true;
            loop.stop();
            return .disarm;
        }
    }.callback);
    try stop.notify();
    const start: std.Io.Timestamp = .now(t.io, .awake);
    while (!stopped) {
        try source.fixture.loop.run(.no_wait);
        if (start.untilNow(t.io, .awake).toMilliseconds() > 1000) return error.StopTimedOut;
    }
    // Teardown cancels a pending read and frees the deferred ordinary input.
    try t.expect(source.fixture.td.backend.initial_input != null);
}

test "PTY source stream EOF completes before queued ordinary input" {
    const t = std.testing;
    const pipe = try @import("../os/main.zig").pipe();
    var transferred = false;
    defer if (!transferred) {
        _ = posix.system.close(pipe[0]);
    };
    // Close the producer after a small stream payload; exercise real EOF.
    try t.expectEqual(@as(isize, 6), posix.system.write(pipe[1], "stream", 6));
    _ = posix.system.close(pipe[1]);
    var source: SourceFixture = .{};
    try source.init(t.allocator, &.{.{ .file = .{ .handle = pipe[0], .flags = .{ .nonblocking = true } } }});
    transferred = true;
    defer source.deinit(t.allocator);
    try source.start();
    try source.fixture.write(t.allocator, "suffix", false);
    try source.fixture.drain("streamsuffix", false);
    try t.expect(source.fixture.td.backend.initial_input == null);
}

test "PTY source allocation failures release source and deferred storage" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "source", .data = "contents" });
    try t.checkAllAllocationFailures(t.allocator, struct {
        fn run(alloc: std.mem.Allocator, dir: std.Io.Dir) !void {
            const file = try dir.openFile(std.testing.io, "source", .{});
            var transferred = false;
            defer if (!transferred) file.close(std.testing.io);
            var source: SourceFixture = .{};
            try source.init(alloc, &.{.{ .file = file }});
            transferred = true;
            defer source.deinit(alloc);
            try source.start();
            try source.fixture.write(alloc, &([_]u8{'p'} ** 1024), false);
        }
    }.run, .{tmp.dir});
}

test "PTY source deferred flush yields without reordering later input" {
    const t = std.testing;
    var source: SourceFixture = .{};
    try source.init(t.allocator, &.{.{ .string = "" }});
    defer source.deinit(t.allocator);
    var expected: [101]u8 = undefined;
    for (expected[0..100], 0..) |*byte, i| {
        byte.* = @intCast(i);
        try source.fixture.write(t.allocator, byte[0..1], false);
    }
    try source.start();
    try t.expectEqual(@as(usize, 32), source.fixture.pending());
    try t.expect(source.fixture.td.backend.initial_input != null);
    expected[100] = 200;
    try source.fixture.write(t.allocator, expected[100..], false);
    try source.fixture.drain(&expected, false);
    try t.expect(source.fixture.td.backend.initial_input == null);
}

test "PTY source rejects growth beyond limit with a visible fault" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const payload = try t.allocator.alloc(u8, InitialInput.file_limit);
    defer t.allocator.free(payload);
    @memset(payload, 'x');
    try tmp.dir.writeFile(t.io, .{ .sub_path = "source", .data = payload });
    const writer = try tmp.dir.openFile(t.io, "source", .{ .mode = .read_write });
    defer writer.close(t.io);
    const file = try tmp.dir.openFile(t.io, "source", .{});
    var transferred = false;
    defer if (!transferred) file.close(t.io);
    var source: SourceFixture = .{};
    try source.init(t.allocator, &.{.{ .file = file }});
    transferred = true;
    defer source.deinit(t.allocator);
    // The descriptor's original size was within the limit. Grow it after
    // opening, representing a changing file or a streaming source.
    try writer.setLength(t.io, InitialInput.file_limit + 1);
    try source.start();
    try source.fixture.drain(payload, false);
    const start: std.Io.Timestamp = .now(t.io, .awake);
    while (!source.io.fault.failed()) {
        try source.fixture.loop.run(.no_wait);
        if (start.untilNow(t.io, .awake).toMilliseconds() > 1000) return error.FaultTimedOut;
    }
    try t.expectEqual(error.InputFailed, source.io.fault.take().?);
    var byte: [1]u8 = undefined;
    const result = posix.system.read(source.fixture.pty.slave, &byte, 1);
    try t.expectEqual(posix.E.AGAIN, posix.errno(result));
}

test "PTY source read and request allocation errors publish a sticky fault" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "source", .data = "contents" });
    for ([_]bool{ false, true }) |allocation_error| {
        var counter = t.FailingAllocator.init(t.allocator, .{});
        const alloc = counter.allocator();
        // A write-only descriptor causes read EBADF without violating
        // ownership: teardown must still close a valid descriptor exactly once.
        const file = try tmp.dir.openFile(t.io, "source", .{
            .mode = if (allocation_error) .read_only else .write_only,
        });
        var transferred = false;
        defer if (!transferred) file.close(t.io);
        var source: SourceFixture = .{};
        try source.init(alloc, &.{.{ .file = file }});
        transferred = true;
        defer source.deinit(alloc);
        const input = source.fixture.td.backend.initial_input.?;
        input.buffer = try input.arena.allocator().alloc(u8, InitialInput.chunk_size);
        if (allocation_error) {
            // Reading succeeds; allocating the borrowed PTY request fails.
            counter.fail_index = counter.alloc_index;
        }
        try source.start();
        try t.expectEqual(error.InputFailed, source.io.fault.take().?);
        try t.expect(source.io.fault.failed());
        try t.expectEqual(@as(usize, 0), source.fixture.pending());
    }
}
