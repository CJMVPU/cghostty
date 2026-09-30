//! Constant-size identities read while the terminal mutex is held. Keys store
//! numeric addresses and page serials, never dereference saved page pointers.
//! Text/layout consumers use ContentView; selection-aware clients compose it
//! with Selection. Mutation epochs are independent of renderer dirty flags.
const std = @import("std");
const Terminal = @import("Terminal.zig");
const Screen = @import("Screen.zig");

pub const Position = struct {
    node: usize,
    serial: u64,
    x: usize,
    y: usize,
    fn read(pin: @import("PageList.zig").Pin) Position {
        return .{ .node = @intFromPtr(pin.node), .serial = pin.node.serial, .x = pin.x, .y = pin.y };
    }
};

pub const ContentView = struct {
    terminal_epoch: u64,
    screen_epoch: u64,
    screen_generation: usize,
    active_key: @import("ScreenSet.zig").Key,
    page_serial: u64,
    cols: usize,
    rows: usize,
    top: Position,
    bottom: Position,
    viewport: Position,

    pub fn read(term: *const Terminal) ContentView {
        const screen = term.screens.active;
        const pages = &screen.pages;
        return .{
            // Existing counters cover content and layout mutations. Retain
            // their storage names to avoid changing every mutation site.
            .terminal_epoch = term.accessibility_revision,
            .screen_epoch = screen.accessibility_revision,
            .screen_generation = term.screens.generations.get(term.screens.active_key).?,
            .active_key = term.screens.active_key,
            .page_serial = pages.page_serial,
            .cols = pages.cols,
            .rows = pages.rows,
            .top = .read(pages.getTopLeft(.screen)),
            .bottom = .read(pages.getBottomRight(.screen).?),
            .viewport = .read(pages.getTopLeft(.viewport)),
        };
    }
};

pub const Selection = struct {
    start: ?Position,
    end: ?Position,
    rectangle: bool,
    pub fn read(screen: *const Screen) Selection {
        return .{
            .start = if (screen.selection) |sel| .read(sel.start()) else null,
            .end = if (screen.selection) |sel| .read(sel.end()) else null,
            .rectangle = if (screen.selection) |sel| sel.rectangle else false,
        };
    }
};

test "content view identity ignores selection and survives consumed renderer dirties" {
    const t = std.testing;
    var term = try Terminal.init(t.io, t.allocator, .{ .cols = 10, .rows = 2, .max_scrollback_bytes = 1024 * 1024 });
    defer term.deinit(t.allocator);
    try term.printString("old\nvisible\nlast");
    const content = ContentView.read(&term);
    const selection = Selection.read(term.screens.active);
    const pin = term.screens.active.pages.getTopLeft(.screen);
    try term.screens.active.select(@import("Selection.zig").init(pin, pin, false));
    try t.expect(std.meta.eql(content, ContentView.read(&term)));
    try t.expect(!std.meta.eql(selection, Selection.read(term.screens.active)));
    term.screens.active.clearSelection();
    try t.expect(std.meta.eql(content, ContentView.read(&term)));
    try term.printString("X");
    var render: @import("render.zig").RenderState = .empty;
    defer render.deinit(t.allocator);
    try render.update(t.allocator, &term);
    const edited = ContentView.read(&term);
    try t.expect(!std.meta.eql(content, edited));
    term.screens.active.pages.scroll(.top);
    try t.expect(!std.meta.eql(edited, ContentView.read(&term)));
}
