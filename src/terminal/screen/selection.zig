//! Selection queries over screen contents. Selection ownership stays in Screen.
const std = @import("std");
const Screen = @import("../Screen.zig");
const Selection = @import("../Selection.zig");
const PageList = @import("../PageList.zig");
const selection_codepoints = @import("../selection_codepoints.zig");
const point = @import("../point.zig");
const Cell = @import("../page.zig").Cell;
const Pin = PageList.Pin;

pub const SelectLine = struct {
    /// The pin of some part of the line to select.
    pin: Pin,

    /// These are the codepoints to consider whitespace to trim
    /// from the ends of the selection.
    whitespace: ?[]const u21 = &selection_codepoints.default_line_whitespace,

    /// If true, line selection will consider semantic prompt
    /// state changing a boundary. State changing is ANY state
    /// change.
    semantic_prompt_boundary: bool = true,
};

/// Select the line under the given point. This will select across soft-wrapped
/// lines and will omit the leading and trailing whitespace. If the point is
/// over whitespace but the line has non-whitespace characters elsewhere, the
/// line will be selected.
pub fn selectLine(self: *const Screen, opts: SelectLine) ?Selection {
    _ = self;

    // Get the current point semantic prompt state since that determines
    // boundary conditions too. This makes it so that line selection can
    // only happen within the same prompt state. For example, if you triple
    // click output, but the shell uses spaces to soft-wrap to the prompt
    // then the selection will stop prior to the prompt. See issue #1329.
    const semantic_prompt_state: ?Cell.SemanticContent = state: {
        if (!opts.semantic_prompt_boundary) break :state null;
        const rac = opts.pin.rowAndCell();
        break :state rac.cell.semantic_content;
    };

    // The real start of the row is the first row in the soft-wrap.
    const start_pin: Pin = start_pin: {
        var it = opts.pin.rowIterator(.left_up, null);
        var it_prev: Pin = it.next().?; // skip self

        // First, check the current row for semantic boundaries before the clicked position.
        if (semantic_prompt_state) |v| {
            const row = it_prev.rowAndCell().row;
            const cells = it_prev.node.page().getCells(row);
            // Scan backwards from clicked position to find where our content starts
            for (0..opts.pin.x + 1) |i| {
                const x_rev = opts.pin.x - i;
                if (cells[x_rev].semantic_content != v) {
                    var copy = it_prev;
                    copy.x = @intCast(x_rev + 1);
                    break :start_pin copy;
                }
            }

            // No boundary found before clicked position on current row.
            // If row doesn't wrap from above, start is at column 0.
            // Otherwise, continue checking previous rows.
        }

        while (it.next()) |p| {
            const row = p.rowAndCell().row;

            if (!row.wrap) {
                var copy = it_prev;
                copy.x = 0;
                break :start_pin copy;
            }

            if (semantic_prompt_state) |v| {
                // We need to check every cell in this row in reverse
                // order since we're going up and back.
                const cells = p.node.page().getCells(row);
                for (0..cells.len) |x| {
                    const x_rev = cells.len - 1 - x;
                    const cell = cells[x_rev];
                    if (cell.semantic_content != v) break :start_pin it_prev;
                    it_prev = p;
                    it_prev.x = @intCast(x_rev);
                }

                continue;
            }

            it_prev = p;
        } else {
            var copy = it_prev;
            copy.x = 0;
            break :start_pin copy;
        }
    };

    // The real end of the row is the final row in the soft-wrap.
    const end_pin: Pin = end_pin: {
        var it = opts.pin.rowIterator(.right_down, null);
        while (it.next()) |p| {
            const row = p.rowAndCell().row;

            if (semantic_prompt_state) |v| {
                // We need to check every cell in this row
                const cells = p.node.page().getCells(row);

                // If this is our pin row we can start from our x because
                // the start_pin logic already found the real start.
                const start_offset = if (p.node == opts.pin.node and
                    p.y == opts.pin.y) opts.pin.x else 0;

                // Handle the zero case specially because if the first
                // col doesn't match then we end at the end of the prior
                // row. But if this is the first row, we can't go back,
                // so we scan forward to find where our content ends.
                if (start_offset == 0 and cells[0].semantic_content != v) {
                    var prev = p.up(1).?;
                    prev.x = prev.node.cols() - 1;
                    break :end_pin prev;
                }

                // For every other case, we end at the prior cell.
                for (start_offset.., cells[start_offset..]) |x, cell| {
                    if (cell.semantic_content != v) {
                        var copy = p;
                        copy.x = @intCast(x - 1);
                        break :end_pin copy;
                    }
                }
            }

            if (!row.wrap) {
                var copy = p;
                copy.x = p.node.cols() - 1;
                break :end_pin copy;
            }
        }

        return null;
    };

    // Go forward from the start to find the first non-whitespace character.
    const start: Pin = start: {
        const whitespace = opts.whitespace orelse break :start start_pin;
        var it = start_pin.cellIterator(.right_down, end_pin);
        while (it.next()) |p| {
            const cell = p.rowAndCell().cell;
            if (!cell.hasText()) continue;

            // Non-empty means we found it.
            const this_whitespace = std.mem.indexOfScalar(
                u21,
                whitespace,
                cell.content.codepoint.data,
            ) != null;
            if (this_whitespace) continue;

            break :start p;
        }

        return null;
    };

    // Go backward from the end to find the first non-whitespace character.
    const end: Pin = end: {
        const whitespace = opts.whitespace orelse break :end end_pin;
        var it = end_pin.cellIterator(.left_up, start_pin);
        while (it.next()) |p| {
            const cell = p.rowAndCell().cell;
            if (!cell.hasText()) continue;

            // Non-empty means we found it.
            const this_whitespace = std.mem.indexOfScalar(
                u21,
                whitespace,
                cell.content.codepoint.data,
            ) != null;
            if (this_whitespace) continue;

            break :end p;
        }

        return null;
    };

    return .init(start, end, false);
}

/// Return the selection for all contents on the screen. Surrounding
/// whitespace is omitted. If there is no selection, this returns null.
pub fn selectAll(self: *Screen) ?Selection {
    const whitespace = &[_]u32{ 0, ' ', '\t' };

    const start: Pin = start: {
        var it = self.pages.cellIterator(
            .right_down,
            .{ .screen = .{} },
            null,
        );
        while (it.next()) |p| {
            const cell = p.rowAndCell().cell;
            if (!cell.hasText()) continue;

            // Non-empty means we found it.
            const this_whitespace = std.mem.indexOfAny(
                u32,
                whitespace,
                &[_]u32{cell.content.codepoint.data},
            ) != null;
            if (this_whitespace) continue;

            break :start p;
        }

        return null;
    };

    const end: Pin = end: {
        var it = self.pages.cellIterator(
            .left_up,
            .{ .screen = .{} },
            null,
        );
        while (it.next()) |p| {
            const cell = p.rowAndCell().cell;
            if (!cell.hasText()) continue;

            // Non-empty means we found it.
            const this_whitespace = std.mem.indexOfAny(
                u32,
                whitespace,
                &[_]u32{cell.content.codepoint.data},
            ) != null;
            if (this_whitespace) continue;

            break :end p;
        }

        return null;
    };

    return .init(start, end, false);
}

/// Select the nearest word to start point that is between start_pt and
/// end_pt (inclusive). Because it selects "nearest" to start point, start
/// point can be before or after end point.
///
/// The boundary_codepoints parameter should be a slice of u21 codepoints that
/// mark word boundaries, passed through to selectWord.
///
/// TODO: test this
pub fn selectWordBetween(
    self: *Screen,
    start: Pin,
    end: Pin,
    boundary_codepoints: []const u21,
) ?Selection {
    const dir: PageList.Direction = if (start.before(end)) .right_down else .left_up;
    var it = start.cellIterator(dir, end);
    while (it.next()) |pin| {
        // Boundary conditions
        switch (dir) {
            .right_down => if (end.before(pin)) return null,
            .left_up => if (pin.before(end)) return null,
        }

        // If we found a word, then return it
        if (self.selectWord(pin, boundary_codepoints)) |sel| return sel;
    }

    return null;
}

/// Select the word under the given point. A word is any consecutive series
/// of characters that are exclusively whitespace or exclusively non-whitespace.
/// A selection can span multiple physical lines if they are soft-wrapped.
///
/// This will return null if a selection is impossible. The only scenario
/// this happens is if the point pt is outside of the written screen space.
///
/// The boundary_codepoints parameter should be a slice of u21 codepoints that
/// mark word boundaries. This is expected to be pre-parsed from the config.
pub fn selectWord(
    self: *Screen,
    pin: Pin,
    boundary_codepoints: []const u21,
) ?Selection {
    _ = self;

    // If our cell is empty we can't select a word, because we can't select
    // areas where the screen is not yet written.
    const start_cell = pin.rowAndCell().cell;
    if (!start_cell.hasText()) return null;

    // Determine if we are a boundary or not to determine what our boundary is.
    const expect_boundary = std.mem.indexOfScalar(
        u21,
        boundary_codepoints,
        start_cell.content.codepoint.data,
    ) != null;

    // Go forwards to find our end boundary
    const end: Pin = end: {
        var it = pin.cellIterator(.right_down, null);
        var prev = it.next().?; // Consume one, our start
        while (it.next()) |p| {
            const rac = p.rowAndCell();
            const cell = rac.cell;

            // If we reached an empty cell its always a boundary
            if (!cell.hasText()) break :end prev;

            // If we do not match our expected set, we hit a boundary
            const this_boundary = std.mem.indexOfScalar(
                u21,
                boundary_codepoints,
                cell.content.codepoint.data,
            ) != null;
            if (this_boundary != expect_boundary) break :end prev;

            // If we are going to the next row and it isn't wrapped, we
            // return the previous.
            if (p.x == p.node.cols() - 1 and !rac.row.wrap) {
                break :end p;
            }

            prev = p;
        }

        break :end prev;
    };

    // Go backwards to find our start boundary
    const start: Pin = start: {
        var it = pin.cellIterator(.left_up, null);
        var prev = it.next().?; // Consume one, our start
        while (it.next()) |p| {
            const rac = p.rowAndCell();
            const cell = rac.cell;

            // If we are going to the next row and it isn't wrapped, we
            // return the previous.
            if (p.x == p.node.cols() - 1 and !rac.row.wrap) {
                break :start prev;
            }

            // If we reached an empty cell its always a boundary
            if (!cell.hasText()) break :start prev;

            // If we do not match our expected set, we hit a boundary
            const this_boundary = std.mem.indexOfScalar(
                u21,
                boundary_codepoints,
                cell.content.codepoint.data,
            ) != null;
            if (this_boundary != expect_boundary) break :start prev;

            prev = p;
        }

        break :start prev;
    };

    return .init(start, end, false);
}

/// Select the command output under the given point. The limits of the output
/// are determined by semantic prompt information provided by shell integration.
/// A selection can span multiple physical lines if they are soft-wrapped.
///
/// This will return null if a selection is impossible:
///  - the point pt is outside of the written screen space.
///  - the point pt is on a prompt / input line.
pub fn selectOutput(self: *Screen, pin: Pin) ?Selection {
    // If our pin right now is not on output, then we return nothing.
    if (pin.rowAndCell().cell.semantic_content != .output) return null;

    // Get the post prior prompt from this pin. This is the prompt whose
    // output we'll be capturing.
    const prompt_pin: Pin = prompt: {
        // If we have a prompt above this point (including this point),
        // then thats the prompt we want to capture output from.
        var it = pin.promptIterator(.left_up, null);
        if (it.next()) |p| break :prompt p;

        // If we don't have a prompt, then we assume that we're
        // capturing all the output up to the next prompt.
        it = pin.promptIterator(.right_down, null);
        const next = it.next() orelse return null;

        // We'll capture from the start of the screen to just above
        // the prompt and will trim the trailing whitespace.
        const start_pin = self.pages.getTopLeft(.screen);
        var end_pin = next.up(1) orelse return null;
        end_pin.x = end_pin.node.cols() - 1;
        var cell_it = end_pin.cellIterator(.left_up, start_pin);
        while (cell_it.next()) |p| {
            const cell = p.rowAndCell().cell;
            end_pin = p;
            if (cell.hasText()) break;
        }

        return .init(
            start_pin,
            end_pin,
            false,
        );
    };

    // Grab our content
    var hl = self.pages.highlightSemanticContent(
        prompt_pin,
        .output,
    ) orelse return null;

    // Trim our trailing whitespace
    var cell_it = hl.end.cellIterator(.left_up, hl.start);
    while (cell_it.next()) |p| {
        const cell = p.rowAndCell().cell;
        hl.end = p;
        if (cell.hasText()) break;
    }

    return .init(hl.start, hl.end, false);
}

pub const LineIterator = struct {
    screen: *const Screen,
    current: ?Pin = null,

    pub fn next(self: *LineIterator) ?Selection {
        const current = self.current orelse return null;
        const result = self.screen.selectLine(.{
            .pin = current,
            .whitespace = null,
            .semantic_prompt_boundary = false,
        }) orelse {
            self.current = null;
            return null;
        };

        self.current = result.end().down(1);
        return result;
    }
};

/// Returns an iterator to move through the soft-wrapped lines starting
/// from pin.
pub fn lineIterator(self: *const Screen, start: Pin) LineIterator {
    return LineIterator{
        .screen = self,
        .current = start,
    };
}
