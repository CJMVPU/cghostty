//! Opt-in local performance trace. Never records terminal text or input.
//! Controlled by render-trace (default false) and render-trace-directory.
//! Producers never wait for the writer: contention/overflow drops are counted.
const Self = @This();
const std = @import("std");
const global = @import("../global.zig");
var serial: std.atomic.Value(u64) = .init(0);

// Kept as a cheap immutable enabled flag for callers that collect timestamps.
file: ?std.Io.File = null,
state: ?*State = null,
worker: ?std.Thread = null,
alloc: ?std.mem.Allocator = null,

const Record = struct { event: []const u8, time: u64, a: u64, b: u64, c: u64 };
const State = struct {
    const capacity = 256;
    const batch_size = 64;
    file: std.Io.File,
    mutex: std.Io.Mutex = .init,
    ready: std.Io.Condition = .init,
    records: [capacity]Record = undefined,
    len: usize = 0,
    stopping: bool = false,
    failed: std.atomic.Value(bool) = .init(false),
    dropped: std.atomic.Value(u64) = .init(0),

    fn enqueue(self: *State, record: Record) void {
        if (self.failed.load(.monotonic)) return;
        if (!self.mutex.tryLock()) {
            _ = self.dropped.fetchAdd(1, .monotonic);
            return;
        }
        defer self.mutex.unlock(global.io());
        if (self.len == capacity) {
            _ = self.dropped.fetchAdd(1, .monotonic);
            return;
        }
        self.records[self.len] = record;
        self.len += 1;
        if (self.len == batch_size) self.ready.signal(global.io());
    }

    fn run(self: *State) void {
        // Trace I/O should not inherit the renderer's interactive priority.
        @import("../os/macos.zig").setQosClass(.utility) catch {};
        var batch: [capacity]Record = undefined;
        while (true) {
            self.mutex.lockUncancelable(global.io());
            while (self.len < batch_size and !self.stopping)
                self.ready.waitUncancelable(global.io(), &self.mutex);
            const len = self.len;
            @memcpy(batch[0..len], self.records[0..len]);
            self.len = 0;
            const stopping = self.stopping;
            self.mutex.unlock(global.io());

            // Formatting and file writes happen only here, outside the lock.
            const dropped = self.dropped.swap(0, .monotonic);
            self.writeBatch(batch[0..len], dropped) catch {
                self.failed.store(true, .monotonic);
                return;
            };
            if (stopping) return;
        }
    }

    fn writeBatch(self: *State, records: []const Record, dropped: u64) !void {
        var output: [(capacity + 1) * 160]u8 = undefined;
        var len: usize = 0;
        for (records) |record| {
            const line = try std.fmt.bufPrint(output[len..], "{s},{d},{d},{d},{d}\n", .{
                record.event, record.time, record.a, record.b, record.c,
            });
            len += line.len;
        }
        if (dropped != 0) {
            const line = try std.fmt.bufPrint(output[len..], "trace_drop,{d},{d},0,0\n", .{ clock(), dropped });
            len += line.len;
        }
        if (len != 0) try self.file.writeStreamingAll(global.io(), output[0..len]);
    }
};

pub fn init(alloc: std.mem.Allocator, enabled: bool, directory: []const u8) Self {
    // The configuration switch is the sole opt-in, before any allocation/I/O.
    if (!enabled) return .{};
    if (!std.fs.path.isAbsolute(directory)) {
        std.log.warn("render-trace-directory must be an absolute path", .{});
        return .{};
    }
    std.Io.Dir.cwd().createDirPath(global.io(), directory) catch |err| {
        std.log.warn("could not create render-trace-directory err={}", .{err});
        return .{};
    };
    const path = std.fmt.allocPrint(alloc, "{s}/render-{d}-{d}.csv", .{ directory, clock(), serial.fetchAdd(1, .monotonic) }) catch return .{};
    defer alloc.free(path);
    const file = std.Io.Dir.createFileAbsolute(global.io(), path, .{ .permissions = .fromMode(0o600), .exclusive = true }) catch return .{};
    return start(alloc, file) catch {
        file.close(global.io());
        return .{};
    };
}

/// Takes file ownership on success. Heap state stays stable when Trace moves.
fn start(alloc: std.mem.Allocator, file: std.Io.File) !Self {
    const state = try alloc.create(State);
    errdefer alloc.destroy(state);
    state.* = .{ .file = file };
    const worker = try std.Thread.spawn(.{}, State.run, .{state});
    return .{ .file = file, .state = state, .worker = worker, .alloc = alloc };
}

/// Called after all producers detach. Flush the partial batch before closing.
pub fn deinit(self: *Self) void {
    const state = self.state orelse return;
    state.mutex.lockUncancelable(global.io());
    state.stopping = true;
    state.ready.signal(global.io());
    state.mutex.unlock(global.io());
    self.worker.?.join();
    state.file.close(global.io());
    self.alloc.?.destroy(state);
    self.* = .{};
}

pub fn clock() u64 {
    return @intCast(std.Io.Timestamp.now(global.io(), .awake).nanoseconds);
}

/// event,time_ns,a,b,c. Draw: wall CPU path ns / copied cell bytes / segments.
/// GPU: execution ns / healthy / unused. Timer: update kind / vsync / unused.
/// Overlay: full foreground count / submitted instances / scissor pixels.
/// Vsync: callback interval ns (restart excluded). Draw_lock/draw_total:
/// wait/total ns / synchronous / unused. Rebuild: swap-chain initialization ns.
/// Present: main-queue wait ns / submission sequence / synchronous. This is
/// layer assignment, NOT scanout. Present_drop: reason / sequence / unused;
/// reasons: 0 stale, 1 replaced, 2 size mismatch, 3 invalidated, 4 target reused.
/// State: focused / visible / unused. Trace_drop: lost records / unused / unused.
/// Names are comptime strings so queued records never borrow transient memory.
pub fn emit(self: *Self, comptime event: []const u8, a: u64, b: u64, c: u64) void {
    const state = self.state orelse return;
    state.enqueue(.{ .event = event, .time = clock(), .a = a, .b = b, .c = c });
}

test "Trace contention and full buffers drop records without waiting" {
    const t = std.testing;
    var state: State = .{ .file = undefined };
    const record: Record = .{ .event = "draw", .time = 1, .a = 2, .b = 3, .c = 4 };
    state.mutex.lockUncancelable(t.io);
    state.enqueue(record); // Would deadlock if the producer waited for the lock.
    state.mutex.unlock(t.io);
    try t.expectEqual(@as(u64, 1), state.dropped.load(.monotonic));
    for (0..State.capacity + 10) |_| state.enqueue(record);
    try t.expectEqual(State.capacity, state.len);
    try t.expectEqual(@as(u64, 11), state.dropped.load(.monotonic));
}

test "Trace shutdown flushes a partial batch and remains safe when disabled" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(t.io, "trace.csv", .{});
    var trace = try start(t.allocator, file);
    trace.emit("present", 123, 7, 0);
    trace.emit("draw_lock", 456, 0, 0);
    trace.deinit();
    trace.emit("draw", 0, 0, 0);
    trace.deinit();
    const data = try tmp.dir.readFileAlloc(t.io, "trace.csv", t.allocator, .unlimited);
    defer t.allocator.free(data);
    try t.expect(std.mem.indexOf(u8, data, ",123,7,0\n") != null);
    try t.expect(std.mem.indexOf(u8, data, ",456,0,0\n") != null);
    try t.expectEqual(@as(usize, 2), std.mem.count(u8, data, "\n"));
}

test "Trace concurrent producers account for every accepted or dropped record" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(t.io, "trace.csv", .{});
    var trace = try start(t.allocator, file);
    const Producer = struct {
        fn run(sink: *Self) void {
            for (0..1000) |n| sink.emit("draw", n, 0, 0);
        }
    };
    var threads: [4]std.Thread = undefined;
    var started: usize = 0;
    defer trace.deinit();
    {
        defer for (threads[0..started]) |thread| thread.join();
        for (&threads) |*thread| {
            thread.* = try std.Thread.spawn(.{}, Producer.run, .{&trace});
            started += 1;
        }
    }
    trace.deinit();
    const data = try tmp.dir.readFileAlloc(t.io, "trace.csv", t.allocator, .unlimited);
    defer t.allocator.free(data);
    var total: u64 = 0;
    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ',');
        const event = fields.next().?;
        _ = fields.next();
        total += if (std.mem.eql(u8, event, "trace_drop")) try std.fmt.parseInt(u64, fields.next().?, 10) else 1;
    }
    try t.expectEqual(@as(u64, 4000), total);
}

test "Trace config disabled creates nothing and enabled creates output directory" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(base);
    const directory = try std.fmt.allocPrint(t.allocator, "{s}/diagnostics", .{base});
    defer t.allocator.free(directory);
    var disabled = init(t.allocator, false, directory);
    defer disabled.deinit();
    try t.expect(disabled.file == null and disabled.worker == null and disabled.state == null);
    try t.expectError(error.FileNotFound, tmp.dir.openDir(t.io, "diagnostics", .{}));
    var enabled = init(t.allocator, true, directory);
    defer enabled.deinit();
    try t.expect(enabled.file != null and enabled.worker != null);
    enabled.emit("present", 1, 2, 0);
    enabled.deinit();
    var dir = try tmp.dir.openDir(t.io, "diagnostics", .{ .iterate = true });
    defer dir.close(t.io);
    var it = dir.iterate();
    const entry = (try it.next(t.io)).?;
    const data = try dir.readFileAlloc(t.io, entry.name, t.allocator, .unlimited);
    defer t.allocator.free(data);
    try t.expect(std.mem.startsWith(u8, data, "present,"));
    try t.expect(try it.next(t.io) == null);
}
