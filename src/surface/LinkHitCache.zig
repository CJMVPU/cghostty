//! One logical line's ordered regex hits, reused by hover and click lookup.
//! Untracked selections may only be read while the terminal mutex is held and
//! the mutation/page/viewport identity still matches. Configuration invalidates
//! explicitly. Cached storage is bounded; oversized results use direct lookup.
const Self = @This();
const std = @import("std");
const terminal = @import("../terminal/main.zig");
const input = @import("../input.zig");
const pcre2 = @import("pcre2");
const max_hits = 1024;

pub const Entry = struct { regex: pcre2.Regex, action: input.Link.Action, highlight: input.Link.Highlight };
pub const Hit = struct { action: input.Link.Action, selection: terminal.Selection };
const Key = struct { content: terminal.accessibility.Tracker.Key, mods: ?input.Mods };
key: ?Key = null,
line: ?terminal.Selection = null,
hits: std.ArrayList(Hit) = .empty,
rebuilds: usize = 0,

pub fn invalidate(self: *Self) void {
    self.key = null;
    self.line = null;
    self.hits.clearRetainingCapacity();
}
pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
    self.hits.deinit(alloc);
    self.* = .{};
}

pub fn lookup(self: *Self, alloc: std.mem.Allocator, term: *const terminal.Terminal, pin: terminal.Pin, mods: ?input.Mods, entries: []const Entry) !?Hit {
    if (entries.len == 0) return null;
    const screen = term.screens.active;
    const key: Key = .{ .content = .read(term), .mods = mods };
    if (self.key != null and std.meta.eql(self.key.?, key) and self.line.?.contains(screen, pin)) {
        for (self.hits.items) |hit| if (hit.selection.contains(screen, pin)) return hit;
        return null;
    }
    self.invalidate();
    const line = screen.selectLine(.{ .pin = pin, .whitespace = null, .semantic_prompt_boundary = true }) orelse return null;
    const map = try screen.selectionStringMap(alloc, .{ .sel = line, .trim = false });
    defer map.deinit(alloc);
    self.rebuilds += 1;
    var found: ?Hit = null;
    var cacheable = true;
    for (entries) |entry| {
        if (mods) |value| switch (entry.highlight) {
            .always, .hover => {},
            .always_mods, .hover_mods => |required| if (!required.equal(value)) continue,
        };
        var it = try map.searchIterator(entry.regex);
        defer it.deinit();
        while (try it.next()) |match| {
            const hit: Hit = .{ .action = entry.action, .selection = match.selection() };
            if (found == null and hit.selection.contains(screen, pin)) found = hit;
            if (self.hits.items.len == max_hits) cacheable = false;
            if (cacheable) try self.hits.append(alloc, hit);
            // Once storage is exhausted, behave like uncached first-hit lookup.
            if (!cacheable and found != null) return found;
        }
    }
    if (cacheable) {
        self.line = line;
        self.key = key;
    }
    return found;
}

test "LinkHitCache reuses hits and misses but invalidates text mods viewport and config" {
    const t = std.testing;
    var term = try terminal.Terminal.init(t.io, t.allocator, .{ .cols = 40, .rows = 3 });
    defer term.deinit(t.allocator);
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("abc def");
    var cache: Self = .{};
    defer cache.deinit(t.allocator);
    var regex = try pcre2.Regex.init("abc|def");
    defer regex.deinit();
    const entries = [_]Entry{.{ .regex = regex, .action = .open, .highlight = .hover }};
    for (0..7) |x| {
        const pin = term.screens.active.pages.pin(.{ .viewport = .{ .x = @intCast(x), .y = 0 } }).?;
        const hit = try cache.lookup(t.allocator, &term, pin, .{}, &entries);
        try t.expect((hit != null) == (x != 3));
    }
    try t.expectEqual(@as(usize, 1), cache.rebuilds);
    const pin = term.screens.active.pages.pin(.{ .viewport = .{ .x = 0, .y = 0 } }).?;
    _ = try cache.lookup(t.allocator, &term, pin, .{ .shift = true }, &entries);
    try t.expectEqual(@as(usize, 2), cache.rebuilds);
    stream.nextSlice("\rxyz");
    try t.expectEqual(null, try cache.lookup(t.allocator, &term, pin, .{ .shift = true }, &entries));
    try t.expectEqual(@as(usize, 3), cache.rebuilds);
    cache.invalidate();
    _ = try cache.lookup(t.allocator, &term, pin, .{ .shift = true }, &entries);
    try t.expectEqual(@as(usize, 4), cache.rebuilds);
    stream.nextSlice("\r\nline2\r\nline3\r\nline4");
    const moved = term.screens.active.pages.pin(.{ .viewport = .{ .x = 0, .y = 0 } }).?;
    _ = try cache.lookup(t.allocator, &term, moved, .{}, &entries);
    try t.expectEqual(@as(usize, 5), cache.rebuilds);
}

test "LinkHitCache preserves overlapping rule priority and invalidates after screen switch" {
    const t = std.testing;
    var term = try terminal.Terminal.init(t.io, t.allocator, .{ .cols = 20, .rows = 2 });
    defer term.deinit(t.allocator);
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("abc def");
    var cache: Self = .{};
    defer cache.deinit(t.allocator);
    var first = try pcre2.Regex.init("def");
    defer first.deinit();
    var second = try pcre2.Regex.init("abc def");
    defer second.deinit();
    const entries = [_]Entry{
        .{ .regex = first, .action = .open, .highlight = .hover },
        .{ .regex = second, .action = .open, .highlight = .hover },
    };
    const begin = term.screens.active.pages.pin(.{ .viewport = .{ .x = 0, .y = 0 } }).?;
    const later = term.screens.active.pages.pin(.{ .viewport = .{ .x = 5, .y = 0 } }).?;
    try t.expectEqual(@as(terminal.size.CellCountInt, 0), (try cache.lookup(t.allocator, &term, begin, null, &entries)).?.selection.start().x);
    try t.expectEqual(@as(terminal.size.CellCountInt, 4), (try cache.lookup(t.allocator, &term, later, null, &entries)).?.selection.start().x);
    try t.expectEqual(@as(usize, 1), cache.rebuilds);
    stream.nextSlice("\x1b[?1049hother");
    const alternate = term.screens.active.pages.pin(.{ .viewport = .{ .x = 0, .y = 0 } }).?;
    try t.expectEqual(null, try cache.lookup(t.allocator, &term, alternate, null, &entries));
    try t.expectEqual(@as(usize, 2), cache.rebuilds);
}

test "LinkHitCache bounds retained hits and retries failed rebuilds" {
    const t = std.testing;
    var term = try terminal.Terminal.init(t.io, t.allocator, .{ .cols = 1100, .rows = 2 });
    defer term.deinit(t.allocator);
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("a" ** 1100);
    var cache: Self = .{};
    defer cache.deinit(t.allocator);
    var regex = try pcre2.Regex.init("a");
    defer regex.deinit();
    const entries = [_]Entry{.{ .regex = regex, .action = .open, .highlight = .hover }};
    const pin = term.screens.active.pages.pin(.{ .viewport = .{ .x = 1099, .y = 0 } }).?;
    try t.expect((try cache.lookup(t.allocator, &term, pin, null, &entries)) != null);
    try t.expect(cache.hits.items.len <= max_hits);
    try t.expectEqual(null, cache.key);
    var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    try t.expectError(error.OutOfMemory, cache.lookup(failing.allocator(), &term, pin, null, &entries));
    try t.expectEqual(null, cache.key);
    try t.expect((try cache.lookup(t.allocator, &term, pin, null, &entries)) != null);
}
