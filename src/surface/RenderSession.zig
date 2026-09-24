//! Stable owner of a surface's renderer, render worker and shared render state.
//! Surface must stop search/IO producers before destruction. The terminal is
//! borrowed; its owner keeps it alive until the render worker has joined.
const Self = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const rendererpkg = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const configpkg = @import("../config.zig");
const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const global = @import("../global.zig");
const log = std.log.scoped(.render_session);

alloc: Allocator,
renderer: rendererpkg.Renderer,
thread: rendererpkg.Thread,
state: rendererpkg.State,
mutex: std.Io.Mutex = .init,
os_thread: ?std.Thread = null,
phase: enum { ready, running, stopped } = .ready,

pub const Options = struct {
    config: *const configpkg.Config,
    font_grid: *font.SharedGrid,
    size: rendererpkg.Size,
    terminal: *terminal.Terminal,
    rt_surface: *apprt.Surface,
    surface_mailbox: apprt.surface.Mailbox,
};

/// Create resources without starting a worker. All internal addresses are
/// stable before renderer/API initialization sees them. Failure unwinds only
/// resources that have successfully initialized, in reverse order.
pub fn create(alloc: Allocator, opts: Options) !*Self {
    const self = try alloc.create(Self);
    errdefer alloc.destroy(self);
    self.* = .{
        .alloc = alloc,
        .renderer = undefined,
        .thread = undefined,
        .state = .{ .mutex = &self.mutex, .terminal = opts.terminal },
    };
    self.renderer = renderer: {
        var config = try rendererpkg.Renderer.DerivedConfig.init(alloc, opts.config);
        errdefer config.deinit();
        break :renderer try rendererpkg.Renderer.init(alloc, .{
            .config = config,
            .font_grid = opts.font_grid,
            .size = opts.size,
            .surface_mailbox = opts.surface_mailbox,
            .rt_surface = opts.rt_surface,
            .thread = &self.thread,
        });
    };
    errdefer self.renderer.deinit();
    self.thread = try rendererpkg.Thread.init(alloc, opts.config, opts.rt_surface, &self.renderer, &self.state);
    return self;
}

/// Terminal initialization must have completed before starting this worker.
pub fn start(self: *Self) !void {
    try self.startWith(struct {
        fn spawn(worker: *rendererpkg.Thread) std.Thread.SpawnError!std.Thread {
            return std.Thread.spawn(.{}, rendererpkg.Thread.threadMain, .{worker});
        }
    }.spawn);
}

// Keep spawn separate so failure and join ownership can be tested without a GPU.
fn startWith(self: *Self, spawn: *const fn (*rendererpkg.Thread) std.Thread.SpawnError!std.Thread) !void {
    if (self.phase != .ready) return error.InvalidRenderSessionState;
    self.os_thread = try spawn(&self.thread);
    self.phase = .running;
    self.os_thread.?.setName(global.io(), "renderer") catch {};
}

/// Idempotent. Joining also waits for threadExit/loopExit to release GPU work
/// and stop DisplayLink. Shared state and queues remain alive for IO teardown.
pub fn stop(self: *Self) void {
    if (self.os_thread) |thread| {
        self.thread.stop.notify() catch |err| log.err(
            "error notifying renderer thread to stop, may stall err={}",
            .{err},
        );
        thread.join();
        self.os_thread = null;
    }
    self.phase = .stopped;
}

/// No external producer may still access the state, queue or wakeup handle.
pub fn destroy(self: *Self) void {
    self.stop();
    // Release the renderer before queued font-grid transfers relinquish old
    // grids. Surface still owns its current grid until after this returns.
    self.renderer.deinit();
    self.thread.deinit();
    if (self.state.preedit) |preedit| preedit.deinit(self.alloc);
    const alloc = self.alloc;
    alloc.destroy(self);
}

const TestWorker = struct {
    fn fail(_: *rendererpkg.Thread) std.Thread.SpawnError!std.Thread {
        return error.ThreadQuotaExceeded;
    }
    fn spawn(worker: *rendererpkg.Thread) std.Thread.SpawnError!std.Thread {
        return std.Thread.spawn(.{}, run, .{worker});
    }
    fn run(worker: *rendererpkg.Thread) void {
        worker.stop.wait(&worker.loop, &worker.stop_c, rendererpkg.Thread, worker, stopped);
        worker.loop.run(.until_done) catch unreachable;
        // Written only on worker exit; reading after stop proves join completed.
        worker.flags.visible = false;
    }
    fn stopped(worker: ?*rendererpkg.Thread, _: *global.xev.Loop, _: *global.xev.Completion, result: global.xev.Async.WaitError!void) global.xev.CallbackAction {
        result catch unreachable;
        worker.?.loop.stop();
        return .disarm;
    }
};

test "RenderSession failed spawn remains ready and stop joins exactly once" {
    const t = std.testing;
    var config = try configpkg.Config.default(t.allocator);
    defer config.deinit();
    var mutex: std.Io.Mutex = .init;
    var term: terminal.Terminal = undefined;
    var session: Self = .{
        .alloc = t.allocator,
        .renderer = undefined,
        .thread = undefined,
        .state = .{ .mutex = &mutex, .terminal = &term },
    };
    session.thread = try rendererpkg.Thread.init(t.allocator, &config, undefined, &session.renderer, &session.state);
    defer session.thread.deinit();
    defer session.stop();
    try t.expectError(error.ThreadQuotaExceeded, session.startWith(TestWorker.fail));
    try t.expect(session.phase == .ready and session.os_thread == null);
    try session.startWith(TestWorker.spawn);
    try t.expect(session.phase == .running);
    try t.expectError(error.InvalidRenderSessionState, session.startWith(TestWorker.spawn));
    session.stop();
    try t.expect(!session.thread.flags.visible);
    try t.expect(session.phase == .stopped and session.os_thread == null);
    session.stop();
    try t.expectError(error.InvalidRenderSessionState, session.startWith(TestWorker.spawn));
}

test "RenderSession unstarted worker releases queued configuration and search snapshots" {
    const t = std.testing;
    var config = try configpkg.Config.default(t.allocator);
    defer config.deinit();
    var mutex: std.Io.Mutex = .init;
    var term: terminal.Terminal = undefined;
    var session: Self = .{
        .alloc = t.allocator,
        .renderer = undefined,
        .thread = undefined,
        .state = .{ .mutex = &mutex, .terminal = &term },
    };
    var grids = font.SharedGridSet.init(t.allocator);
    defer grids.deinit();
    var font_config = try font.SharedGridSet.DerivedConfig.init(t.allocator, &config);
    defer font_config.deinit();
    const first_key, _ = try grids.ref(&font_config, .{ .points = 12 });
    const second_key, const second_grid = try grids.ref(&font_config, .{ .points = 13 });
    const current_key, const current_grid = try grids.ref(&font_config, .{ .points = 14 });
    {
        session.thread = try rendererpkg.Thread.init(t.allocator, &config, undefined, &session.renderer, &session.state);
        defer session.thread.deinit();
        _ = session.thread.mailbox.push(t.io, .{ .font_grid = .{ .grid = second_grid, .set = &grids, .old_key = first_key, .new_key = second_key } }, .forever);
        _ = session.thread.mailbox.push(t.io, .{ .font_grid = .{ .grid = current_grid, .set = &grids, .old_key = second_key, .new_key = current_key } }, .forever);
        _ = session.thread.mailbox.push(t.io, try rendererpkg.Message.initChangeConfig(t.allocator, &config), .forever);
        var builder = @import("../terminal/main.zig").search.Snapshot.Builder.init(t.allocator);
        defer builder.deinit();
        try builder.append(.empty);
        const viewport = try builder.finish();
        _ = session.thread.mailbox.push(t.io, .{ .search_viewport_matches = viewport }, .forever);
        var selected = std.heap.ArenaAllocator.init(t.allocator);
        _ = try selected.allocator().alloc(u8, 128);
        _ = session.thread.mailbox.push(t.io, .{ .search_selected_match = .{ .arena = selected, .match = .empty } }, .forever);
        session.stop();
        session.stop();
        try t.expect(session.phase == .stopped and session.os_thread == null);
    }
    // Surface owns the newest grid; discarded transfers release both old grids.
    try t.expectEqual(@as(usize, 1), grids.count());
    grids.deref(current_key);
    try t.expectEqual(@as(usize, 0), grids.count());
}
