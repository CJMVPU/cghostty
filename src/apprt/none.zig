//! Runtime for application command-line actions and core tests.
const internal_os = @import("../os/main.zig");
pub const resourcesDir = internal_os.resourcesDir;
pub const App = if (@import("builtin").is_test) struct {
    // Headless IO handlers may publish a surface message. There is no native
    // event loop to wake in core tests, but queue ownership remains real.
    pub fn wakeup(_: *@This()) void {}
} else struct {};
pub const Surface = struct {};
