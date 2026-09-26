//! A wrapper around a CALayer with a utility method
//! for settings its `contents` to an IOSurface.
const IOSurfaceLayer = @This();

const std = @import("std");
const global = @import("../../global.zig");
const Trace = @import("../Trace.zig");
const PresentationQueue = @import("../PresentationQueue.zig");
const objc = @import("objc");
const macos = @import("macos");

const IOSurface = macos.iosurface.IOSurface;

const log = std.log.scoped(.IOSurfaceLayer);

/// We subclass CALayer with a custom display handler, we only need
/// to make the subclass once, and then we can use it as a singleton.
var Subclass: ?objc.Class = null;

/// The underlying CALayer
layer: objc.Object,
state: *State,

const Pending = struct { surface: *IOSurface, queued_ns: u64 };
const Queue = PresentationQueue.Queue(Pending);

// Dispatch blocks can outlive both the renderer and its native view. Keep the
// mailbox alive independently; close() detaches the borrowed trace before teardown.
const State = struct {
    refs: std.atomic.Value(usize) = .init(1),
    mutex: std.Io.Mutex = .init,
    queue: Queue = .{},
    trace: ?*Trace = null,

    fn release(self: *State) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) std.heap.c_allocator.destroy(self);
    }

    fn discard(self: *State, entry: ?Queue.Entry, reason: u64) void {
        if (entry) |e| {
            if (self.trace) |trace| trace.emit("present_drop", reason, e.sequence, 0);
            e.value.surface.release();
        }
    }
};

pub fn init() !IOSurfaceLayer {
    // The layer returned by `[CALayer layer]` is autoreleased, which means
    // that at the end of the current autorelease pool it will be deallocated
    // if it isn't retained, so we retain it here manually an extra time.
    const layer = (try getSubclass()).msgSend(
        objc.Object,
        objc.sel("layer"),
        .{},
    ).retain();
    errdefer layer.release();

    // The layer gravity is set to top-left so that the contents aren't
    // stretched during resize operations before a new frame has been drawn.
    layer.setProperty("contentsGravity", macos.animation.kCAGravityTopLeft);

    layer.setInstanceVariable("display_cb", .{ .value = null });
    layer.setInstanceVariable("display_ctx", .{ .value = null });

    const state = try std.heap.c_allocator.create(State);
    state.* = .{};
    return .{ .layer = layer, .state = state };
}

pub fn release(self: *IOSurfaceLayer) void {
    // The layer may be retained by the view after we release our reference.
    // Clear the callback first so that a later display pass can't access the
    // renderer that owned this wrapper after it has been freed.
    self.setDisplayCallback(null, null);
    self.close();
    self.state.release();
    self.layer.release();
}

/// Set once the renderer has reached its stable address (loopEnter).
pub fn setTrace(self: *IOSurfaceLayer, trace: *Trace) void {
    self.state.mutex.lockUncancelable(global.io());
    defer self.state.mutex.unlock(global.io());
    if (!self.state.queue.closed) self.state.trace = trace;
}

/// Stop pending callbacks from touching the renderer, even if main is blocked.
pub fn close(self: *IOSurfaceLayer) void {
    self.state.mutex.lockUncancelable(global.io());
    defer self.state.mutex.unlock(global.io());
    self.state.discard(self.state.queue.close(), 3);
    self.state.trace = null;
}

pub fn invalidate(self: *IOSurfaceLayer) void {
    self.state.mutex.lockUncancelable(global.io());
    defer self.state.mutex.unlock(global.io());
    self.state.discard(self.state.queue.invalidate(), 3);
}

/// Called before encoding into a reused target. A queued IOSurface is a live
/// buffer, not a snapshot: never apply it after the next GPU write has begun.
pub fn beginSurface(self: *IOSurfaceLayer, surface: *IOSurface) u64 {
    self.state.mutex.lockUncancelable(global.io());
    defer self.state.mutex.unlock(global.io());
    if (self.state.queue.pending) |entry| {
        if (entry.value.surface == surface) {
            self.state.queue.pending = null;
            self.state.discard(entry, 4);
        }
    }
    return self.state.queue.reserve();
}

/// One main-queue callback consumes the latest completed frame. The callback
/// owns the state and layer, rather than retaining a particular reusable target.
pub fn setSurface(self: *IOSurfaceLayer, surface: *IOSurface, sequence: u64) !void {
    const state = self.state;
    state.mutex.lockUncancelable(global.io());
    defer state.mutex.unlock(global.io());
    const queued_ns = if (state.trace != null and state.trace.?.file != null) Trace.clock() else 0;
    const result = state.queue.offer(.{ .sequence = sequence, .value = .{ .surface = surface, .queued_ns = queued_ns } });
    if (!result.accepted) {
        if (state.trace) |trace| trace.emit("present_drop", 0, sequence, 0);
        return;
    }
    surface.retain();
    state.discard(result.displaced, 1);
    if (!result.schedule) return;

    _ = state.refs.fetchAdd(1, .monotonic);
    // objc.c.id is retained by the copied Objective-C block. The state uses
    // an explicit reference because it is not an Objective-C object.
    var block = SetSurfaceBlock.init(.{ .layer = self.layer.value, .state = state }, &setSurfaceCallback);
    macos.dispatch.dispatch_async(@ptrCast(macos.dispatch.queue.getMain()), @ptrCast(&block));
}

/// Called only by Core Animation's synchronous main-thread display path.
pub fn setSurfaceSync(self: *IOSurfaceLayer, surface: *IOSurface, sequence: u64) void {
    const state = self.state;
    state.mutex.lockUncancelable(global.io());
    defer state.mutex.unlock(global.io());
    const result = state.queue.supersede(sequence);
    if (!result.accepted) return;
    state.discard(result.displaced, 1);
    self.layer.setProperty("contents", surface);
    if (state.trace) |trace| trace.emit("present", 0, sequence, 1);
}

const SetSurfaceBlock = objc.Block(struct {
    layer: objc.c.id,
    state: *State,
}, .{}, void);

fn setSurfaceCallback(block: *const SetSurfaceBlock.Context) callconv(.c) void {
    const state = block.state;
    defer state.release();
    state.mutex.lockUncancelable(global.io());
    defer state.mutex.unlock(global.io());
    const entry = state.queue.take() orelse return;
    const surface = entry.value.surface;
    defer surface.release();
    const layer = objc.Object.fromId(block.layer);

    const bounds = layer.getProperty(macos.graphics.Rect, "bounds");
    const scale = layer.getProperty(f64, "contentsScale");
    const width: usize = @intFromFloat(bounds.size.width * scale);
    const height: usize = @intFromFloat(bounds.size.height * scale);
    if (width != surface.getWidth() or height != surface.getHeight()) {
        if (state.trace) |trace| trace.emit("present_drop", 2, entry.sequence, 0);
        return;
    }
    layer.setProperty("contents", surface);
    if (state.trace) |trace| {
        const wait_ns = if (entry.value.queued_ns != 0) Trace.clock() - entry.value.queued_ns else 0;
        trace.emit("present", wait_ns, entry.sequence, 0);
    }
}

pub const DisplayCallback = ?*align(8) const fn (?*anyopaque) void;

pub fn setDisplayCallback(
    self: *IOSurfaceLayer,
    display_cb: DisplayCallback,
    display_ctx: ?*anyopaque,
) void {
    self.layer.setInstanceVariable(
        "display_cb",
        objc.Object.fromId(@constCast(display_cb)),
    );
    self.layer.setInstanceVariable(
        "display_ctx",
        objc.Object.fromId(display_ctx),
    );
}

fn getSubclass() error{ObjCFailed}!objc.Class {
    if (Subclass) |c| return c;

    const CALayer =
        objc.getClass("CALayer") orelse return error.ObjCFailed;

    var subclass =
        objc.allocateClassPair(CALayer, "IOSurfaceLayer") orelse return error.ObjCFailed;
    errdefer objc.disposeClassPair(subclass);

    if (!subclass.addIvar("display_cb")) return error.ObjCFailed;
    if (!subclass.addIvar("display_ctx")) return error.ObjCFailed;

    subclass.replaceMethod("display", struct {
        fn display(target: objc.c.id, sel: objc.c.SEL) callconv(.c) void {
            _ = sel;
            const self = objc.Object.fromId(target);
            const display_cb: DisplayCallback = @ptrFromInt(@intFromPtr(
                self.getInstanceVariable("display_cb").value,
            ));
            if (display_cb) |cb| cb(
                @ptrCast(self.getInstanceVariable("display_ctx").value),
            );
        }
    }.display);

    // Disable all animations for this layer by returning null for all actions.
    subclass.replaceMethod("actionForKey:", struct {
        fn actionForKey(
            target: objc.c.id,
            sel: objc.c.SEL,
            key: objc.c.id,
        ) callconv(.c) objc.c.id {
            _ = target;
            _ = sel;
            _ = key;
            return objc.getClass("NSNull").?.msgSend(objc.c.id, "null", .{});
        }
    }.actionForKey);

    objc.registerClassPair(subclass);

    Subclass = subclass;

    return subclass;
}
