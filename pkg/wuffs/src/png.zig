const std = @import("std");
const common = @import("decode.zig");
const ImageData = @import("main.zig").ImageData;
const Error = @import("error.zig").Error;

pub fn decode(alloc: std.mem.Allocator, data: []const u8) Error!ImageData {
    return decodeLimited(alloc, data, @import("main.zig").maximum_image_size);
}

pub fn decodeLimited(alloc: std.mem.Allocator, data: []const u8, max_bytes: usize) Error!ImageData {
    return common.decode("png", alloc, data, max_bytes);
}

test "png_decode_000000" {
    const data = try decode(std.testing.allocator, @embedFile("1x1#000000.png"));
    defer std.testing.allocator.free(data.data);

    try std.testing.expectEqual(1, data.width);
    try std.testing.expectEqual(1, data.height);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255 }, data.data);
}

test "png_decode_FFFFFF" {
    const data = try decode(std.testing.allocator, @embedFile("1x1#FFFFFF.png"));
    defer std.testing.allocator.free(data.data);

    try std.testing.expectEqual(1, data.width);
    try std.testing.expectEqual(1, data.height);
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, data.data);
}

test "png: too big" {
    const data = decode(std.testing.allocator, @embedFile("too_big.png"));
    try std.testing.expectError(error.Overflow, data);
}

test "png respects caller pixel budget" {
    try std.testing.expectError(error.Overflow, decodeLimited(std.testing.allocator, @embedFile("1x1#000000.png"), 3));
}

fn decodeFixture(alloc: std.mem.Allocator) !void {
    const image = try decodeLimited(alloc, @embedFile("1x1#000000.png"), 4);
    defer alloc.free(image.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255 }, image.data);
}

test "png frees intermediate allocations on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, decodeFixture, .{});
}

test "png rejects truncated input" {
    const data = @embedFile("1x1#000000.png");
    try std.testing.expectError(error.WuffsError, decode(std.testing.allocator, data[0 .. data.len / 2]));
}
