const std = @import("std");
const build_config = @import("../build_config.zig");
const global = @import("../global.zig");

const c = @import("posix_c");

/// Returns true for an app-bundle launch or a process parented by launchd.
pub fn launchedFromDesktop() bool {
    // Swift identifies launches through the app bundle, including `open`.
    if (build_config.artifact == .lib) lib: {
        const source = global.environ().getPosix("CGHOSTTY_MAC_LAUNCH_SOURCE") orelse break :lib;
        if (std.mem.eql(u8, source, "app")) return true;
    }
    return c.getppid() == 1;
}
