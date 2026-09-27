//! Drive the render thread's existing kqueue from a CF/NSRunLoop. No polling
//! interval: the run-loop timeout follows libxev's earliest timer deadline.
const std = @import("std");
const objc = @import("objc");
const c = @import("macos").c;
const xev = @import("../global.zig").xev;

pub fn run(loop: *xev.Loop) !void {
    const backend = loop;
    const descriptor = c.CFFileDescriptorCreate(null, backend.kqueue_fd, 0, ready, null) orelse return error.RunLoopDescriptorFailed;
    defer c.CFRelease(descriptor);
    defer c.CFFileDescriptorInvalidate(descriptor);
    const source = c.CFFileDescriptorCreateRunLoopSource(null, descriptor, 0) orelse return error.RunLoopSourceFailed;
    defer c.CFRelease(source);
    const runloop = c.CFRunLoopGetCurrent();
    c.CFRunLoopAddSource(runloop, source, c.kCFRunLoopDefaultMode);
    defer c.CFRunLoopRemoveSource(runloop, source, c.kCFRunLoopDefaultMode);
    while (!loop.stopped()) {
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();
        try loop.run(.no_wait);
        if (loop.stopped()) break;
        // Cancel completions can enqueue work without a kernel event. Still
        // service the run loop so sustained output cannot starve display links.
        const pending = !backend.submissions.empty() or !backend.completions.empty() or !backend.cancellations.empty();
        backend.update_now();
        const timeout: f64 = if (pending) 0 else if (backend.timers.peek()) |timer|
            @max(0, @as(f64, @floatFromInt(timer.next.sec - backend.cached_now.sec)) +
                @as(f64, @floatFromInt(timer.next.nsec - backend.cached_now.nsec)) / std.time.ns_per_s)
        else
            1e10;
        c.CFFileDescriptorEnableCallBacks(descriptor, c.kCFFileDescriptorReadCallBack);
        _ = c.CFRunLoopRunInMode(c.kCFRunLoopDefaultMode, timeout, 1);
    }
}

fn ready(_: c.CFFileDescriptorRef, _: c.CFOptionFlags, _: ?*anyopaque) callconv(.c) void {
    c.CFRunLoopStop(c.CFRunLoopGetCurrent());
}

test "MetalRunLoop services timers and cross-thread async wakeups" {
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();
    var event = try xev.Async.init();
    defer event.deinit();
    var timer = try xev.Timer.init();
    defer timer.deinit();
    const State = struct {
        event: *xev.Async,
        ready: std.Io.Semaphore = .{ .permits = 0 },
        fired: bool = false,
        fn producer(self: *@This()) void {
            self.ready.waitUncancelable(std.testing.io);
            self.event.notify() catch unreachable;
        }
        fn timed(self: ?*@This(), _: *xev.Loop, _: *xev.Completion, result: xev.Timer.RunError!void) xev.CallbackAction {
            result catch unreachable;
            self.?.ready.post(std.testing.io);
            return .disarm;
        }
        fn notified(self: ?*@This(), l: *xev.Loop, _: *xev.Completion, result: xev.Async.WaitError!void) xev.CallbackAction {
            result catch unreachable;
            self.?.fired = true;
            l.stop();
            return .disarm;
        }
    };
    var state = State{ .event = &event };
    var event_completion: xev.Completion = .{};
    var timer_completion: xev.Completion = .{};
    event.wait(&loop, &event_completion, State, &state, State.notified);
    timer.run(&loop, &timer_completion, 1, State, &state, State.timed);
    const worker = try std.Thread.spawn(.{}, State.producer, .{&state});
    defer worker.join();
    try run(&loop);
    try std.testing.expect(state.fired);
}
