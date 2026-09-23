const std = @import("std");
const Allocator = std.mem.Allocator;
const size = @import("size.zig");

/// The possible reference locations for a point. When someone says "(42, 80)"
/// in the context of a terminal, that could mean multiple things: it is in the
/// current visible viewport? the current active area of the screen where the
/// cursor is? the entire scrollback history? etc.
///
/// This tag is used to differentiate those cases.
pub const Tag = enum(u2) {
    active = 0,
    viewport = 1,
    screen = 2,
    history = 3,
};

/// An x/y point in the terminal for some definition of location (tag).
pub const Point = union(Tag) {
    active: Coordinate,
    viewport: Coordinate,
    screen: Coordinate,
    history: Coordinate,

    pub inline fn coord(self: Point) Coordinate {
        return switch (self) {
            .active,
            .viewport,
            .screen,
            .history,
            => |v| v,
        };
    }
};

pub const Coordinate = extern struct {
    /// x can use size.CellCountInt because the number of columns
    /// can't ever be more than a valid number of columns in a Page.
    x: size.CellCountInt = 0,

    /// y does not use size.CellCountInt because certain coordinate
    /// usage such as screen/history can have more rows than are possible
    /// in a single page.
    y: u32 = 0,

    pub fn eql(self: Coordinate, other: Coordinate) bool {
        return self.x == other.x and self.y == other.y;
    }
};
