//! Bounded UTF-8 matching for terminal links. Compiled patterns can be shared;
//! mutable match data and budgets belong to each caller, not to the pattern.
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
        var scratch = try self.matcher();
        defer scratch.deinit();
        return scratch.search(subject, start);
    }

    /// A caller-owned scratch context; never share it between threads. The
    /// compiled pattern must outlive the matcher.
    pub fn matcher(self: Regex) Error!Matcher {
        const context = c.pcre2_match_context_create_8(null) orelse return error.OutOfMemory;
        errdefer c.pcre2_match_context_free_8(context);
        _ = c.pcre2_set_match_limit_8(context, 100_000);
        _ = c.pcre2_set_depth_limit_8(context, 1_000);
        _ = c.pcre2_set_heap_limit_8(context, 8 * 1024);
        const data = c.pcre2_match_data_create_from_pattern_8(self.code, null) orelse return error.OutOfMemory;
        return .{ .regex = self, .context = context, .data = data };
    }
};

pub const Matcher = struct {
    regex: Regex,
    context: *c.pcre2_match_context_8,
    data: *c.pcre2_match_data_8,

    pub fn deinit(self: *Matcher) void {
        c.pcre2_match_data_free_8(self.data);
        c.pcre2_match_context_free_8(self.context);
        self.* = undefined;
    }

    pub fn search(self: *Matcher, subject: []const u8, start: usize) Error!Match {
        if (start > subject.len) return error.InvalidOffset;
        const rc = c.pcre2_match_8(self.regex.code, subject.ptr, subject.len, start, c.PCRE2_NOTEMPTY, self.data, self.context);
        if (rc < 0) return switch (rc) {
            c.PCRE2_ERROR_NOMATCH => error.NoMatch,
            c.PCRE2_ERROR_MATCHLIMIT, c.PCRE2_ERROR_DEPTHLIMIT, c.PCRE2_ERROR_HEAPLIMIT => error.MatchLimitExceeded,
            c.PCRE2_ERROR_NOMEMORY => error.OutOfMemory,
            c.PCRE2_ERROR_BADOFFSET, c.PCRE2_ERROR_BADUTFOFFSET => error.InvalidOffset,
            c.PCRE2_ERROR_UTF8_ERR21...c.PCRE2_ERROR_UTF8_ERR1 => error.InvalidUtf8,
            else => error.UnexpectedError,
        };
        const offsets = c.pcre2_get_ovector_pointer_8(self.data);
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

test "independent matchers can be reused after errors without leaking match state" {
    var regex = try Regex.init("(*NO_START_OPT)(*NO_AUTO_POSSESS)^(a+)+$");
    defer regex.deinit();
    var first = try regex.matcher();
    defer first.deinit();
    var second = try regex.matcher();
    defer second.deinit();
    try std.testing.expectError(error.MatchLimitExceeded, first.search("a" ** 30 ++ "!", 0));
    try std.testing.expectEqual(Match{ .start = 0, .end = 2 }, try second.search("aa", 0));
    try std.testing.expectEqual(Match{ .start = 0, .end = 3 }, try first.search("aaa", 0));
    try std.testing.expectError(error.InvalidUtf8, first.search("\xff", 0));
    try std.testing.expectError(error.InvalidOffset, first.search("a", 2));
    try std.testing.expectError(error.NoMatch, first.search("b", 0));
    try std.testing.expectEqual(Match{ .start = 0, .end = 1 }, try first.search("a", 0));
    try std.testing.expectError(error.MatchLimitExceeded, first.search("a" ** 30 ++ "!", 0));
}
