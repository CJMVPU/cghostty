//! One lazy, bounded CF release worker per app font set. Each shaper waits
//! only for its own accepted batches before its allocator context can die.
const Service = @This();
const std = @import("std");
const macos = @import("macos");
const global = @import("../global.zig");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.cf_release_service);

const capacity = 64;
mutex: std.Io.Mutex = .init,
ready: std.Io.Condition = .init,
messages: [capacity]Message = undefined,
head: usize = 0,
len: usize = 0,
clients: usize = 0,
worker: ?std.Thread = null,
stopping: bool = false,
spawn_fn: *const fn (*Service) std.Thread.SpawnError!std.Thread = spawn,
release_fn: *const fn ([]*anyopaque) void = releaseObjects,

const Message = struct {
    refs: []*anyopaque,
    alloc: Allocator,
    client: *Client,
};

pub fn init() Service {
    return .{};
}

/// All clients must have closed. The worker drains accepted batches before
/// exiting; there is no abnormal loop state that can discard owned objects.
pub fn deinit(self: *Service) void {
    self.mutex.lockUncancelable(global.io());
    std.debug.assert(self.clients == 0);
    self.stopping = true;
    self.ready.signal(global.io());
    const worker = self.worker;
    self.mutex.unlock(global.io());
    if (worker) |thread| thread.join();
    self.* = undefined;
}

pub fn client(self: *Service, alloc: Allocator) Allocator.Error!*Client {
    const result = try alloc.create(Client);
    result.* = .{ .service = self, .alloc = alloc };
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    std.debug.assert(!self.stopping);
    self.clients += 1;
    return result;
}

pub const Client = struct {
    service: *Service,
    alloc: Allocator,
    mutex: std.Io.Mutex = .init,
    drained: std.Io.Condition = .init,
    pending: usize = 0,

    /// Consumes the owned slice on all paths. A full queue or failed spawn
    /// releases locally instead of blocking a renderer behind queue capacity.
    pub fn submit(self: *Client, refs: []*anyopaque, alloc: Allocator) void {
        self.mutex.lockUncancelable(global.io());
        self.pending += 1;
        self.mutex.unlock(global.io());
        const message: Message = .{ .refs = refs, .alloc = alloc, .client = self };
        if (!self.service.enqueue(message)) self.service.dispose(message);
    }

    /// Call only after this shaper stops producing. The completion barrier
    /// protects both the client and any stack-backed allocator context.
    pub fn destroy(self: *Client) void {
        self.mutex.lockUncancelable(global.io());
        while (self.pending != 0) self.drained.waitUncancelable(global.io(), &self.mutex);
        self.mutex.unlock(global.io());
        const service = self.service;
        service.mutex.lockUncancelable(global.io());
        service.clients -= 1;
        service.mutex.unlock(global.io());
        self.alloc.destroy(self);
    }

    fn complete(self: *Client) void {
        self.mutex.lockUncancelable(global.io());
        defer self.mutex.unlock(global.io());
        self.pending -= 1;
        if (self.pending == 0) self.drained.signal(global.io());
    }
};

fn enqueue(self: *Service, message: Message) bool {
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    if (self.stopping or self.len == capacity) return false;
    if (self.worker == null) self.worker = self.spawn_fn(self) catch |err| {
        log.warn("CF worker spawn failed, releasing locally err={}", .{err});
        return false;
    };
    self.messages[(self.head + self.len) % capacity] = message;
    self.len += 1;
    self.ready.signal(global.io());
    return true;
}

fn spawn(self: *Service) std.Thread.SpawnError!std.Thread {
    return std.Thread.spawn(.{}, run, .{self});
}

fn run(self: *Service) void {
    @import("macos.zig").pthread_setname_np(&"cf_release".*);
    @import("macos.zig").setQosClass(.utility) catch {};
    while (true) {
        self.mutex.lockUncancelable(global.io());
        while (self.len == 0 and !self.stopping) self.ready.waitUncancelable(global.io(), &self.mutex);
        if (self.len == 0) {
            self.mutex.unlock(global.io());
            return;
        }
        const message = self.messages[self.head];
        self.head = (self.head + 1) % capacity;
        self.len -= 1;
        self.mutex.unlock(global.io());
        self.dispose(message);
    }
}

fn dispose(self: *Service, message: Message) void {
    self.release_fn(message.refs);
    message.alloc.free(message.refs);
    message.client.complete(); // No client/allocator access after this barrier.
}

fn releaseObjects(refs: []*anyopaque) void {
    for (refs) |ref| macos.foundation.CFRelease(ref);
}

test "CF release service is lazy and drains client allocations before closing" {
    const t = std.testing;
    const CF = struct {
        extern "c" fn CFRetain(*anyopaque) *anyopaque;
        extern "c" fn CFGetRetainCount(*anyopaque) isize;
    };
    var service: Service = .init();
    defer service.deinit();
    var owner = t.FailingAllocator.init(t.allocator, .{});
    const producer = try service.client(owner.allocator());
    try t.expect(service.worker == null);
    const object = try macos.foundation.MutableArray.create();
    defer object.release();
    _ = CF.CFRetain(object);
    const refs = try owner.allocator().alloc(*anyopaque, 1);
    refs[0] = object;
    producer.submit(refs, owner.allocator());
    producer.destroy();
    try t.expectEqual(@as(isize, 1), CF.CFGetRetainCount(object));
    try t.expectEqual(owner.allocated_bytes, owner.freed_bytes);
    try t.expectEqual(@as(usize, 0), service.clients);
}

test "CF release service full queues and spawn failures release locally" {
    const t = std.testing;
    const Probe = struct {
        var entered: std.Io.Event = .unset;
        var allow: std.Io.Event = .unset;
        var disposed: std.atomic.Value(usize) = .init(0);
        fn release(refs: []*anyopaque) void {
            if (@intFromPtr(refs[0]) == 1) {
                entered.set(t.io);
                allow.waitUncancelable(t.io);
            }
            _ = disposed.fetchAdd(1, .monotonic);
        }
        fn failSpawn(_: *Service) std.Thread.SpawnError!std.Thread {
            return error.ThreadQuotaExceeded;
        }
    };
    Probe.entered = .unset;
    Probe.allow = .unset;
    Probe.disposed = .init(0);
    var service: Service = .init();
    defer service.deinit();
    service.release_fn = Probe.release;
    const producer = try service.client(t.allocator);
    defer producer.destroy();
    const first = try t.allocator.alloc(*anyopaque, 1);
    first[0] = @ptrFromInt(1);
    producer.submit(first, t.allocator);
    defer Probe.allow.set(t.io);
    try Probe.entered.waitTimeout(t.io, .{ .duration = .{ .raw = .fromMilliseconds(1000), .clock = .awake } });
    // A different client can close while this producer's worker is busy.
    const idle = try service.client(t.allocator);
    idle.destroy();
    for (0..capacity + 1) |_| {
        const refs = try t.allocator.alloc(*anyopaque, 1);
        refs[0] = @ptrFromInt(2);
        producer.submit(refs, t.allocator);
    }
    try t.expectEqual(@as(usize, 1), Probe.disposed.load(.monotonic));
    var failed: Service = .init();
    defer failed.deinit();
    failed.spawn_fn = Probe.failSpawn;
    failed.release_fn = Probe.release;
    const fallback = try failed.client(t.allocator);
    const refs = try t.allocator.alloc(*anyopaque, 1);
    refs[0] = @ptrFromInt(2);
    fallback.submit(refs, t.allocator);
    fallback.destroy();
    try t.expect(failed.worker == null);
    try t.expectEqual(@as(usize, 2), Probe.disposed.load(.monotonic));
}
