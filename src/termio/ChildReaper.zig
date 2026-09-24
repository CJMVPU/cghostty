//! Reap a closing terminal's child without retaining its Surface or IO loop.
//! Only a PID crosses into the detached worker; all waits use Darwin syscalls.
const std = @import("std");
const c = @import("posix_c");
const posix = std.posix;
// libSystem's global queue owns the work item, so shutdown does not need a
// fallible thread allocation or retain any application-owned executor.
extern "c" fn dispatch_get_global_queue(c_long, c_ulong) *anyopaque;
extern "c" fn dispatch_async_f(*anyopaque, ?*anyopaque, *const fn (?*anyopaque) callconv(.c) void) void;

pub fn start(pid: c.pid_t) void {
    std.debug.assert(pid > 0);
    dispatch_async_f(dispatch_get_global_queue(0, 0), @ptrFromInt(@as(usize, @intCast(pid))), callback);
}

fn callback(context: ?*anyopaque) callconv(.c) void {
    finish(@intCast(@intFromPtr(context)));
}

fn reaped(pid: c.pid_t) bool {
    const result = std.c.waitpid(pid, null, std.c.W.NOHANG);
    return result == pid or (result < 0 and posix.errno(result) == .CHILD);
}

fn signal(pid: c.pid_t, sig: c_int) void {
    // Never signal the parent's group when close races the child's setsid.
    // A child that has not been reaped cannot have its PID reused.
    const target = if (c.getpgid(pid) == pid) -pid else pid;
    _ = c.kill(target, sig);
}

fn now() i128 {
    var value: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &value) != 0) return 0;
    return @as(i128, value.sec) * std.time.ns_per_s + value.nsec;
}

fn finish(pid: c.pid_t) void {
    if (reaped(pid)) return;
    const queue = std.c.kqueue();
    if (queue >= 0) {
        defer _ = std.c.close(queue);
        // Do not leak the short-lived watcher into a concurrently opened shell.
        _ = std.c.fcntl(queue, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
        const change: std.c.Kevent = .{
            .ident = @intCast(pid),
            .filter = std.c.EVFILT.PROC,
            .flags = std.c.EV.ADD | std.c.EV.ONESHOT,
            .fflags = std.c.NOTE.EXIT,
            .data = 0,
            .udata = 0,
        };
        var events: [1]std.c.Kevent = undefined;
        const registered = std.c.kevent(queue, @ptrCast(&change), 1, &events, 0, null) == 0;
        if (!reaped(pid)) signal(pid, c.SIGHUP) else return;
        // This is an exit deadline, not a fixed delay: NOTE_EXIT wakes immediately.
        const deadline = now() + 250 * std.time.ns_per_ms;
        while (registered) {
            const remaining = deadline - now();
            if (remaining <= 0) break;
            const timeout: std.c.timespec = .{
                .sec = @intCast(@divTrunc(remaining, std.time.ns_per_s)),
                .nsec = @intCast(@mod(remaining, std.time.ns_per_s)),
            };
            const count = std.c.kevent(queue, &.{}, 0, &events, 1, &timeout);
            if (count < 0 and posix.errno(count) == .INTR) continue;
            break;
        }
    }
    if (reaped(pid)) return;
    signal(pid, c.SIGKILL);
    // A pathological kernel wait can hold only this independent worker, never
    // the application's UI, render resources, terminal state or IO allocator.
    while (true) {
        const result = std.c.waitpid(pid, null, 0);
        if (result < 0 and posix.errno(result) == .INTR) continue;
        return;
    }
}

// Tests create only their own children. The readiness pipe ensures that HUP
// dispositions and the process group are established before shutdown starts.
fn testChild(ignore_hup: bool, own_group: bool) !c.pid_t {
    var ready: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&ready));
    defer _ = std.c.close(ready[0]);
    defer _ = std.c.close(ready[1]);
    const pid = std.c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        if (own_group and c.setsid() < 0) std.c._exit(1);
        posix.sigaction(.HUP, &.{
            .handler = .{ .handler = if (ignore_hup) std.c.SIG.IGN else std.c.SIG.DFL },
            .mask = std.mem.zeroes(std.c.sigset_t),
            .flags = 0,
        }, null);
        _ = std.c.write(ready[1], "!", 1);
        while (true) _ = c.pause();
    }
    errdefer {
        _ = c.kill(pid, c.SIGKILL);
        _ = std.c.waitpid(pid, null, 0);
    }
    var poll: [1]std.c.pollfd = .{.{ .fd = ready[0], .events = std.c.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(c_int, 1), std.c.poll(&poll, 1, 2000));
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 1), std.c.read(ready[0], &byte, 1));
    return pid;
}

fn expectEventuallyReaped(pid: c.pid_t) !void {
    const deadline = now() + 2 * std.time.ns_per_s;
    // Do not waitpid here: the production reaper must collect the zombie.
    while (c.kill(pid, 0) == 0) {
        if (now() >= deadline) {
            _ = c.kill(pid, c.SIGKILL);
            return error.ChildNotReaped;
        }
        const pause: std.c.timespec = .{ .sec = 0, .nsec = std.time.ns_per_ms };
        _ = std.c.nanosleep(&pause, null);
    }
    try std.testing.expect(reaped(pid));
}

test "termio child reaper returns before stubborn child exits and collects it" {
    const pid = try testChild(true, true);
    const before = now();
    start(pid);
    try std.testing.expect(now() - before < 200 * std.time.ns_per_ms);
    try expectEventuallyReaped(pid);
}

test "termio child reaper closes child before setsid without signaling parent group" {
    const pid = try testChild(false, false);
    start(pid);
    try expectEventuallyReaped(pid);
}

test "termio child reaper accepts an already reaped child" {
    const pid = try testChild(false, true);
    _ = c.kill(pid, c.SIGKILL);
    while (std.c.waitpid(pid, null, 0) < 0) {
        if (posix.errno(-1) != .INTR) break;
    }
    // ECHILD returns before either a signal or an event registration.
    finish(pid);
    try std.testing.expect(reaped(pid));
}
