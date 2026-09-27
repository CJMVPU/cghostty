//! Selectable presentation backend. Metal callbacks and link control belong to
//! the render thread; only initial view attachment belongs to the main thread.
const Self = @This();
const std = @import("std");
const objc = @import("objc");
const macos = @import("macos");
const global = @import("../../global.zig");
const Renderer = @import("../Renderer.zig");
const Trace = @import("../Trace.zig");
const IOSurfaceLayer = @import("IOSurfaceLayer.zig");
const IOSurface = macos.iosurface.IOSurface;
const FrameTiming = @import("../FrameTiming.zig");
const log = std.log.scoped(.metal_display_link);

layer: objc.Object,
legacy: ?IOSurfaceLayer = null,
link: ?objc.Object = null,
delegate: ?objc.Object = null,
/// Borrowed from CAMetalDisplayLinkUpdate, only during its callback.
drawable: ?objc.Object = null,
timing: ?FrameTiming = null,
sequence: u64 = 0,
window_compositor: bool = false,
/// Retained native wake sink. Accessed only under renderer.draw_mutex.
compositor_sink: ?objc.Object = null,
/// Borrowed only for the duration of a window render call.
compositor_target: ?@import("Target.zig") = null,
compositor_queue: ?objc.Object = null,

// The Objective-C delegate is retained by presentation blocks. Its state may
// outlive the renderer, but close detaches trace under this mutex first.
const State = struct {
    renderer: ?*Renderer = null,
    mutex: std.Io.Mutex = .init,
    trace: ?*Trace = null,
};
var DelegateClass: ?objc.Class = null; // Registered during main-thread init.

pub fn init(metal: bool, window_compositor: bool, device: objc.Object, pixel_format: c_ulong, latency: f32) !Self {
    if (window_compositor) {
        // Input views stay transparent; only the native window host presents.
        const layer = objc.getClass("CALayer").?.msgSend(objc.Object, "new", .{});
        return .{ .layer = layer, .window_compositor = true };
    }
    if (!metal) {
        const legacy = try IOSurfaceLayer.init();
        return .{ .layer = legacy.layer, .legacy = legacy };
    }
    const layer = objc.getClass("CAMetalLayer").?.msgSend(objc.Object, "new", .{});
    errdefer layer.release();
    layer.setProperty("device", device.value);
    layer.setProperty("pixelFormat", pixel_format);
    layer.setProperty("framebufferOnly", true);
    layer.setProperty("opaque", false);
    layer.setProperty("presentsWithTransaction", false);
    const colorspace = try macos.graphics.ColorSpace.createNamed(.displayP3);
    defer colorspace.release();
    layer.setProperty("colorspace", colorspace);
    const delegate = (try delegateClass()).msgSend(objc.Object, "new", .{});
    errdefer delegate.release();
    const state = try std.heap.c_allocator.create(State);
    state.* = .{};
    delegate.setInstanceVariable("state", objc.Object.fromId(state));
    const link = objc.getClass("CAMetalDisplayLink").?.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithMetalLayer:", .{layer});
    link.setProperty("delegate", delegate.value);
    link.setProperty("preferredFrameLatency", latency);
    link.setProperty("paused", true);
    return .{ .layer = layer, .link = link, .delegate = delegate };
}

pub fn isMetal(self: *const Self) bool {
    return self.link != null;
}

pub fn isDirect(self: *const Self) bool {
    return self.isMetal() or self.window_compositor;
}

pub fn start(self: *Self, renderer: *Renderer) void {
    const delegate = self.delegate orelse return;
    const state = stateOf(delegate);
    state.renderer = renderer;
    state.trace = &renderer.trace;
    const runloop = objc.getClass("NSRunLoop").?.msgSend(objc.Object, "currentRunLoop", .{});
    self.link.?.msgSend(void, "addToRunLoop:forMode:", .{ runloop, macos.c.kCFRunLoopDefaultMode });
}

pub fn stop(self: *Self) void {
    if (self.link) |link| link.msgSend(void, "invalidate", .{});
}

pub fn setRunning(self: *Self, running: bool, width: u32, height: u32) void {
    const link = self.link orelse return;
    const size: macos.graphics.Size = .{ .width = @floatFromInt(width), .height = @floatFromInt(height) };
    const current = self.layer.getProperty(macos.graphics.Size, "drawableSize");
    if (current.width != size.width or current.height != size.height) self.layer.setProperty("drawableSize", size);
    const paused = !running or width == 0 or height == 0;
    if (link.getProperty(bool, "paused") != paused) {
        link.setProperty("paused", paused);
        if (stateOf(self.delegate.?).trace) |trace| trace.emit("metal_state", @intFromBool(paused), @intFromFloat(link.getProperty(f32, "preferredFrameLatency") * 1000), 0);
    }
}

pub fn release(self: *Self) void {
    self.close();
    if (self.legacy) |*legacy| {
        legacy.release();
        return;
    }
    if (self.link) |link| link.release();
    if (self.delegate) |delegate| delegate.release();
    self.layer.release();
}

pub fn close(self: *Self) void {
    if (self.compositor_sink) |sink| {
        sink.release();
        self.compositor_sink = null;
    }
    if (self.legacy) |*legacy| legacy.close();
    if (self.delegate) |delegate| {
        const state = stateOf(delegate);
        state.mutex.lockUncancelable(global.io());
        defer state.mutex.unlock(global.io());
        state.trace = null;
        state.renderer = null;
    }
}

pub fn invalidate(self: *Self) void {
    if (self.legacy) |*legacy| legacy.invalidate();
}

pub fn setTrace(self: *Self, trace: *Trace) void {
    if (self.legacy) |*legacy| legacy.setTrace(trace);
}

pub fn setDisplayCallback(self: *Self, cb: IOSurfaceLayer.DisplayCallback, ctx: ?*anyopaque) void {
    if (self.legacy) |*legacy| legacy.setDisplayCallback(cb, ctx);
}

pub fn beginSurface(self: *Self, surface: ?*IOSurface) u64 {
    if (self.legacy) |*legacy| return legacy.beginSurface(surface.?);
    self.sequence +%= 1;
    return self.sequence;
}

pub fn setSurface(self: *Self, surface: ?*IOSurface, sequence: u64) !void {
    try self.legacy.?.setSurface(surface.?, sequence);
}

pub fn setSurfaceSync(self: *Self, surface: ?*IOSurface, sequence: u64) void {
    self.legacy.?.setSurfaceSync(surface.?, sequence);
}

const Presented = objc.Block(struct { delegate: objc.c.id, sequence: u64 }, .{objc.c.id}, void);

pub fn observePresentation(self: *Self, drawable: objc.Object, sequence: u64) void {
    const delegate = self.delegate.?;
    const state = stateOf(delegate);
    if (state.trace == null or state.trace.?.file == null) return;
    var block = Presented.init(.{ .delegate = delegate.value, .sequence = sequence }, &presented);
    drawable.msgSend(void, "addPresentedHandler:", .{&block});
}

fn presented(block: *const Presented.Context, drawable_id: objc.c.id) callconv(.c) void {
    const state = stateOf(objc.Object.fromId(block.delegate));
    state.mutex.lockUncancelable(global.io());
    defer state.mutex.unlock(global.io());
    const trace = state.trace orelse return;
    const presented_time = objc.Object.fromId(drawable_id).getProperty(f64, "presentedTime");
    // Store the system's presentation timestamp, not callback arrival time.
    trace.emit("displayed", FrameTiming.nanoseconds(presented_time), block.sequence, 0);
}

fn stateOf(object: objc.Object) *State {
    return @ptrCast(@alignCast(object.getInstanceVariable("state").value));
}

fn needsUpdate(id: objc.c.id, _: objc.c.SEL, _: objc.c.id, update_id: objc.c.id) callconv(.c) void {
    const renderer = stateOf(objc.Object.fromId(id)).renderer orelse return;
    const layer = &renderer.api.layer;
    const update = objc.Object.fromId(update_id);
    layer.drawable = update.getProperty(objc.Object, "drawable");
    const ca_now = FrameTiming.CACurrentMediaTime();
    const now = @as(f64, @floatFromInt(Trace.clock())) / std.time.ns_per_s;
    const target = update.getProperty(f64, "targetPresentationTimestamp");
    const deadline = update.getProperty(f64, "targetTimestamp");
    layer.timing = FrameTiming.init(now, ca_now, target);
    defer {
        layer.drawable = null;
        layer.timing = null;
        // Recompute libxev's next timer deadline after animation state changes.
        macos.c.CFRunLoopStop(macos.c.CFRunLoopGetCurrent());
    }
    renderer.trace.emit("metal_tick", FrameTiming.nanoseconds(deadline), FrameTiming.nanoseconds(target), layer.sequence +% 1);
    renderer.trace.emit("metal_callback", FrameTiming.nanoseconds(ca_now), layer.sequence +% 1, 0);
    renderer.drawFrame(false) catch |err| log.err("drawing failed: {}", .{err});
    renderer.syncDisplayLink(null, null);
}

fn delegateClass() !objc.Class {
    if (DelegateClass) |class| return class;
    var class = objc.allocateClassPair(objc.getClass("NSObject").?, "CGhosttyMetalDisplayLinkDelegate") orelse return error.ObjCFailed;
    errdefer objc.disposeClassPair(class);
    if (!class.addIvar("state")) return error.ObjCFailed;
    class.replaceMethod("metalDisplayLink:needsUpdate:", needsUpdate);
    class.replaceMethod("dealloc", struct {
        fn dealloc(id: objc.c.id, _: objc.c.SEL) callconv(.c) void {
            const object = objc.Object.fromId(id);
            if (object.getInstanceVariable("state").value != null) std.heap.c_allocator.destroy(stateOf(object));
            object.msgSendSuper(objc.getClass("NSObject").?, void, "dealloc", .{});
        }
    }.dealloc);
    objc.registerClassPair(class);
    DelegateClass = class;
    return class;
}
