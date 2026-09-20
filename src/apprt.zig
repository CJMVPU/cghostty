//! "apprt" is the "application runtime" package. This abstracts the
//! application runtime and lifecycle management such as creating windows,
//! getting user input (mouse/keyboard), etc.
//!
//! The embedded runtime connects the core to the native macOS app. The
//! no-window runtime supports command-line tools and tests.
const build_config = @import("build_config.zig");

const structs = @import("apprt/structs.zig");

pub const action = @import("apprt/action.zig");
pub const none = @import("apprt/none.zig");
pub const embedded = @import("apprt/embedded.zig");
pub const surface = @import("apprt/surface.zig");

pub const Action = action.Action;
pub const Target = action.Target;

pub const ContentScale = structs.ContentScale;
pub const Clipboard = structs.Clipboard;
pub const ClipboardContent = structs.ClipboardContent;
pub const ClipboardReadResult = structs.ClipboardReadResult;
pub const ClipboardRequest = structs.ClipboardRequest;
pub const ClipboardRequestType = structs.ClipboardRequestType;
pub const ColorScheme = structs.ColorScheme;
pub const CursorPos = structs.CursorPos;
pub const IMEPos = structs.IMEPos;
pub const Selection = structs.Selection;
pub const SurfaceSize = structs.SurfaceSize;

/// The implementation to use for the app runtime. This is comptime chosen
/// so that every build has exactly one application runtime implementation.
/// Most callers use the App and Surface aliases below.
pub const runtime = switch (build_config.artifact) {
    .exe => none,
    .lib => embedded,
};

pub const App = runtime.App;
pub const Surface = runtime.Surface;

test {
    _ = runtime;
    _ = action;
    _ = structs;
}
