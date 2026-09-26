//! Renderer implementation and utilities. The renderer is responsible for
//! taking the internal screen state and turning into some output format,
//! usually for a screen.
//!
//! The Metal renderer presents frames through an IOSurface-backed layer
//! attached to the native macOS view supplied by the application runtime.

const cursor = @import("renderer/cursor.zig");
const message = @import("renderer/message.zig");
const size = @import("renderer/size.zig");
pub const FrameScheduler = @import("renderer/FrameScheduler.zig");
pub const CellUpload = @import("renderer/CellUpload.zig");
pub const Presentation = @import("renderer/Presentation.zig");
pub const CursorMotion = @import("renderer/CursorMotion.zig");
pub const SmoothCursor = @import("renderer/SmoothCursor.zig");
pub const CursorTrail = @import("renderer/CursorTrail.zig");
pub const Metal = @import("renderer/Metal.zig");
pub const Options = @import("renderer/Options.zig");
pub const Thread = @import("renderer/Thread.zig");
pub const State = @import("renderer/State.zig");
pub const CursorStyle = cursor.Style;
pub const Message = message.Message;
pub const Size = size.Size;
pub const Coordinate = size.Coordinate;
pub const CellSize = size.CellSize;
pub const ScreenSize = size.ScreenSize;
pub const GridSize = size.GridSize;
pub const Padding = size.Padding;
pub const cursorStyle = cursor.style;
pub const cursorNeedsBlink = cursor.needsBlink;
pub const lib = @import("lib/main.zig");

/// The native Metal renderer.
pub const Renderer = @import("renderer/Renderer.zig");

/// Renderer health reported through the internal C bridge.
pub const Health = enum(c_int) {
    healthy,
    unhealthy,

    test "ghostty.h Health" {
        try lib.checkGhosttyHEnum(Health, "GHOSTTY_RENDERER_HEALTH_");
    }
};

test {
    // Explicit test roots: referring to Renderer alone does not analyze its
    // lazily imported helpers when a focused test filter is used.
    _ = @import("renderer/ScrollMotion.zig");
    _ = @import("renderer/ScrollScene.zig");
    _ = @import("renderer/CursorOverlay.zig");
    _ = @import("renderer/ScrollHit.zig");
    _ = @import("terminal/ScrollState.zig");
    _ = @import("renderer/AtlasUpload.zig");
    _ = @import("renderer/RowUpload.zig");
    _ = @import("renderer/link.zig");
    _ = @import("renderer/row.zig");
    _ = @import("renderer/cell.zig");
    _ = CursorMotion;
    // Our comptime-chosen renderer
    _ = Renderer;

    _ = cursor;
    _ = message;
    _ = SmoothCursor;
    _ = CursorTrail;
    _ = FrameScheduler;
    _ = CellUpload;
    _ = Presentation;
    _ = @import("renderer/PresentationQueue.zig");
    _ = @import("renderer/Trace.zig");
    _ = size;
    _ = Thread;
    _ = State;
    _ = @import("renderer/RenderHold.zig");
}
