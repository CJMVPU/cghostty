const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");
const global = @import("../global.zig");

const c = @import("posix_c");

/// Returns true if the program was launched from a desktop environment.
///
/// On macOS, this returns true if the program was launched from Finder.
///
/// On Linux GTK, this returns true if the program was launched using the
/// desktop file. This also includes when `gtk-launch` is used because I
/// can't find a way to distinguish the two scenarios.
///
/// For other platforms and app runtimes, this returns false.
pub fn launchedFromDesktop() bool {
    return switch (builtin.os.tag) {
        .macos => macos: {
            // This special case is so that if we launch the app via the
            // app bundle (i.e. via open) then we still treat it as if it
            // was launched from the desktop.
            if (build_config.artifact == .lib) lib: {
                const env = "CGHOSTTY_MAC_LAUNCH_SOURCE";
                const source = global.environ().getPosix(env) orelse break :lib;

                // Source can be "app", "cli", or "zig_run". We assume
                // its the desktop only if its "app". We may want to do
                // "zig_run" but at the moment there's no reason.
                if (std.mem.eql(u8, source, "app")) break :macos true;
            }

            break :macos c.getppid() == 1;
        },
        else => unreachable,
    };
}

/// The list of desktop environments that we detect. New Linux desktop
/// environments should only be added to this list if there's a specific reason
/// to differentiate between `gnome` and `other`.
pub const DesktopEnvironment = enum {
    macos,
};

/// Detect what desktop environment we are running under. This is mainly used
/// on Linux and BSD to enable or disable certain features but there may be more uses in
/// the future.
pub fn desktopEnvironment(_: *const std.process.Environ.Map) DesktopEnvironment {
    return switch (builtin.os.tag) {
        .macos => .macos,
        else => unreachable,
    };
}

test "desktop environment" {
    const testing = std.testing;

    // Always run these tests with a blank evironment map so that we don't get any
    // failures from values in the "real" evironment leaking in.
    switch (builtin.os.tag) {
        .macos => |tag| {
            var environ_map: std.process.Environ.Map = .init(testing.allocator);
            defer environ_map.deinit();
            try testing.expectEqual(@tagName(tag), @tagName(desktopEnvironment(&environ_map)));
        },
        else => unreachable,
    }
}
