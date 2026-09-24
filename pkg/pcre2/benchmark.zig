//! Run in this directory: zig build benchmark -Doptimize=ReleaseFast
const std = @import("std");
const pcre2 = @import("pcre2");

pub fn main(init: std.process.Init) !void {
    var regex = try pcre2.Regex.init("https?://[^\\s]+");
    defer regex.deinit();
    const subject = "https://example.com/path " ** 100;
    for (0..5) |run| {
        for ([_]bool{ false, true }) |reuse| {
            const start: std.Io.Timestamp = .now(init.io, .awake);
            var matches: usize = 0;
            for (0..1000) |_| {
                var scratch: ?pcre2.Matcher = if (reuse) try regex.matcher() else null;
                defer if (scratch) |*s| s.deinit();
                var offset: usize = 0;
                while (offset < subject.len) {
                    const result = if (scratch) |*s| s.search(subject[offset..], 0) else regex.search(subject[offset..], 0);
                    const match = result catch |err| switch (err) {
                        error.NoMatch => break,
                        else => return err,
                    };
                    offset += match.end;
                    matches += 1;
                }
            }
            if (matches != 100_000) return error.WrongMatchCount;
            const elapsed = start.durationTo(.now(init.io, .awake)).nanoseconds;
            std.debug.print("run={d} reuse={} matches={d} elapsed_ms={d:.3}\n", .{
                run + 1, reuse, matches, @as(f64, @floatFromInt(elapsed)) / 1_000_000,
            });
        }
    }
}
