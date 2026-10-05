//! Controlled reflow allocation probes. Tests verify semantics and report
//! operation counts, including the enforced grapheme allocation regression.
//! Counts describe page-local calls, not system heap allocations or timing.
const std = @import("std");
const PageList = @import("../../PageList.zig");
const pagepkg = @import("../../page.zig");
const stylepkg = @import("../../style.zig");
const Metrics = PageList.TestAccess.ReflowMetrics;

const text = "ABCDEFGH";
const bold: stylepkg.Style = .{ .flags = .{ .bold = true } };

fn expectTextAndMetadata(list: *PageList, graphemes: bool) !void {
    const testing = std.testing;
    for (text, 0..) |cp, i| {
        const x: u16 = @intCast(i % list.cols);
        const y: u32 = @intCast(i / list.cols);
        const cell = list.getCell(.{ .screen = .{ .x = x, .y = y } }).?;
        const page = cell.node.page();
        try testing.expectEqual(@as(u21, cp), cell.cell.codepoint());
        try testing.expectEqual(i % 2 == 0, cell.cell.protected);
        try testing.expectEqualDeep(bold, page.styles.get(page.memory, cell.cell.style_id).*);
        try testing.expect(cell.row.styled);
        try testing.expectEqual(pagepkg.Row.SemanticPrompt.prompt, cell.row.semantic_prompt);
        if (graphemes) {
            try testing.expect(cell.row.grapheme);
            try testing.expectEqualSlices(u21, &.{ 0x0301, 0x0327 }, page.lookupGrapheme(cell.cell).?);
        }
    }

    const first_row = list.getCell(.{ .screen = .{} }).?.row;
    try testing.expectEqual(list.cols < text.len, first_row.wrap);
    try testing.expect(!first_row.wrap_continuation);
    if (list.cols < text.len) {
        const last_row = list.getCell(.{ .screen = .{ .y = 1 } }).?.row;
        try testing.expect(!last_row.wrap);
        try testing.expect(last_row.wrap_continuation);
    }
}

fn fillText(list: *PageList) !void {
    const page = list.pages.first.?.page();
    for (text, 0..) |cp, x| {
        const rac = page.getRowAndCell(@intCast(x), 0);
        rac.cell.* = .init(cp);
        rac.cell.protected = x % 2 == 0;
        rac.cell.style_id = try page.styles.add(page.memory, bold);
        rac.row.styled = true;
        rac.row.semantic_prompt = .prompt;
    }
}

fn graphemeProbe() !Metrics {
    var list = try PageList.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer list.deinit();
    try fillText(&list);
    const page = list.pages.first.?.page();
    for (0..text.len) |x| {
        const rac = page.getRowAndCell(@intCast(x), 0);
        try page.setGraphemes(rac.row, rac.cell, &.{ 0x0301, 0x0327 });
    }

    // Input construction does not contribute to the measured operation count.
    list.reflow_metrics = .{};
    try list.resize(.{ .cols = 4, .reflow = true });
    const metrics = list.reflow_metrics;
    try expectTextAndMetadata(&list, true);
    try std.testing.expectEqual(text.len, metrics.grapheme_set_attempts);

    try list.resize(.{ .cols = 8, .reflow = true });
    try expectTextAndMetadata(&list, true);
    return metrics;
}

fn hyperlinkProbe() !Metrics {
    const testing = std.testing;
    const uri = "https://example.test/reflow";
    const explicit_id = "stable-id";
    var list = try PageList.init(testing.allocator, .{ .cols = 8, .rows = 2 });
    defer list.deinit();
    try fillText(&list);
    const source = list.pages.first.?.page();
    const id = try source.insertHyperlink(.{
        .id = .{ .explicit = explicit_id },
        .uri = uri,
    });
    for (0..text.len) |x| {
        const rac = source.getRowAndCell(@intCast(x), 0);
        if (x > 0) source.hyperlink_set.use(source.memory, id);
        try source.setHyperlink(rac.row, rac.cell, id);
    }

    list.reflow_metrics = .{};
    try list.resize(.{ .cols = 4, .reflow = true });
    const metrics = list.reflow_metrics;
    try expectTextAndMetadata(&list, false);
    try testing.expect(list.pages.first == list.pages.last);
    const destination = list.pages.first.?.page();
    try testing.expectEqual(text.len, destination.hyperlinkCount());
    var first_id: ?u16 = null;
    for (text, 0..) |_, i| {
        const cell = list.getCell(.{ .screen = .{
            .x = @intCast(i % list.cols),
            .y = @intCast(i / list.cols),
        } }).?;
        try testing.expect(cell.row.hyperlink);
        const dst_id = destination.lookupHyperlink(cell.cell).?;
        if (first_id) |previous| try testing.expectEqual(previous, dst_id) else first_id = dst_id;
        const entry = destination.hyperlink_set.get(destination.memory, dst_id);
        try testing.expectEqualStrings(uri, entry.uri.slice(destination.memory));
        try testing.expectEqualStrings(explicit_id, entry.id.explicit.slice(destination.memory));
    }
    try testing.expectEqual(text.len, destination.hyperlink_set.refCount(destination.memory, first_id.?));

    // Clearing every cell must release every reference, including references
    // which a future cache obtains with use() instead of addWithIdContext().
    for (text, 0..) |_, i| {
        const cell = list.getCell(.{ .screen = .{
            .x = @intCast(i % list.cols),
            .y = @intCast(i / list.cols),
        } }).?;
        destination.clearHyperlink(cell.cell);
    }
    try testing.expectEqual(0, destination.hyperlink_set.refCount(destination.memory, first_id.?));
    try testing.expectEqual(0, destination.hyperlinkCount());
    for (0..destination.size.rows) |y| {
        const row = destination.getRowAndCell(0, @intCast(y)).row;
        destination.updateRowHyperlinkFlag(row);
        try testing.expect(!row.hyperlink);
    }
    return metrics;
}

test "PageList reflow allocation probe grapheme baseline" {
    const metrics = try graphemeProbe();
    std.debug.print("reflow-allocation-probe grapheme cells={d} preflight_allocations={d} set_attempts={d}\n", .{
        text.len, metrics.grapheme_preflight_allocations, metrics.grapheme_set_attempts,
    });
}

test "PageList reflow allocation probe hyperlink baseline" {
    const metrics = try hyperlinkProbe();
    std.debug.print("reflow-allocation-probe hyperlink cells={d} dupe_attempts={d}\n", .{
        text.len, metrics.hyperlink_dupe_attempts,
    });
}

test "PageList reflow allocation probe avoids grapheme preflight" {
    const metrics = try graphemeProbe();
    try std.testing.expectEqual(0, metrics.grapheme_preflight_allocations);
}

test "PageList reflow allocation probe grapheme allocation failure leaves cell unchanged" {
    const testing = std.testing;
    var page = try pagepkg.Page.init(.{ .cols = 2, .rows = 1 });
    defer page.deinit();
    const rac = page.getRowAndCell(0, 0);
    rac.cell.* = .init('A');
    rac.cell.protected = true;
    rac.row.semantic_prompt = .prompt;
    const original = rac.cell.*;

    // Exhaust only byte storage, leaving the grapheme map empty. This tests
    // the failure rollback which a direct setGraphemes retry would rely on.
    const reserved = try page.grapheme_alloc.alloc(
        u8,
        page.memory,
        page.grapheme_alloc.capacityBytes(),
    );
    defer page.grapheme_alloc.free(page.memory, reserved);
    const used = page.grapheme_alloc.usedBytes(page.memory);
    try testing.expectError(error.GraphemeAllocOutOfMemory, page.setGraphemes(
        rac.row,
        rac.cell,
        &.{ 0x0301, 0x0327 },
    ));
    // Cell is a fully initialized packed u64. Comparing its exact bits avoids
    // recursively inspecting the inactive fields of its untagged content union.
    try testing.expectEqual(@as(u64, @bitCast(original)), @as(u64, @bitCast(rac.cell.*)));
    try testing.expect(!rac.row.grapheme);
    try testing.expectEqual(pagepkg.Row.SemanticPrompt.prompt, rac.row.semantic_prompt);
    try testing.expectEqual(0, page.graphemeCount());
    try testing.expectEqual(used, page.grapheme_alloc.usedBytes(page.memory));
}
