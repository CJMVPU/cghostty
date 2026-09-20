//! Search session owned by Surface. The heap address remains stable for the
//! worker callback; stop/join precedes release of the shared terminal and queues.
const Self = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const global = @import("../global.zig");
const terminal = @import("../terminal/main.zig");
const renderer = @import("../renderer.zig");
const apprt = @import("../apprt.zig");
const Worker = terminal.search.Thread;
const log = std.log.scoped(.search_session);

alloc: Allocator,
state: Worker,
thread: ?std.Thread = null,
output: Output,

/// These destinations outlive the session and are never changed by its worker.
pub const Output = struct {
    renderer_mailbox: *renderer.Thread.Mailbox,
    renderer_wakeup: *global.xev.Async,
    surface_mailbox: apprt.surface.Mailbox,
};

pub const Options = struct {
    mutex: *std.Io.Mutex,
    terminal: *terminal.Terminal,
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
    self.thread = try std.Thread.spawn(.{}, Worker.threadMain, .{&self.state});
    self.thread.?.setName(global.io(), "search") catch {};
    self.send(.{ .change_needle = needle });
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
            .event_cb = event_cb,
            .event_userdata = self,
        }),
    };
    return self;
}

pub fn destroy(self: *Self) void {
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
    self.send(.{ .change_needle = try Worker.Message.WriteReq.init(self.alloc, query) });
}

pub fn navigate(self: *Self, direction: enum { next, previous }) void {
    self.send(.{ .select = switch (direction) {
        .next => .next,
        .previous => .prev,
    } });
}

fn send(self: *Self, message: Worker.Message) void {
    _ = self.state.mailbox.push(global.io(), message, .forever);
    self.state.wakeup.notify() catch {};
}

// The renderer owns these arenas after enqueue, even if its wakeup fails.
fn cloneMatches(alloc: Allocator, borrowed: []const terminal.highlight.Flattened) !renderer.Message.SearchMatches {
    var arena: ArenaAllocator = .init(alloc);
    errdefer arena.deinit();
    const owned = try arena.allocator().dupe(terminal.highlight.Flattened, borrowed);
    for (owned) |*match| match.* = try match.clone(arena.allocator());
    return .{ .arena = arena, .matches = owned };
}

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
            session.navigate(.next);
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
            var viewport = try cloneMatches(alloc, &.{ source, source });
            defer viewport.arena.deinit();
            var selected = try cloneMatch(alloc, source);
            defer selected.arena.deinit();
            source.chunks.items(.serial)[0] = 9;
            try std.testing.expectEqual(@as(u64, 7), viewport.matches[0].chunks.items(.serial)[0]);
            try std.testing.expectEqual(@as(u64, 7), viewport.matches[1].chunks.items(.serial)[0]);
            try std.testing.expectEqual(@as(u64, 7), selected.match.chunks.items(.serial)[0]);
        }
    }.check, .{});
}

fn forward(
    self: *Self,
    event: terminal.search.Thread.Event,
) !void {
    // NOTE: This runs on the search thread.

    switch (event) {
        .viewport_matches => |matches_unowned| {
            const payload = try cloneMatches(self.alloc, matches_unowned);

            _ = self.output.renderer_mailbox.push(
                global.io(),
                .{ .search_viewport_matches = payload },
                .forever,
            );
            try self.output.renderer_wakeup.notify();
        },

        .selected_match => |selected_| {
            if (selected_) |sel| {
                const payload = try cloneMatch(self.alloc, sel.highlight);

                _ = self.output.renderer_mailbox.push(
                    global.io(),
                    .{ .search_selected_match = payload },
                    .forever,
                );

                // Send the selected index to the surface mailbox
                _ = self.output.surface_mailbox.push(
                    .{ .search_selected = sel.idx },
                    .forever,
                );
            } else {
                // Reset our selected match
                _ = self.output.renderer_mailbox.push(
                    global.io(),
                    .{ .search_selected_match = null },
                    .forever,
                );

                // Reset the selected index
                _ = self.output.surface_mailbox.push(
                    .{ .search_selected = null },
                    .forever,
                );
            }

            try self.output.renderer_wakeup.notify();
        },

        .total_matches => |total| {
            _ = self.output.surface_mailbox.push(
                .{ .search_total = total },
                .forever,
            );
        },

        // When we quit, tell our renderer to reset any search state.
        .quit => {
            _ = self.output.renderer_mailbox.push(
                global.io(),
                .{ .search_selected_match = null },
                .forever,
            );
            _ = self.output.renderer_mailbox.push(
                global.io(),
                .{ .search_viewport_matches = .{
                    .arena = .init(self.alloc),
                    .matches = &.{},
                } },
                .forever,
            );
            try self.output.renderer_wakeup.notify();

            // Reset search totals in the surface
            _ = self.output.surface_mailbox.push(
                .{ .search_total = null },
                .forever,
            );
            _ = self.output.surface_mailbox.push(
                .{ .search_selected = null },
                .forever,
            );
        },

        // Unhandled, so far.
        .complete => {},
    }
}
