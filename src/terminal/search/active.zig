const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const point = @import("../point.zig");
const size = @import("../size.zig");
const FlattenedHighlight = @import("../highlight.zig").Flattened;
const PageList = @import("../PageList.zig");
const SlidingWindow = @import("sliding_window.zig").SlidingWindow;
const Terminal = @import("../Terminal.zig");

/// Searches for a substring within the active area of a PageList.
///
/// The distinction for "active area" is important because it is the
/// only part of a PageList that is mutable. Therefore, its the only part
/// of the terminal that needs to be repeatedly searched as the contents
/// change.
///
/// This struct specializes in searching only within that active area,
/// and handling the active area moving as new lines are added to the bottom.
pub const ActiveSearch = struct {
    window: SlidingWindow,

    pub fn init(
        alloc: Allocator,
        needle: []const u8,
    ) Allocator.Error!ActiveSearch {
        // We just do a forward search since the active area is usually
        // pretty small so search results are instant anyways. This avoids
        // a small amount of work to reverse things.
        var window: SlidingWindow = try .init(alloc, .forward, needle);
        errdefer window.deinit();
        return .{ .window = window };
    }

    pub fn deinit(self: *ActiveSearch) void {
        self.window.deinit();
    }

    /// Update the active area to reflect the current state of the PageList.
    ///
    /// This doesn't do the search, it only copies the necessary data
    /// to perform the search later. This lets the caller hold the lock
    /// on the PageList for a minimal amount of time.
    ///
    /// This returns the first page (in reverse order) covered by this
    /// search. This allows the history search to overlap and search history.
    /// There CAN BE duplicates, and this page CAN BE mutable, so the history
    /// search results should prune anything that's in the active area.
    ///
    /// If the return value is null it means the active area covers the entire
    /// PageList, currently.
    pub fn update(
        self: *ActiveSearch,
        list: *const PageList,
    ) Allocator.Error!?*PageList.List.Node {
        // Clear our previous sliding window
        self.window.clearAndRetainCapacity();

        // An empty needle represents an inactive search and has no overlap
        // or history to load.
        if (self.window.needle.len == 0) return null;

        // Find the first active page without encoding pages in reverse order.
        var rem: usize = list.rows;
        var node_ = list.pages.last;
        var last_node: ?*PageList.List.Node = null;
        while (node_) |node| : (node_ = node.prev) {
            last_node = node;

            // If we reached our target amount, then this is the last
            // page that contains the active area. We go to the previous
            // page once more since its the first page of our required
            // overlap.
            if (rem <= node.rows()) {
                node_ = node.prev;
                break;
            }

            rem -= node.rows();
        }

        // Next, add enough overlap to cover needle.len - 1 bytes (if it
        // exists) so we can cover the overlap.
        var overlap_remaining = self.window.needle.len - 1;
        while (node_) |node| : (node_ = node.prev) {
            // We could be more accurate here and count bytes since the
            // last wrap but its complicated and unlikely multiple pages
            // wrap so this should be fine.
            const appended = try self.window.prependIfWrapped(node) orelse break;
            overlap_remaining -|= appended.content_len;
            if (overlap_remaining == 0) break;
        }

        // Forward matching and its byte-to-cell map require chronological pages.
        node_ = last_node;
        while (node_) |node| : (node_ = node.next) {
            _ = try self.window.append(node);
        }

        // Return the last node we added to our window.
        return last_node;
    }

    /// Find the next match for the needle in the active area. This returns
    /// null when there are no more matches.
    pub fn next(self: *ActiveSearch) ?FlattenedHighlight {
        return self.window.next();
    }
};

test "simple search" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("Fizz\r\nBuzz\r\nFizz\r\nBang");

    var search: ActiveSearch = try .init(alloc, "Fizz");
    defer search.deinit();
    _ = try search.update(&t.screens.active.pages);

    {
        const h = search.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 3,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.active, sel.end).?);
    }
    {
        const h = search.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 2,
        } }, t.screens.active.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 3,
            .y = 2,
        } }, t.screens.active.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect(search.next() == null);
}

test "clear screen and search" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("Fizz\r\nBuzz\r\nFizz\r\nBang");

    var search: ActiveSearch = try .init(alloc, "Fizz");
    defer search.deinit();
    _ = try search.update(&t.screens.active.pages);

    s.nextSlice("\x1b[2J"); // Clear screen
    s.nextSlice("\x1b[H"); // Move cursor home
    s.nextSlice("Buzz\r\nFizz\r\nBuzz");
    _ = try search.update(&t.screens.active.pages);

    {
        const h = search.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 1,
        } }, t.screens.active.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 3,
            .y = 1,
        } }, t.screens.active.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect(search.next() == null);
}

test "active search finds a soft-wrapped match across page boundaries" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(testing.io, alloc, .{ .cols = 10, .rows = 2 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();

    const first = t.screens.active.pages.pages.first.?;
    for (0..first.capacity().rows - 1) |_| stream.nextSlice("\r\n");
    try testing.expect(first == t.screens.active.pages.pages.last);
    stream.nextSlice("xxxxxxxABCDEF");
    try testing.expect(first != t.screens.active.pages.pages.last);

    var search: ActiveSearch = try .init(alloc, "ABCDEF");
    defer search.deinit();
    _ = try search.update(&t.screens.active.pages);
    const match = search.next();
    try testing.expect(match != null);
    const sel = match.?.untracked();
    try testing.expectEqual(point.Point{ .active = .{ .x = 7, .y = 0 } }, t.screens.active.pages.pointFromPin(.active, sel.start).?);
    try testing.expectEqual(point.Point{ .active = .{ .x = 2, .y = 1 } }, t.screens.active.pages.pointFromPin(.active, sel.end).?);
    try testing.expect(search.next() == null);

    var screen_search = try @import("screen.zig").ScreenSearch.init(alloc, t.screens.active, "ABCDEF");
    defer screen_search.deinit();
    try screen_search.searchAll();
    try testing.expectEqual(@as(usize, 1), screen_search.active_results.items.len);
    try testing.expectEqual(@as(usize, 0), screen_search.history_results.items.len);
}

test "active search keeps multipage results in chronological order" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(testing.io, alloc, .{ .cols = 10, .rows = 2 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    const first = t.screens.active.pages.pages.first.?;
    for (0..first.capacity().rows - 1) |_| stream.nextSlice("\r\n");
    stream.nextSlice("hit\r\nhit");
    try testing.expect(first != t.screens.active.pages.pages.last);

    var search = try @import("screen.zig").ScreenSearch.init(alloc, t.screens.active, "hit");
    defer search.deinit();
    try search.searchAll();
    try testing.expectEqual(@as(usize, 2), search.active_results.items.len);
    for (0..2) |idx| {
        const sel = search.matchAt(idx).?.untracked();
        try testing.expectEqual(point.Point{ .active = .{ .x = 0, .y = @intCast(1 - idx) } }, t.screens.active.pages.pointFromPin(.active, sel.start).?);
    }
}
