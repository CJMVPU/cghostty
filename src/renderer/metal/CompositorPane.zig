//! Per-pane encoding context. Only the native window compositor presents.
const Self = @This();
const objc = @import("objc");
const FrameTiming = @import("../FrameTiming.zig");

/// Transparent structural layer for the input view, never a presentation layer.
layer: objc.Object,
timing: ?FrameTiming = null,
sequence: u64 = 0,
/// Retained native wake sink, protected by renderer.draw_mutex.
compositor_sink: ?objc.Object = null,
/// Borrowed only during the window's render callback.
compositor_queue: ?objc.Object = null,

pub fn init() Self {
    return .{ .layer = objc.getClass("CALayer").?.msgSend(objc.Object, "new", .{}) };
}

pub fn close(self: *Self) void {
    if (self.compositor_sink) |sink| sink.release();
    self.compositor_sink = null;
}

pub fn release(self: *Self) void {
    self.close();
    self.layer.release();
}
