const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const compat_fd = @import("../lib/compat/fd.zig");

/// pipe() that works on Windows and POSIX. For POSIX systems, this sets
/// CLOEXEC on the file descriptors.
pub fn pipe() ![2]posix.fd_t {
    switch (builtin.os.tag) {
        .macos => return compat_fd.pipe2(.{ .CLOEXEC = true }),
        else => unreachable,
    }
}
