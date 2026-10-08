//! Configured input owns its source descriptors and one reusable file chunk.
//! Advance only after a complete PTY write, so a stalled child cannot cause
//! file read-ahead. Ordinary input retains its existing ownership semantics.
const InitialInput = @This();
const std = @import("std");
const global = @import("../global.zig");
const xev = global.xev;
const configpkg = @import("../config.zig");
const termio = @import("../termio.zig");
const log = std.log.scoped(.initial_input);

pub const chunk_size = 64 * 1024;
pub const file_limit = 10 * 1024 * 1024;

arena: std.heap.ArenaAllocator,
input: configpkg.io.RepeatableReadableIO,
inputs: []const Input = &.{},
index: usize = 0,
file_bytes: usize = 0,
buffer: ?[]u8 = null,
read_c: xev.Completion = .{},
state: enum { ready, reading, writing, failed } = .ready,
io: *termio.Termio = undefined,
td: *termio.Termio.ThreadData = undefined,

pub const Input = union(enum) {
    string: []const u8,
    file: std.Io.File,
};

pub fn create(alloc: std.mem.Allocator, config: *const configpkg.Config) !?*InitialInput {
    if (config.input.list.items.len == 0) return null;
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const a = arena.allocator();
    const ptr = try a.create(InitialInput);
    const input = try config.input.cloneParsed(a);
    ptr.* = .{ .arena = arena, .input = input };
    return ptr;
}

pub fn destroy(self: *InitialInput) void {
    for (self.inputs) |input| switch (input) {
        .file => |file| file.close(global.io()),
        .string => {},
    };
    // The object itself lives in this arena. Do not access it afterwards.
    var arena = self.arena;
    arena.deinit();
}

/// Open and validate every source before starting the subprocess. Regular
/// files over the existing limit fail before any of their bytes are sent.
pub fn prepare(self: *InitialInput) !void {
    var inputs: std.ArrayList(Input) = try .initCapacity(
        self.arena.allocator(),
        self.input.list.items.len,
    );
    errdefer for (inputs.items) |input| switch (input) {
        .file => |file| file.close(global.io()),
        .string => {},
    };
    for (self.input.list.items) |item| {
        inputs.appendAssumeCapacity(switch (item) {
            .raw => |data| .{ .string = data },
            .path => |path| file: {
                const f = std.Io.Dir.cwd().openFile(global.io(), path, .{}) catch |err| {
                    log.warn("failed to open input file={s} err={}", .{ path, err });
                    return error.InputNotFound;
                };
                errdefer f.close(global.io());
                const stat = try f.stat(global.io());
                if (stat.kind == .file and stat.size > file_limit) return error.InputFailed;
                const flags = std.posix.system.fcntl(f.handle, std.posix.F.GETFL);
                if (flags == -1 or std.posix.system.fcntl(
                    f.handle,
                    std.posix.F.SETFL,
                    flags | @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true })),
                ) == -1) return error.InputFailed;
                break :file .{ .file = f };
            },
        });
    }
    self.inputs = inputs.items;
}

/// Called from the writer mailbox callback, never from a write completion.
/// In particular, cleanup cannot free an embedded completion while libxev
/// is still returning from its callback.
pub fn drive(self: *InitialInput) !void {
    if (self.state != .ready or self.io.fault.failed()) return;
    if (self.td.backend.exited) {
        self.state = .failed;
        return; // Thread teardown owns any still-registered completion.
    }
    while (self.index < self.inputs.len) {
        switch (self.inputs[self.index]) {
            .string => |data| {
                self.index += 1;
                if (data.len == 0) continue;
                try termio.Exec.queueInitialChunk(self.td, data);
                self.state = .writing;
            },
            .file => |file| {
                const buffer = self.buffer orelse buffer: {
                    const result = try self.arena.allocator().alloc(u8, chunk_size);
                    self.buffer = result;
                    break :buffer result;
                };
                self.state = .reading;
                // One extra byte detects growing/streaming sources exceeding
                // the limit. No excess bytes are written or silently clipped.
                const len = @min(buffer.len, file_limit - self.file_bytes + 1);
                // A regular file at EOF need not produce a kqueue read
                // event. Attempt the bounded nonblocking read first; only
                // sources without available bytes need a readiness wait.
                const result = std.posix.system.read(file.handle, buffer.ptr, len);
                switch (std.posix.errno(result)) {
                    .SUCCESS => {
                        self.readFinished(@intCast(result));
                        return;
                    },
                    .AGAIN => {},
                    .INTR => {
                        self.state = .ready;
                        self.io.mailbox.notify();
                        return;
                    },
                    else => |errno| {
                        log.warn("source read failed errno={}", .{errno});
                        self.fail(error.InputFailed);
                        return;
                    },
                }
                xev.Stream.initFd(file.handle).read(
                    self.td.loop,
                    &self.read_c,
                    .{ .slice = buffer[0..len] },
                    InitialInput,
                    self,
                    readCallback,
                );
            },
        }
        return;
    }
    if (!termio.Exec.flushDeferredWrites(self.td)) {
        self.io.mailbox.notify();
        return;
    }
    self.td.backend.initial_input = null;
    self.destroy();
}

pub fn writeCompleted(self: *InitialInput, result: xev.WriteError!usize) void {
    _ = result catch |err| {
        self.fail(err);
        return;
    };
    self.state = .ready;
    self.io.mailbox.notify();
}

fn fail(self: *InitialInput, err: anyerror) void {
    self.state = .failed;
    log.warn("configured input failed err={}", .{err});
    self.io.reportFault(error.InputFailed);
}

fn readCallback(
    self_: ?*InitialInput,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.Stream,
    _: xev.ReadBuffer,
    result: xev.ReadError!usize,
) xev.CallbackAction {
    const self = self_.?;
    const n = result catch |err| switch (err) {
        error.EOF => 0,
        else => {
            self.fail(err);
            return .disarm;
        },
    };
    self.readFinished(n);
    return .disarm;
}

fn readFinished(self: *InitialInput, n: usize) void {
    if (self.io.fault.failed() or self.td.backend.exited) {
        self.state = .failed;
        return;
    }
    if (n == 0) {
        self.index += 1;
        self.file_bytes = 0;
        self.state = .ready;
        self.io.mailbox.notify();
    } else {
        if (n > file_limit - self.file_bytes) {
            self.fail(error.FileTooBig);
            return;
        }
        self.file_bytes += n;
        termio.Exec.queueInitialChunk(self.td, self.buffer.?[0..n]) catch |err| {
            self.fail(err);
            return;
        };
        self.state = .writing;
    }
}

test "PTY source preparation preserves limit and closes failed inputs" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(t.io, "source", .{});
    defer file.close(t.io);
    const path = try tmp.dir.realPathFileAlloc(t.io, "source", t.allocator);
    defer t.allocator.free(path);
    const path_z = try t.allocator.dupeZ(u8, path);
    defer t.allocator.free(path_z);
    var entries = [_]configpkg.io.ReadableIO{ .{ .raw = "prefix" }, .{ .path = path_z } };
    var config: configpkg.Config = undefined;
    config.input = .{ .list = .{ .items = &entries, .capacity = entries.len } };
    try file.setLength(t.io, file_limit);
    const input = (try create(t.allocator, &config)).?;
    var destroyed = false;
    defer if (!destroyed) input.destroy();
    try input.prepare();
    try t.expectEqualStrings("prefix", input.inputs[0].string);
    const fd = input.inputs[1].file.handle;
    input.destroy();
    destroyed = true;
    try t.expectEqual(@as(c_int, -1), std.posix.system.fcntl(fd, std.posix.F.GETFL));
    try file.setLength(t.io, file_limit + 1);
    const too_big = (try create(t.allocator, &config)).?;
    defer too_big.destroy();
    try t.expectError(error.InputFailed, too_big.prepare());
    try t.expectEqual(@as(usize, 0), too_big.inputs.len);
}

test "PTY source preparation frees cloned config on allocation failures" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "source", .data = "data" });
    const path = try tmp.dir.realPathFileAlloc(t.io, "source", t.allocator);
    defer t.allocator.free(path);
    const path_z = try t.allocator.dupeZ(u8, path);
    defer t.allocator.free(path_z);
    var entries = [_]configpkg.io.ReadableIO{ .{ .raw = "first" }, .{ .path = path_z } };
    var config: configpkg.Config = undefined;
    config.input = .{ .list = .{ .items = &entries, .capacity = entries.len } };
    try t.checkAllAllocationFailures(t.allocator, struct {
        fn run(alloc: std.mem.Allocator, cfg: *const configpkg.Config) !void {
            const input = (try create(alloc, cfg)).?;
            defer input.destroy();
            try input.prepare();
        }
    }.run, .{&config});
}
