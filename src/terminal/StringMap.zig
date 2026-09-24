/// A string along with the mapping of each individual byte in the string
/// to the point in the screen.
const StringMap = @This();

const std = @import("std");
const pcre2 = @import("pcre2");
const point = @import("point.zig");
const PinMap = @import("formatter.zig").PinMap;
const Selection = @import("Selection.zig");
const Screen = @import("Screen.zig");
const Allocator = std.mem.Allocator;

string: [:0]const u8,

/// Mapping of string byte offsets to pins. See PinMap for the
/// storage details.
map: PinMap.Map,

pub fn deinit(self: StringMap, alloc: Allocator) void {
    alloc.free(self.string);
    var map = self.map;
    map.deinit(alloc);
}

/// Returns an iterator that yields the next match of the given regex.
pub fn searchIterator(
    self: StringMap,
    regex: pcre2.Regex,
) pcre2.Error!SearchIterator {
    return .{ .map = self, .matcher = try regex.matcher() };
}

/// Iterates over the regular expression matches of the string.
pub const SearchIterator = struct {
    map: StringMap,
    matcher: pcre2.Matcher,
    offset: usize = 0,

    pub fn deinit(self: *SearchIterator) void {
        self.matcher.deinit();
    }

    /// Returns the next regular expression match or null if there are
    /// no more matches.
    pub fn next(self: *SearchIterator) !?Match {
        if (self.offset >= self.map.string.len) return null;

        const region = self.matcher.search(self.map.string[self.offset..], 0) catch |err| switch (err) {
            error.NoMatch, error.MatchLimitExceeded => {
                self.offset = self.map.string.len;
                return null;
            },
            else => return err,
        };

        // Increment our offset by the number of bytes in the match.
        // We defer this so that we can return the match before
        // modifying the offset.
        const end_idx: usize = region.end;
        defer self.offset += end_idx;

        return .{
            .map = self.map,
            .offset = self.offset,
            .region = region,
        };
    }
};

/// A single regular expression match.
pub const Match = struct {
    map: StringMap,
    offset: usize,
    region: pcre2.Match,

    /// Returns the selection containing the full match.
    pub fn selection(self: Match) Selection {
        const start_idx: usize = self.region.start;
        const end_idx: usize = self.region.end - 1;
        const start_pt = self.map.map.get(self.offset + start_idx).?;
        const end_pt = self.map.map.get(self.offset + end_idx).?;
        return .init(start_pt, end_pt, false);
    }
};

test "StringMap searchIterator" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    // Initialize our regex
    var re = try pcre2.Regex.init("[A-B]{2}");
    defer re.deinit();

    // Initialize our screen
    var s = try Screen.init(io, alloc, .{ .cols = 5, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABCD2EFGH\n3IJKL";
    try s.testWriteString(str);
    const line = s.selectLine(.{
        .pin = s.pages.pin(.{ .active = .{
            .x = 2,
            .y = 1,
        } }).?,
    }).?;
    const map = try s.selectionStringMap(alloc, .{
        .sel = line,
        .trim = false,
    });
    defer map.deinit(alloc);

    // Get our iterator
    var it = try map.searchIterator(re);
    defer it.deinit();
    {
        const match = (try it.next()).?;

        const sel = match.selection();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }

    try testing.expect(try it.next() == null);
}

test "StringMap searchIterator URL detection" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    const url = @import("../config/url.zig");

    // Initialize URL regex
    var re = try pcre2.Regex.init(url.regex);
    defer re.deinit();

    // Initialize our screen with text containing a URL
    var s = try Screen.init(io, alloc, .{ .cols = 40, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("hello https://example.com/path world");

    // Get the line
    const line = s.selectLine(.{
        .pin = s.pages.pin(.{ .active = .{
            .x = 10,
            .y = 0,
        } }).?,
    }).?;
    const map = try s.selectionStringMap(alloc, .{
        .sel = line,
        .trim = false,
    });
    defer map.deinit(alloc);

    // Search for URL match
    var it = try map.searchIterator(re);
    defer it.deinit();
    {
        const match = (try it.next()).?;

        const sel = match.selection();
        // URL should start at x=6 ("https://example.com/path" starts after "hello ")
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 6,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        // URL should end at x=29 (end of "/path")
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 29,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }

    try testing.expect(try it.next() == null);
}

test "StringMap searchIterator URL with click position" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    const url = @import("../config/url.zig");

    // Initialize URL regex
    var re = try pcre2.Regex.init(url.regex);
    defer re.deinit();

    // Initialize our screen with text containing a URL
    var s = try Screen.init(io, alloc, .{ .cols = 40, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("hello https://example.com world");

    // Simulate clicking on "example" (x=14)
    const click_pin = s.pages.pin(.{ .active = .{
        .x = 14,
        .y = 0,
    } }).?;

    // Get the line
    const line = s.selectLine(.{
        .pin = click_pin,
    }).?;
    const map = try s.selectionStringMap(alloc, .{
        .sel = line,
        .trim = false,
    });
    defer map.deinit(alloc);

    // Search for URL match and verify click position is within URL
    var it = try map.searchIterator(re);
    defer it.deinit();
    var found_url = false;
    while (true) {
        const match = (try it.next()) orelse break;

        const sel = match.selection();
        if (sel.contains(&s, click_pin)) {
            found_url = true;
            // Verify URL bounds
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 6,
                .y = 0,
            } }, s.pages.pointFromPin(.screen, sel.start()).?);
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 24,
                .y = 0,
            } }, s.pages.pointFromPin(.screen, sel.end()).?);
            break;
        }
    }
    try testing.expect(found_url);
}

test "StringMap Unicode URL selections and multiple matches" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var screen = try Screen.init(testing.io, alloc, .{ .cols = 80, .rows = 2, .max_scrollback_bytes = 0 });
    defer screen.deinit();
    try screen.testWriteString("🙂 ./文件.txt ./cafe\u{0301}.txt");
    const line = screen.selectLine(.{
        .pin = screen.pages.pin(.{ .active = .{ .x = 3, .y = 0 } }).?,
    }).?;
    const map = try screen.selectionStringMap(alloc, .{ .sel = line, .trim = false });
    defer map.deinit(alloc);
    var regex = try pcre2.Regex.init(@import("../config/url.zig").regex);
    defer regex.deinit();
    var iter = try map.searchIterator(regex);
    defer iter.deinit();
    for ([_][]const u8{ "./文件.txt", "./cafe\u{0301}.txt" }) |expected| {
        const match = (try iter.next()).?;
        const text = try screen.selectionString(alloc, .{ .sel = match.selection(), .trim = false });
        defer alloc.free(text);
        try testing.expectEqualStrings(expected, text);
    }
    try testing.expectEqual(null, try iter.next());
}

test "StringMap empty matches and exhausted budgets stop iteration" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var screen = try Screen.init(testing.io, alloc, .{ .cols = 40, .rows = 2, .max_scrollback_bytes = 0 });
    defer screen.deinit();
    try screen.testWriteString("a" ** 30 ++ "!");
    const line = screen.selectLine(.{
        .pin = screen.pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?,
    }).?;
    const map = try screen.selectionStringMap(alloc, .{ .sel = line, .trim = false });
    defer map.deinit(alloc);
    for ([_][]const u8{ "(?=a)", "(*NO_START_OPT)(*NO_AUTO_POSSESS)^(a+)+$" }) |pattern| {
        var regex = try pcre2.Regex.init(pattern);
        defer regex.deinit();
        var iter = try map.searchIterator(regex);
        defer iter.deinit();
        try testing.expectEqual(null, try iter.next());
        try testing.expectEqual(null, try iter.next());
    }
}
