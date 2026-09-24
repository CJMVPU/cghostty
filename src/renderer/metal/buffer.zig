const std = @import("std");
const objc = @import("objc");
const mtl = @import("api.zig");

pub const Options = struct {
    device: objc.Object,
    resource_options: mtl.MTLResourceOptions,
};

/// CPU-written, shared-memory buffers for the native Apple Silicon renderer.
pub fn Buffer(comptime T: type) type {
    return struct {
        const Self = @This();
        opts: Options,
        buffer: objc.Object,
        /// Capacity in elements, not bytes.
        len: usize,

        pub fn init(opts: Options, requested: usize) !Self {
            std.debug.assert(opts.resource_options.storage_mode == .shared);
            const len = @max(requested, 1);
            const bytes = try std.math.mul(usize, len, @sizeOf(T));
            const value = opts.device.msgSend(?*anyopaque, objc.sel("newBufferWithLength:options:"), .{
                @as(c_ulong, @intCast(bytes)), opts.resource_options,
            }) orelse return error.MetalFailed;
            return .{ .buffer = objc.Object.fromId(value), .opts = opts, .len = len };
        }

        pub fn initFill(opts: Options, data: []const T) !Self {
            var result = try init(opts, data.len);
            errdefer result.deinit();
            try result.sync(data);
            return result;
        }

        pub fn deinit(self: *const Self) void {
            self.buffer.release();
        }

        /// Publish a replacement only after allocation succeeds. Existing data
        /// and ownership remain valid if Metal cannot allocate the larger buffer.
        pub fn ensureCapacity(self: *Self, count: usize) !void {
            if (count <= self.len) return;
            const capacity = std.math.mul(usize, count, 2) catch count;
            const replacement = try init(self.opts, capacity);
            self.deinit();
            self.* = replacement;
        }

        pub fn writable(self: *Self, count: usize) ![]T {
            try self.ensureCapacity(count);
            const ptr = self.buffer.msgSend(?[*]T, objc.sel("contents"), .{}) orelse return error.MetalFailed;
            return ptr[0..count];
        }

        pub fn sync(self: *Self, data: []const T) !void {
            @memcpy(try self.writable(data.len), data);
        }

        pub fn syncFromArrayLists(self: *Self, lists: []const std.ArrayListUnmanaged(T)) !usize {
            var total: usize = 0;
            for (lists) |list| total = try std.math.add(usize, total, list.items.len);
            const dst = try self.writable(total);
            var offset: usize = 0;
            for (lists) |list| {
                @memcpy(dst[offset..][0..list.items.len], list.items);
                offset += list.items.len;
            }
            return total;
        }
    };
}
