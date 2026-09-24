//! A coalesced change notification. Subscription is protected independently
//! of the terminal lock, so UI, IO and renderer producers can all publish.
const Self = @This();
const std = @import("std");
const global = @import("../../global.zig");

mutex: std.Io.Mutex = .init,
listening: std.atomic.Value(bool) = .init(false),
subscriber: ?*global.xev.Async = null,
dirty: bool = false,
visible: bool = true,

pub fn attach(self: *Self, subscriber: *global.xev.Async) void {
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    std.debug.assert(self.subscriber == null);
    self.subscriber = subscriber;
    self.listening.store(true, .release);
    self.dirty = true;
    if (self.visible) subscriber.notify() catch {};
}

/// Call before joining/freeing the worker. No publisher can retain its handle.
pub fn detach(self: *Self) void {
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    self.listening.store(false, .release);
    self.subscriber = null;
    self.dirty = false;
}

pub fn notify(self: *Self) void {
    // Most terminals have no search session: do not add a lock to their IO path.
    if (!self.listening.load(.acquire)) return;
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    if (self.dirty) return;
    self.dirty = true;
    if (self.visible) if (self.subscriber) |subscriber| subscriber.notify() catch {};
}

pub fn setVisible(self: *Self, visible: bool) void {
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    if (self.visible == visible) return;
    self.visible = visible;
    self.dirty = true;
    if (visible) if (self.subscriber) |subscriber| subscriber.notify() catch {};
}

pub fn pending(self: *Self) bool {
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    return self.visible and self.dirty;
}

pub fn consume(self: *Self) bool {
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    if (!self.visible) return false;
    const dirty = self.dirty;
    self.dirty = false;
    return dirty;
}

test "search change signal coalesces and retains hidden changes" {
    const t = std.testing;
    var signal: Self = .{};
    var wake = try global.xev.Async.init();
    defer wake.deinit();
    signal.attach(&wake);
    defer signal.detach();
    try t.expect(signal.consume());
    try t.expect(!signal.consume());
    for (0..100) |_| signal.notify();
    try t.expect(signal.consume());
    try t.expect(!signal.pending());
    signal.setVisible(false);
    signal.notify();
    try t.expect(!signal.consume());
    try t.expect(!signal.pending());
    signal.setVisible(true);
    try t.expect(signal.pending());
    try t.expect(signal.consume());
    signal.detach();
    signal.notify(); // A publisher after detachment never touches the old handle.
    try t.expect(signal.subscriber == null);
}
