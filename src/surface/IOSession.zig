//! Stable owner of terminal state, subprocess, IO loop and worker.
//! Stop this producer while rendering is still running. Destroy only after
//! search/render borrowers and selection pins have finished using the terminal.
const Self = @This();
const std = @import("std");
const global = @import("../global.zig");
const termiopkg = @import("../termio.zig");
const configpkg = @import("../config.zig");
const apprt = @import("../apprt.zig");
const renderer = @import("../renderer.zig");
const RenderSession = @import("RenderSession.zig");
const log = std.log.scoped(.io_session);

alloc: std.mem.Allocator,
termio: termiopkg.Termio = undefined,
thread: termiopkg.Thread,
os_thread: ?std.Thread = null,
phase: enum { empty, ready, running, stopped } = .empty,

pub const Options = struct {
    config: *const configpkg.Config,
    command: ?configpkg.Command,
    rt_surface: *apprt.Surface,
    surface_id: u64,
    size: renderer.Size,
    render: *RenderSession,
    surface_mailbox: apprt.surface.Mailbox,
};

/// Reserve stable addresses before RenderSession borrows the terminal pointer.
pub fn create(alloc: std.mem.Allocator) !*Self {
    const self = try alloc.create(Self);
    errdefer alloc.destroy(self);
    self.* = .{ .alloc = alloc, .thread = try termiopkg.Thread.init(alloc) };
    return self;
}

pub fn initialize(self: *Self, opts: Options) !void {
    if (self.phase != .empty) return error.InvalidIOSessionState;
    const config = opts.config;
    const environment = prepared: {
        var env = opts.rt_surface.defaultTermioEnv() catch |err| env: {
            log.warn("error getting env map for surface err={}", .{err});
            break :env global.environMap() catch std.process.Environ.Map.init(self.alloc);
        };
        errdefer env.deinit();
        _ = env.orderedRemove("CGHOSTTY_LOG");
        var buf: [18]u8 = undefined;
        try env.put("GHOSTTY_SURFACE_ID", try std.fmt.bufPrint(&buf, "0x{x:0>16}", .{opts.surface_id}));
        break :prepared env;
    };
    var backend = try termiopkg.Exec.init(self.alloc, .{
        .command = opts.command,
        .env = environment,
        .env_override = config.env,
        .shell_integration = config.@"shell-integration",
        .shell_integration_features = config.@"shell-integration-features",
        .claude_compatibility = config.@"claude-compatibility",
        .cursor_blink = config.@"cursor-style-blink",
        .working_directory = if (config.@"working-directory") |wd| wd.value() else null,
        .resources_dir = global.resourcesDir().host(),
        .term = config.term,
        .rt_pre_exec_info = .init(config),
        .rt_post_fork_info = .init(config),
    });
    errdefer backend.deinit();
    var mailbox = try termiopkg.Mailbox.initSPSC(self.alloc);
    errdefer mailbox.deinit(self.alloc);
    var derived = try termiopkg.Termio.DerivedConfig.init(self.alloc, config);
    errdefer derived.deinit();
    try termiopkg.Termio.init(&self.termio, self.alloc, .{
        .size = opts.size,
        .full_config = config,
        .config = derived,
        .backend = backend,
        .mailbox = mailbox,
        .renderer_state = &opts.render.state,
        .renderer_wakeup = opts.render.thread.wakeup,
        .renderer_mailbox = opts.render.thread.mailbox,
        .surface_mailbox = opts.surface_mailbox,
    });
    self.phase = .ready;
}

pub fn start(self: *Self) !void {
    try self.startWith(struct {
        fn spawn(worker: *termiopkg.Thread, io: *termiopkg.Termio) std.Thread.SpawnError!std.Thread {
            return std.Thread.spawn(.{}, termiopkg.Thread.threadMain, .{ worker, io });
        }
    }.spawn);
}

fn startWith(self: *Self, spawn: *const fn (*termiopkg.Thread, *termiopkg.Termio) std.Thread.SpawnError!std.Thread) !void {
    if (self.phase != .ready) return error.InvalidIOSessionState;
    self.os_thread = try spawn(&self.thread, &self.termio);
    self.phase = .running;
    self.os_thread.?.setName(global.io(), "io") catch {};
}

/// Idempotent; terminal state remains available to borrowers after joining.
pub fn stop(self: *Self) void {
    if (self.phase != .empty) self.termio.mailbox.close();
    if (self.os_thread) |thread| {
        self.thread.stop.notify() catch |err|
            log.err("error notifying io thread to stop, may stall err={}", .{err});
        thread.join();
        self.os_thread = null;
    }
    if (self.phase != .empty) self.phase = .stopped;
}

pub fn destroy(self: *Self) void {
    self.stop();
    self.thread.deinit();
    if (self.phase != .empty) self.termio.deinit();
    const alloc = self.alloc;
    alloc.destroy(self);
}

test "IOSession allocation can unwind before terminal initialization" {
    const session = try create(std.testing.allocator);
    defer session.destroy();
    try std.testing.expectError(error.InvalidIOSessionState, session.startWith(struct {
        fn fail(_: *termiopkg.Thread, _: *termiopkg.Termio) std.Thread.SpawnError!std.Thread {
            return error.ThreadQuotaExceeded;
        }
    }.fail));
    session.stop();
    session.stop();
    try std.testing.expectEqual(.empty, session.phase);
}

test "IOSession failed spawn preserves ready state and joins exactly once" {
    const Worker = struct {
        fn fail(_: *termiopkg.Thread, _: *termiopkg.Termio) std.Thread.SpawnError!std.Thread {
            return error.ThreadQuotaExceeded;
        }
        fn spawn(worker: *termiopkg.Thread, _: *termiopkg.Termio) std.Thread.SpawnError!std.Thread {
            return std.Thread.spawn(.{}, run, .{worker});
        }
        fn run(worker: *termiopkg.Thread) void {
            worker.stop.wait(&worker.loop, &worker.stop_c, termiopkg.Thread, worker, stopped);
            worker.loop.run(.until_done) catch unreachable;
        }
        fn stopped(worker: ?*termiopkg.Thread, _: *global.xev.Loop, _: *global.xev.Completion, result: global.xev.Async.WaitError!void) global.xev.CallbackAction {
            result catch unreachable;
            worker.?.loop.stop();
            return .disarm;
        }
    };
    const session = try create(std.testing.allocator);
    session.termio.mailbox = try termiopkg.Mailbox.initSPSC(std.testing.allocator);
    defer {
        session.stop();
        session.termio.mailbox.deinit(std.testing.allocator);
        // This test exercises worker ownership without constructing a terminal.
        session.phase = .empty;
        session.destroy();
    }
    session.phase = .ready;
    try std.testing.expectError(error.ThreadQuotaExceeded, session.startWith(Worker.fail));
    try std.testing.expect(session.phase == .ready and session.os_thread == null);
    try session.startWith(Worker.spawn);
    try std.testing.expectError(error.InvalidIOSessionState, session.startWith(Worker.spawn));
    session.stop();
    session.stop();
    try std.testing.expect(session.phase == .stopped and session.os_thread == null);
    try std.testing.expectError(error.InvalidIOSessionState, session.startWith(Worker.spawn));
}

test "IOSession stop joins a worker blocked on a full IO queue within deadline" {
    const t = std.testing;
    const Worker = struct {
        fn spawn(worker: *termiopkg.Thread, io: *termiopkg.Termio) std.Thread.SpawnError!std.Thread {
            return std.Thread.spawn(.{}, run, .{ worker, io });
        }
        fn run(_: *termiopkg.Thread, io: *termiopkg.Termio) void {
            // The consumer has stopped; this is the reader's final response.
            io.mailbox.send(.{ .write_stable = "\x1b[0n" }, null);
        }
    };
    const session = try create(t.allocator);
    session.termio.mailbox = try termiopkg.Mailbox.initSPSC(t.allocator);
    session.phase = .ready;
    defer {
        session.stop();
        session.termio.mailbox.deinit(t.allocator);
        session.phase = .empty;
        session.destroy();
    }
    const queue = session.termio.mailbox.spsc.queue;
    for (0..64) |_| session.termio.mailbox.send(.{ .write_stable = "pending" }, null);
    try session.startWith(Worker.spawn);
    // Force cleanup independently of IOSession.stop so a regression reports
    // Timeout instead of hanging the test runner in a join.
    defer {
        queue.mutex.lockUncancelable(t.io);
        queue.closed = true;
        queue.cond_not_full.broadcast(t.io);
        queue.mutex.unlock(t.io);
    }
    const wait_started = std.Io.Timestamp.now(t.io, .awake);
    var blocked = false;
    while (wait_started.untilNow(t.io, .awake).toMilliseconds() < 1000) {
        queue.mutex.lockUncancelable(t.io);
        blocked = queue.not_full_waiters == 1;
        queue.mutex.unlock(t.io);
        if (blocked) break;
        try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
    }
    try t.expect(blocked);
    const Stopper = struct {
        session: *Self,
        done: std.Io.Event = .unset,
        fn run(self: *@This()) void {
            self.session.stop();
            self.done.set(std.testing.io);
        }
    };
    var stopper: Stopper = .{ .session = session };
    const thread = try std.Thread.spawn(.{}, Stopper.run, .{&stopper});
    defer {
        queue.mutex.lockUncancelable(t.io);
        queue.closed = true;
        queue.cond_not_full.broadcast(t.io);
        queue.mutex.unlock(t.io);
        thread.join();
    }
    try stopper.done.waitTimeout(t.io, .{ .duration = .{ .raw = .fromMilliseconds(1000), .clock = .awake } });
    try t.expect(session.phase == .stopped and session.os_thread == null);
    for (0..64) |_| try t.expectEqualStrings("pending", queue.pop(t.io).?.write_stable);
    try t.expect(queue.pop(t.io) == null);
}
