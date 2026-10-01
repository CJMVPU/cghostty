//! Search session owned by Surface. The heap address remains stable for the
//! worker callback; stop/join precedes release of the shared terminal and queues.
const Self = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const global = @import("../global.zig");
const terminal = @import("../terminal/main.zig");
const renderer = @import("../renderer.zig");
const Worker = terminal.search.Thread;
const log = std.log.scoped(.search_session);

alloc: Allocator,
state: Worker,
thread: ?std.Thread = null,
output: Output,
ui_mutex: std.Io.Mutex = .init,
ui: UI = .{},
ui_pending: bool = false,

pub const UI = struct { total: ?usize = null, selected: ?usize = null };

pub fn takeUI(self: *Self) ?UI {
    self.ui_mutex.lockUncancelable(global.io());
    defer self.ui_mutex.unlock(global.io());
    if (!self.ui_pending) return null;
    self.ui_pending = false;
    return self.ui;
}

/// These destinations outlive the session and are never changed by its worker.
pub const Output = struct {
    renderer_results: *@import("../renderer/SearchResults.zig"),
    renderer_wakeup: *global.xev.Async,
    app_wakeup: *const fn (?*anyopaque) void,
    app_userdata: ?*anyopaque,
};

pub const Options = struct {
    mutex: *std.Io.Mutex,
    terminal: *terminal.Terminal,
    changes: ?*terminal.search.ChangeSignal = null,
    output: Output,
};

/// Publish only the returned pointer. Any initialization/spawn failure releases
/// both the worker state and initial query without leaving a partial session.
pub fn create(alloc: Allocator, opts: Options, query: []const u8) !*Self {
    std.debug.assert(query.len > 0);
    const needle = try Worker.Message.WriteReq.init(alloc, query);
    errdefer needle.deinit();
    const self = try init(alloc, opts, callback);
    errdefer self.destroy();
    if (opts.changes) |changes| changes.attach(&self.state.wakeup);
    self.thread = try std.Thread.spawn(.{}, Worker.threadMain, .{&self.state});
    self.thread.?.setName(global.io(), "search") catch {};
    try self.send(.{ .change_needle = needle });
    return self;
}

fn init(alloc: Allocator, opts: Options, event_cb: ?Worker.EventCallback) !*Self {
    const self = try alloc.create(Self);
    errdefer alloc.destroy(self);
    self.* = .{
        .alloc = alloc,
        .output = opts.output,
        .state = try Worker.init(alloc, .{
            .mutex = opts.mutex,
            .terminal = opts.terminal,
            .changes = opts.changes,
            .event_cb = event_cb,
            .event_userdata = self,
        }),
    };
    return self;
}

pub fn destroy(self: *Self) void {
    if (self.state.opts.changes) |changes| changes.detach();
    if (self.thread) |thread| {
        self.state.stop.notify() catch |err| log.err(
            "error notifying search thread to stop, may stall err={}",
            .{err},
        );
        thread.join();
    }
    self.state.deinit();
    const alloc = self.alloc;
    alloc.destroy(self);
}

pub fn setQuery(self: *Self, query: []const u8) !void {
    std.debug.assert(query.len > 0);
    const needle = try Worker.Message.WriteReq.init(self.alloc, query);
    errdefer needle.deinit();
    try self.send(.{ .change_needle = needle });
}

pub fn navigate(self: *Self, direction: enum { next, previous }) !void {
    try self.send(.{ .select = switch (direction) {
        .next => .next,
        .previous => .prev,
    } });
}

fn send(self: *Self, message: Worker.Message) !void {
    try self.state.mailbox.push(global.io(), message);
    self.state.wakeup.notify() catch {};
}

// The result channel owns these arenas after publication, even if wakeup fails.
fn cloneMatch(alloc: Allocator, borrowed: terminal.highlight.Flattened) !renderer.Message.SearchMatch {
    var arena: ArenaAllocator = .init(alloc);
    errdefer arena.deinit();
    const owned = try borrowed.clone(arena.allocator());
    return .{ .arena = arena, .match = owned };
}

fn callback(event: terminal.search.Thread.Event, ud: ?*anyopaque) void {
    // Runs on the search thread. Only immutable output dependencies are
    // accessed; destroy joins this thread before releasing the callback context.
    const self: *Self = @ptrCast(@alignCast(ud.?));
    self.forward(event) catch |err| {
        log.warn("error in search callback err={}", .{err});
    };
}

test "SearchSession initialization and queued queries unwind on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn check(alloc: Allocator) !void {
            // No worker is started: this is the same cleanup used if spawn fails.
            var mutex: std.Io.Mutex = .init;
            var term: terminal.Terminal = undefined;
            const session = try init(alloc, .{ .mutex = &mutex, .terminal = &term, .output = undefined }, null);
            defer session.destroy();
            try std.testing.expectEqual(@as(?*anyopaque, session), session.state.opts.event_userdata);
            var text = [_]u8{'x'} ** 512;
            try session.setQuery(&text);
            text[0] = 'y';
            const message = session.state.mailbox.pop(global.io()).?;
            defer message.change_needle.deinit();
            try std.testing.expectEqual(@as(u8, 'x'), message.change_needle.slice()[0]);
            // Unconsumed allocated messages must be released during destruction.
            try session.setQuery(&text);
            try session.navigate(.next);
            try session.setQuery(&text);
        }
    }.check, .{});
}

test "SearchSession snapshots own highlight chunks and unwind partial copies" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn check(alloc: Allocator) !void {
            var source: terminal.highlight.Flattened = .empty;
            defer source.deinit(std.testing.allocator);
            var node: terminal.PageList.List.Node = undefined;
            try source.chunks.append(std.testing.allocator, .{ .node = &node, .serial = 7, .start = 0, .end = 2 });
            var builder = terminal.search.Snapshot.Builder.init(alloc);
            defer builder.deinit();
            try builder.append(source);
            try builder.append(source);
            const viewport = try builder.finish();
            defer viewport.deinit();
            var selected = try cloneMatch(alloc, source);
            defer selected.arena.deinit();
            source.chunks.items(.serial)[0] = 9;
            try std.testing.expectEqual(@as(u64, 7), viewport.matches[0].chunks.items(.serial)[0]);
            try std.testing.expectEqual(@as(u64, 7), viewport.matches[1].chunks.items(.serial)[0]);
            try std.testing.expectEqual(@as(u64, 7), selected.match.chunks.items(.serial)[0]);
        }
    }.check, .{});
}

fn forward(self: *Self, event: terminal.search.Thread.Event) !void {
    switch (event) {
        .viewport_matches => |matches| {
            self.output.renderer_results.publishMatches(matches.retain());
            try self.output.renderer_wakeup.notify();
        },
        .selected_match => |selected| {
            const owned = if (selected) |sel| try cloneMatch(self.alloc, sel.highlight) else null;
            self.output.renderer_results.publishSelected(owned);
            self.ui_mutex.lockUncancelable(global.io());
            self.ui.selected = if (selected) |sel| sel.idx else null;
            self.ui_pending = true;
            self.ui_mutex.unlock(global.io());
            self.output.app_wakeup(self.output.app_userdata);
            try self.output.renderer_wakeup.notify();
        },
        .total_matches => |total| {
            self.ui_mutex.lockUncancelable(global.io());
            self.ui.total = total;
            self.ui_pending = true;
            self.ui_mutex.unlock(global.io());
            self.output.app_wakeup(self.output.app_userdata);
        },
        .quit => {
            // The main thread may be joining us. No shutdown callback waits
            // for it or for the renderer to consume a bounded mailbox.
            self.output.renderer_results.clear();
            try self.output.renderer_wakeup.notify();
        },
        .complete => {},
    }
}

test "SearchSession shutdown completes with full app and renderer queues" {
    const t = std.testing;
    const app_queue = try @import("../App.zig").Mailbox.Queue.create(t.allocator);
    defer app_queue.destroy(t.allocator);
    const render_queue = try renderer.Thread.Mailbox.create(t.allocator);
    defer render_queue.destroy(t.allocator);
    for (0..64) |_| {
        _ = app_queue.push(t.io, .quit, .forever);
        _ = render_queue.push(t.io, .reset_cursor_blink, .forever);
    }
    var results: @import("../renderer/SearchResults.zig") = .{};
    defer results.deinit();
    var wake = try global.xev.Async.init();
    defer wake.deinit();
    var mutex: std.Io.Mutex = .init;
    var term = try terminal.Terminal.init(t.io, t.allocator, .{ .cols = 10, .rows = 2 });
    defer term.deinit(t.allocator);
    const opts: Options = .{ .mutex = &mutex, .terminal = &term, .output = .{
        .renderer_results = &results,
        .renderer_wakeup = &wake,
        .app_wakeup = struct {
            fn notify(_: ?*anyopaque) void {}
        }.notify,
        .app_userdata = null,
    } };
    const ui_session = try init(t.allocator, opts, null);
    try ui_session.forward(.{ .total_matches = 5 });
    try ui_session.forward(.{ .selected_match = null });
    try t.expectEqual(UI{ .total = 5, .selected = null }, ui_session.takeUI().?);
    try t.expect(ui_session.takeUI() == null);
    ui_session.destroy();
    for (0..3) |_| {
        const session = try create(t.allocator, opts, "needle");
        // destroy must finish without either queue being drained. The actual
        // worker executes the quit callback before the join returns.
        session.destroy();
        var cleared = results.take();
        defer cleared.deinit();
        try t.expect(cleared.selected_changed);
        try t.expect(cleared.selected == null);
    }
    for (0..64) |_| {
        try t.expect(app_queue.pop(t.io) != null);
        try t.expect(render_queue.pop(t.io) != null);
    }
}
