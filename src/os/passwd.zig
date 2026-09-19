const std = @import("std");
const builtin = @import("builtin");
const internal_os = @import("main.zig");
const build_config = @import("../build_config.zig");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const posix = std.posix;
const compat_fd = @import("../lib/compat/fd.zig");

const log = std.log.scoped(.passwd);

// We want to be extra sure since this will force bad symbols into our import table
comptime {}

/// Used to determine the default shell and directory on Unixes.
const c = @import("posix_c");

// Entry that is retrieved from the passwd API. This only contains the fields
// we care about.
pub const Entry = struct {
    shell: ?[:0]const u8 = null,
    home: ?[:0]const u8 = null,
    name: ?[:0]const u8 = null,
};

/// Get the passwd entry for the currently executing user.
pub fn get(alloc: Allocator) !Entry {
    var buf: [1024]u8 = undefined;
    var pw: c.struct_passwd = undefined;
    var pw_ptr: ?*c.struct_passwd = null;
    const res = c.getpwuid_r(c.getuid(), &pw, &buf, buf.len, &pw_ptr);
    if (res != 0) {
        log.warn("error retrieving pw entry code={d}", .{res});
        return Entry{};
    }

    if (pw_ptr == null) {
        // Future: let's check if a better shell is available like zsh
        log.warn("no pw entry to detect default shell, will default to 'sh'", .{});
        return Entry{};
    }

    var result: Entry = .{};

    // If we're in flatpak then our entry is always empty so we grab it
    // by shelling out to the host. note that we do HAVE an entry in the
    // sandbox but only the username is correct.

    if (pw.pw_shell) |ptr| {
        const source = std.mem.sliceTo(ptr, 0);
        const value = try alloc.dupeZ(u8, source);
        result.shell = value;
    }

    if (pw.pw_dir) |ptr| {
        const source = std.mem.sliceTo(ptr, 0);
        const value = try alloc.dupeZ(u8, source);
        result.home = value;
    }

    if (pw.pw_name) |ptr| {
        const source = std.mem.sliceTo(ptr, 0);
        const value = try alloc.dupeZ(u8, source);
        result.name = value;
    }

    return result;
}

test {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // We should be able to get an entry
    const entry = try get(alloc);
    try testing.expect(entry.shell != null);
    try testing.expect(entry.home != null);
}
