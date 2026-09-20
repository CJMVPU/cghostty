//! Bounded UTF-8 matching for terminal links. Compiled patterns can be shared;
//! mutable match data and budgets belong to each search, not to the pattern.
const std = @import("std");
const c = @import("pcre2_c");

pub const Match = struct {
    /// Byte offsets in the supplied UTF-8 subject, end exclusive.
    start: usize,
    end: usize,
};

pub const Error = error{
    InvalidPattern,
    OutOfMemory,
    NoMatch,
    MatchLimitExceeded,
    InvalidUtf8,
    InvalidOffset,
    UnexpectedError,
};

pub const Regex = struct {
    code: *c.pcre2_code_8,

    pub fn init(pattern: []const u8) Error!Regex {
        var err: c_int = 0;
        var offset: usize = 0;
        const code = c.pcre2_compile_8(
            pattern.ptr,
            pattern.len,
            c.PCRE2_UTF | c.PCRE2_UCP | c.PCRE2_MULTILINE | c.PCRE2_NO_AUTO_CAPTURE,
            &err,
            &offset,
            null,
        ) orelse return if (err == c.PCRE2_ERROR_HEAP_FAILED) error.OutOfMemory else error.InvalidPattern;
        return .{ .code = code };
    }

    pub fn deinit(self: *Regex) void {
        c.pcre2_code_free_8(self.code);
        self.* = undefined;
    }

    /// Empty matches cannot identify terminal cells, so they are excluded here.
    /// Limits bound matching work/depth/heap, not wall-clock time. Both renderer
    /// highlighting and click lookup use this same policy.
    pub fn search(self: Regex, subject: []const u8, start: usize) Error!Match {
        if (start > subject.len) return error.InvalidOffset;
        const context = c.pcre2_match_context_create_8(null) orelse return error.OutOfMemory;
        defer c.pcre2_match_context_free_8(context);
        _ = c.pcre2_set_match_limit_8(context, 100_000);
        _ = c.pcre2_set_depth_limit_8(context, 1_000);
        _ = c.pcre2_set_heap_limit_8(context, 8 * 1024); // KiB, 8 MiB per search.

        const data = c.pcre2_match_data_create_from_pattern_8(self.code, null) orelse return error.OutOfMemory;
        defer c.pcre2_match_data_free_8(data);
        const rc = c.pcre2_match_8(self.code, subject.ptr, subject.len, start, c.PCRE2_NOTEMPTY, data, context);
        if (rc < 0) return switch (rc) {
            c.PCRE2_ERROR_NOMATCH => error.NoMatch,
            c.PCRE2_ERROR_MATCHLIMIT, c.PCRE2_ERROR_DEPTHLIMIT, c.PCRE2_ERROR_HEAPLIMIT => error.MatchLimitExceeded,
            c.PCRE2_ERROR_NOMEMORY => error.OutOfMemory,
            c.PCRE2_ERROR_BADOFFSET, c.PCRE2_ERROR_BADUTFOFFSET => error.InvalidOffset,
            c.PCRE2_ERROR_UTF8_ERR21...c.PCRE2_ERROR_UTF8_ERR1 => error.InvalidUtf8,
            else => error.UnexpectedError,
        };
        const offsets = c.pcre2_get_ovector_pointer_8(data);
        return .{ .start = offsets[0], .end = offsets[1] };
    }
};

test "UTF-8 byte ranges and search offsets" {
    var regex = try Regex.init("世界");
    defer regex.deinit();
    try std.testing.expectEqual(Match{ .start = 4, .end = 10 }, try regex.search("🙂世界 世界", 0));
    try std.testing.expectEqual(Match{ .start = 11, .end = 17 }, try regex.search("🙂世界 世界", 10));
    try std.testing.expectError(error.NoMatch, regex.search("hello", 0));
    try std.testing.expectError(error.InvalidOffset, regex.search("世界", 1));
    try std.testing.expectError(error.InvalidOffset, regex.search("", 1));
    try std.testing.expectError(error.InvalidUtf8, regex.search("\xff", 0));
}

test "empty matches do not stall link iteration" {
    var regex = try Regex.init("a*");
    defer regex.deinit();
    try std.testing.expectError(error.NoMatch, regex.search("bbb", 0));
    try std.testing.expectError(error.NoMatch, regex.search("", 0));
    try std.testing.expectEqual(Match{ .start = 1, .end = 3 }, try regex.search("baa", 0));
}

test "invalid patterns and bounded backtracking" {
    try std.testing.expectError(error.InvalidPattern, Regex.init("("));
    var regex = try Regex.init("(*NO_START_OPT)(*NO_AUTO_POSSESS)^(a+)+$");
    defer regex.deinit();
    try std.testing.expectError(error.MatchLimitExceeded, regex.search("a" ** 30 ++ "!", 0));
}
