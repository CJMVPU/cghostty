const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const pcre2 = @import("pcre2");
const inputpkg = @import("../input.zig");
const terminal = @import("../terminal/main.zig");
const point = terminal.point;
const Screen = terminal.Screen;
const Terminal = terminal.Terminal;

const log = std.log.scoped(.renderer_link);

/// The link configuration needed for renderers.
pub const Link = struct {
    /// The regular expression to match the link against.
    regex: pcre2.Regex,

    /// The situations in which the link should be highlighted.
    highlight: inputpkg.Link.Highlight,

    pub fn deinit(self: *Link) void {
        self.regex.deinit();
    }

    /// Returns true if this link's highlight condition matches the given mouse state.
    fn active(
        self: *const Link,
        mouse_viewport: ?point.Coordinate,
        mouse_mods: inputpkg.Mods,
    ) bool {
        return switch (self.highlight) {
            .always => true,
            .always_mods => |v| mouse_mods.equal(v),
            .hover => mouse_viewport != null,
            .hover_mods => |v| mouse_viewport != null and mouse_mods.equal(v),
        };
    }
};

/// A set of links. This provides a higher level API for renderers
/// to match against a viewport and determine if cells are part of
/// a link.
pub const Set = struct {
    links: []Link,

    /// Returns the slice of links from the configuration.
    pub fn fromConfig(
        alloc: Allocator,
        config: []const inputpkg.Link,
    ) !Set {
        var links: std.ArrayList(Link) = .empty;
        defer links.deinit(alloc);
        errdefer for (links.items) |*link| link.deinit();

        for (config) |link| {
            var regex = try link.compileRegex();
            errdefer regex.deinit();
            try links.append(alloc, .{
                .regex = regex,
                .highlight = link.highlight,
            });
        }

        return .{ .links = try links.toOwnedSlice(alloc) };
    }

    pub fn deinit(self: *Set, alloc: Allocator) void {
        for (self.links) |*link| link.deinit();
        alloc.free(self.links);
    }

    /// Fills matches with the matches from regex link matches.
    pub fn renderCellMap(
        self: *const Set,
        alloc: Allocator,
        result: *terminal.RenderState.CellSet,
        render_state: *const terminal.RenderState,
        mouse_viewport: ?point.Coordinate,
        mouse_mods: inputpkg.Mods,
    ) !void {
        // Fast path, not very likely since we have default links.
        if (self.links.len == 0) return;

        // Determine if any links are active before building the string and
        // byte-to-cell map. Those buffers scale with viewport size and this
        // function runs during frame updates, so avoid allocating them when
        // the current mouse/modifier state can't highlight any regex links.
        for (self.links) |*link| {
            if (link.active(mouse_viewport, mouse_mods)) break;
        } else return;

        // Convert our render state to a string + byte map.
        var builder: std.Io.Writer.Allocating = .init(alloc);
        defer builder.deinit();
        var map: terminal.RenderState.StringMap = .empty;
        defer map.deinit(alloc);
        try render_state.string(&builder.writer, .{
            .alloc = alloc,
            .map = &map,
        });

        const str = builder.writer.buffered();

        // Go through each link and see if we have any matches.
        for (self.links) |*link| {
            if (!link.active(mouse_viewport, mouse_mods)) continue;

            var matcher = try link.regex.matcher();
            defer matcher.deinit();
            var offset: usize = 0;
            while (offset < str.len) {
                const region = matcher.search(
                    str[offset..],
                    0,
                ) catch |err| switch (err) {
                    error.NoMatch, error.MatchLimitExceeded => break,
                    else => return err,
                };

                // We have a match!
                const offset_start: usize = region.start;
                const offset_end: usize = region.end;
                const start = offset + offset_start;
                const end = offset + offset_end;

                // Increment our offset by the number of bytes in the match.
                // We defer this so that we can return the match before
                // modifying the offset.
                defer offset = end;

                switch (link.highlight) {
                    .always, .always_mods => {},
                    .hover, .hover_mods => if (mouse_viewport) |vp| {
                        for (map.items[start..end]) |pt| {
                            if (pt.eql(vp)) break;
                        } else continue;
                    } else continue,
                }

                // Record the match
                for (map.items[start..end]) |pt| {
                    try result.put(alloc, pt, {});
                }
            }
        }
    }
};

/// One viewport's regex results. Mouse movement only selects cached ranges;
/// text/layout/config changes rebuild them. Owns no terminal page pointers.
pub const Cache = struct {
    key: ?Key = null,
    map: terminal.RenderState.StringMap = .empty,
    ranges: std.ArrayList(Range) = .empty,
    rebuilds: usize = 0,
    text: ?std.Io.Writer.Allocating = null,
    matchers: std.ArrayList(pcre2.Matcher) = .empty,
    const max_cached_matchers = 16;
    const max_text_capacity = 256 * 1024;

    const Key = struct {
        content: terminal.accessibility.Tracker.Key,
        mods: inputpkg.Mods,
        mouse_present: bool,
    };
    const Range = struct { start: usize, end: usize, hover: bool };

    pub fn deinit(self: *Cache, alloc: Allocator) void {
        self.invalidate(alloc);
        if (self.text) |*text| text.deinit();
        self.map.deinit(alloc);
        self.ranges.deinit(alloc);
        self.* = .{};
    }

    pub fn invalidate(self: *Cache, alloc: Allocator) void {
        self.key = null;
        for (self.matchers.items) |*matcher| matcher.deinit();
        self.matchers.deinit(alloc);
        self.matchers = .empty;
    }

    fn prepareMatchers(self: *Cache, alloc: Allocator, set: *const Set) !void {
        const count = @min(set.links.len, max_cached_matchers);
        try self.matchers.ensureTotalCapacity(alloc, count);
        while (self.matchers.items.len < count) {
            const index = self.matchers.items.len;
            self.matchers.appendAssumeCapacity(try set.links[index].regex.matcher());
        }
    }

    pub fn render(
        self: *Cache,
        alloc: Allocator,
        result_alloc: Allocator,
        set: *const Set,
        result: *terminal.RenderState.CellSet,
        state: *const terminal.RenderState,
        content: terminal.accessibility.Tracker.Key,
        mouse: ?point.Coordinate,
        mods: inputpkg.Mods,
    ) !void {
        for (set.links) |*entry| {
            if (entry.active(mouse, mods)) break;
        } else return;
        const key: Key = .{ .content = content, .mods = mods, .mouse_present = mouse != null };
        if (self.key == null or !std.meta.eql(self.key.?, key)) {
            // Release oversized buffers after a resize instead of keeping a
            // previous giant viewport alive for the surface's whole lifetime.
            if (self.key) |old| {
                if (old.content.cols != content.cols or old.content.rows != content.rows) self.deinit(alloc);
            }
            self.key = null; // Errors must never publish a partially built cache.
            self.map.clearRetainingCapacity();
            self.ranges.clearRetainingCapacity();
            if (self.text == null) self.text = .init(alloc);
            const text = &self.text.?;
            text.clearRetainingCapacity();
            defer if (text.writer.buffer.len > max_text_capacity) {
                text.deinit();
                self.text = null;
            };
            try state.string(&text.writer, .{ .alloc = alloc, .map = &self.map });
            const str = text.writer.buffered();
            try self.prepareMatchers(alloc, set);
            for (set.links, 0..) |*entry, index| {
                if (!entry.active(mouse, mods)) continue;
                var temporary: ?pcre2.Matcher = if (index >= self.matchers.items.len) try entry.regex.matcher() else null;
                defer if (temporary) |*matcher| matcher.deinit();
                const matcher = if (temporary) |*m| m else &self.matchers.items[index];
                var offset: usize = 0;
                while (offset < str.len) {
                    const match = matcher.search(str[offset..], 0) catch |err| switch (err) {
                        error.NoMatch, error.MatchLimitExceeded => break,
                        else => return err,
                    };
                    try self.ranges.append(alloc, .{
                        .start = offset + match.start,
                        .end = offset + match.end,
                        .hover = switch (entry.highlight) {
                            .hover, .hover_mods => true,
                            else => false,
                        },
                    });
                    offset += match.end;
                }
            }
            self.key = key;
            self.rebuilds += 1;
        }
        for (self.ranges.items) |range| {
            const cells = self.map.items[range.start..range.end];
            if (range.hover) {
                const vp = mouse orelse continue;
                for (cells) |cell| {
                    if (cell.eql(vp)) break;
                } else continue;
            }
            for (cells) |cell| try result.put(result_alloc, cell, {});
        }
    }
};

test "renderCellMap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(testing.io, alloc, .{
        .cols = 5,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    const str = "1ABCD2EFGH\r\n3IJKL";
    s.nextSlice(str);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get a set
    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = "AB",
            .action = .{ .open = {} },
            .highlight = .{ .always = {} },
        },

        .{
            .regex = "EF",
            .action = .{ .open = {} },
            .highlight = .{ .always = {} },
        },
    });
    defer set.deinit(alloc);

    // Get our matches
    var result: terminal.RenderState.CellSet = .empty;
    defer result.deinit(alloc);
    try set.renderCellMap(
        alloc,
        &result,
        &state,
        null,
        .{},
    );
    try testing.expect(!result.contains(.{ .x = 0, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 1, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 2, .y = 0 }));
    try testing.expect(!result.contains(.{ .x = 3, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 1, .y = 1 }));
    try testing.expect(!result.contains(.{ .x = 1, .y = 2 }));
}

test "renderCellMap ignores empty matches and exhausted budgets" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t: terminal.Terminal = try .init(testing.io, alloc, .{ .cols = 40, .rows = 2 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("a" ** 30 ++ "!");
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    var set = try Set.fromConfig(alloc, &.{
        .{ .regex = "(?=a)", .action = .{ .open = {} }, .highlight = .always },
        .{ .regex = "(*NO_START_OPT)(*NO_AUTO_POSSESS)^(a+)+$", .action = .{ .open = {} }, .highlight = .always },
        .{ .regex = "!", .action = .{ .open = {} }, .highlight = .always },
    });
    defer set.deinit(alloc);
    var result: terminal.RenderState.CellSet = .empty;
    defer result.deinit(alloc);
    try set.renderCellMap(alloc, &result, &state, null, .{});
    try testing.expectEqual(@as(usize, 1), result.count());
    try testing.expect(result.contains(.{ .x = 30, .y = 0 }));
}

test "renderCellMap hover links" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(testing.io, alloc, .{
        .cols = 5,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    const str = "1ABCD2EFGH\r\n3IJKL";
    s.nextSlice(str);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get a set
    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = "AB",
            .action = .{ .open = {} },
            .highlight = .{ .hover = {} },
        },

        .{
            .regex = "EF",
            .action = .{ .open = {} },
            .highlight = .{ .always = {} },
        },
    });
    defer set.deinit(alloc);

    // Not hovering over the first link
    {
        var result: terminal.RenderState.CellSet = .empty;
        defer result.deinit(alloc);
        try set.renderCellMap(
            alloc,
            &result,
            &state,
            null,
            .{},
        );

        // Test our matches
        try testing.expect(!result.contains(.{ .x = 0, .y = 0 }));
        try testing.expect(!result.contains(.{ .x = 1, .y = 0 }));
        try testing.expect(!result.contains(.{ .x = 2, .y = 0 }));
        try testing.expect(!result.contains(.{ .x = 3, .y = 0 }));
        try testing.expect(result.contains(.{ .x = 1, .y = 1 }));
        try testing.expect(!result.contains(.{ .x = 1, .y = 2 }));
    }

    // Hovering over the first link
    {
        var result: terminal.RenderState.CellSet = .empty;
        defer result.deinit(alloc);
        try set.renderCellMap(
            alloc,
            &result,
            &state,
            .{ .x = 1, .y = 0 },
            .{},
        );

        // Test our matches
        try testing.expect(!result.contains(.{ .x = 0, .y = 0 }));
        try testing.expect(result.contains(.{ .x = 1, .y = 0 }));
        try testing.expect(result.contains(.{ .x = 2, .y = 0 }));
        try testing.expect(!result.contains(.{ .x = 3, .y = 0 }));
        try testing.expect(result.contains(.{ .x = 1, .y = 1 }));
        try testing.expect(!result.contains(.{ .x = 1, .y = 2 }));
    }
}

test "renderCellMap inactive links don't allocate" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t: terminal.Terminal = try .init(io, alloc, .{
        .cols = 5,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    const str = "1ABCD2EFGH\r\n3IJKL";
    s.nextSlice(str);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = "AB",
            .action = .{ .open = {} },
            .highlight = .{ .hover = {} },
        },

        .{
            .regex = "EF",
            .action = .{ .open = {} },
            .highlight = .{ .always_mods = .{ .ctrl = true } },
        },

        .{
            .regex = "IJ",
            .action = .{ .open = {} },
            .highlight = .{ .hover_mods = .{ .shift = true } },
        },
    });
    defer set.deinit(alloc);

    var failing = std.testing.FailingAllocator.init(
        alloc,
        .{ .fail_index = 0 },
    );
    const failing_alloc = failing.allocator();

    var result: terminal.RenderState.CellSet = .empty;
    defer result.deinit(failing_alloc);
    try set.renderCellMap(
        failing_alloc,
        &result,
        &state,
        null,
        .{},
    );

    try testing.expectEqual(@as(usize, 0), result.count());
}

test "renderCellMap mods no match" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(testing.io, alloc, .{
        .cols = 5,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    const str = "1ABCD2EFGH\r\n3IJKL";
    s.nextSlice(str);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get a set
    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = "AB",
            .action = .{ .open = {} },
            .highlight = .{ .always = {} },
        },

        .{
            .regex = "EF",
            .action = .{ .open = {} },
            .highlight = .{ .always_mods = .{ .ctrl = true } },
        },
    });
    defer set.deinit(alloc);

    // Get our matches
    var result: terminal.RenderState.CellSet = .empty;
    defer result.deinit(alloc);
    try set.renderCellMap(
        alloc,
        &result,
        &state,
        null,
        .{},
    );

    // Test our matches
    try testing.expect(!result.contains(.{ .x = 0, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 1, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 2, .y = 0 }));
    try testing.expect(!result.contains(.{ .x = 3, .y = 0 }));
    try testing.expect(!result.contains(.{ .x = 1, .y = 1 }));
    try testing.expect(!result.contains(.{ .x = 1, .y = 2 }));
}

test "link cache matches uncached results across hover, edits, scroll, resize and config" {
    const t = std.testing;
    var term = try Terminal.init(t.io, t.allocator, .{ .cols = 20, .rows = 2, .max_scrollback_bytes = 1024 * 1024 });
    defer term.deinit(t.allocator);
    try term.printString("one two\nthree four\nfive six");
    var set = try Set.fromConfig(t.allocator, &.{.{ .regex = "[a-z]+", .action = .{ .open = {} }, .highlight = .{ .hover = {} } }});
    defer set.deinit(t.allocator);
    var cache: Cache = .{};
    defer cache.deinit(t.allocator);
    var state: terminal.RenderState = .empty;
    defer state.deinit(t.allocator);
    for (0..6) |step| {
        switch (step) {
            2 => try term.printString(" changed"),
            3 => term.screens.active.pages.scroll(.top),
            4 => try term.resize(t.allocator, .{ .cols = 12, .rows = 3 }),
            5 => cache.invalidate(t.allocator),
            else => {},
        }
        try state.update(t.allocator, &term);
        const before = cache.rebuilds;
        for ([_]point.Coordinate{ .{ .x = 0, .y = 0 }, .{ .x = 7, .y = 0 }, .{ .x = 1, .y = 1 } }) |mouse| {
            var expected: terminal.RenderState.CellSet = .empty;
            defer expected.deinit(t.allocator);
            var actual: terminal.RenderState.CellSet = .empty;
            defer actual.deinit(t.allocator);
            try set.renderCellMap(t.allocator, &expected, &state, mouse, .{});
            try cache.render(t.allocator, t.allocator, &set, &actual, &state, terminal.accessibility.Tracker.Key.read(&term), mouse, .{});
            try t.expectEqual(expected.count(), actual.count());
            for (expected.keys()) |cell| try t.expect(actual.contains(cell));
        }
        if (step == 1) try t.expectEqual(before, cache.rebuilds);
    }
}

test "link cache reuses workspace across edits and releases old patterns on config change" {
    const t = std.testing;
    var term = try Terminal.init(t.io, t.allocator, .{ .cols = 80, .rows = 4 });
    defer term.deinit(t.allocator);
    var state: terminal.RenderState = .empty;
    defer state.deinit(t.allocator);
    var set = try Set.fromConfig(t.allocator, &.{.{ .regex = "[a-z]+", .action = .{ .open = {} }, .highlight = .always }});
    defer set.deinit(t.allocator);
    var counter = t.FailingAllocator.init(t.allocator, .{});
    const alloc = counter.allocator();
    var cache: Cache = .{};
    defer cache.deinit(alloc);
    var cells: terminal.RenderState.CellSet = .empty;
    defer cells.deinit(alloc);
    var retained_allocations: usize = 0;
    var scratch_address: usize = 0;
    var text_address: usize = 0;
    for (0..101) |i| {
        term.carriageReturn();
        try term.printString(if (i % 2 == 0) "hello world" else "other words");
        try state.update(t.allocator, &term);
        cells.clearRetainingCapacity();
        try cache.render(alloc, alloc, &set, &cells, &state, terminal.accessibility.Tracker.Key.read(&term), null, .{});
        if (i == 0) {
            retained_allocations = counter.allocations;
            scratch_address = @intFromPtr(cache.matchers.items[0].data);
            text_address = @intFromPtr(cache.text.?.writer.buffer.ptr);
        } else {
            try t.expectEqual(retained_allocations, counter.allocations);
            try t.expectEqual(scratch_address, @intFromPtr(cache.matchers.items[0].data));
            try t.expectEqual(text_address, @intFromPtr(cache.text.?.writer.buffer.ptr));
        }
    }
    std.debug.print("\nRESOURCE_METRIC link_rebuilds=101 warmed_additional_allocations={d}\n", .{counter.allocations - retained_allocations});
    cache.invalidate(alloc);
    set.deinit(t.allocator);
    set = try Set.fromConfig(t.allocator, &.{.{ .regex = "[0-9]+", .action = .{ .open = {} }, .highlight = .always }});
    cells.clearRetainingCapacity();
    try cache.render(alloc, alloc, &set, &cells, &state, terminal.accessibility.Tracker.Key.read(&term), null, .{});
    try t.expectEqual(@as(u32, 0), cells.count());
}
