//! Metal 4 submissions. Each swap-chain slot owns reusable encoding storage.
const Self = @This();
const std = @import("std");
const objc = @import("objc");
const global = @import("../../global.zig");
const Metal = @import("../Metal.zig");
const Renderer = @import("../Renderer.zig");
const Target = @import("Target.zig");
const RenderPass = @import("RenderPass.zig");
const Health = @import("../../renderer.zig").Health;
const Presentation = @import("../Presentation.zig");
const log = std.log.scoped(.metal);

pub fn object(class: [:0]const u8) objc.Object {
    return objc.getClass(class).?.msgSend(objc.Object, "new", .{});
}

pub const Commands = struct {
    buffer: objc.Object,
    allocator: objc.Object,
    arguments: objc.Object,
    residency: objc.Object,
    /// Metal 4 doesn't retain resources referenced by GPU addresses.
    retained: objc.Object,
    health: Health = .healthy,
    completed: std.Io.Semaphore = .{ .permits = 0 },

    pub fn init(device: objc.Object) !Commands {
        const buffer = device.msgSend(?*anyopaque, "newCommandBuffer", .{}) orelse return error.MetalFailed;
        errdefer objc.Object.fromId(buffer).release();
        const allocator = device.msgSend(?*anyopaque, "newCommandAllocator", .{}) orelse return error.MetalFailed;
        errdefer objc.Object.fromId(allocator).release();
        const desc = object("MTL4ArgumentTableDescriptor");
        defer desc.release();
        desc.setProperty("maxBufferBindCount", @as(c_ulong, 4));
        desc.setProperty("maxTextureBindCount", @as(c_ulong, 4));
        desc.setProperty("maxSamplerStateBindCount", @as(c_ulong, 4));
        const arguments = device.msgSend(?*anyopaque, "newArgumentTableWithDescriptor:error:", .{ desc, @as(?*anyopaque, null) }) orelse return error.MetalFailed;
        errdefer objc.Object.fromId(arguments).release();
        const residency_desc = object("MTLResidencySetDescriptor");
        defer residency_desc.release();
        const residency = device.msgSend(?*anyopaque, "newResidencySetWithDescriptor:error:", .{ residency_desc, @as(?*anyopaque, null) }) orelse return error.MetalFailed;
        return .{
            .buffer = objc.Object.fromId(buffer),
            .allocator = objc.Object.fromId(allocator),
            .arguments = objc.Object.fromId(arguments),
            .residency = objc.Object.fromId(residency),
            .retained = object("NSMutableSet"),
        };
    }

    pub fn deinit(self: *Commands) void {
        self.buffer.release();
        self.allocator.release();
        self.arguments.release();
        self.residency.release();
        self.retained.release();
    }

    pub fn retainResource(self: *const Commands, resource: objc.Object, allocation: bool) void {
        self.retained.msgSend(void, "addObject:", .{resource});
        if (allocation) self.residency.msgSend(void, "addAllocation:", .{resource});
    }
};

pub const Options = struct { queue: objc.Object, commands: *Commands };
queue: objc.Object,
commands: *Commands,
block: CompletionBlock.Context,

pub fn begin(opts: Options, renderer: *Renderer, target: *Target) !Self {
    const c = opts.commands;
    // The swap-chain semaphore guarantees this slot is no longer in flight.
    c.allocator.msgSend(void, "reset", .{});
    c.residency.msgSend(void, "removeAllAllocations", .{});
    c.retained.msgSend(void, "removeAllObjects", .{});
    c.buffer.msgSend(void, "beginCommandBufferWithAllocator:", .{c.allocator});
    return .{
        .queue = opts.queue,
        .commands = c,
        .block = CompletionBlock.init(.{ .renderer = renderer, .target = target, .commands = c, .sync = false }, &bufferCompleted),
    };
}

const CompletionBlock = objc.Block(struct {
    renderer: *Renderer,
    target: *Target,
    commands: *Commands,
    sync: bool,
}, .{objc.c.id}, void);

fn bufferCompleted(block: *const CompletionBlock.Context, feedback_id: objc.c.id) callconv(.c) void {
    const feedback = objc.Object.fromId(feedback_id);
    const err = feedback.getProperty(?*anyopaque, "error");
    const health: Health = if (err == null) .healthy else .unhealthy;
    if (block.renderer.trace.file != null) {
        const elapsed = feedback.getProperty(f64, "GPUEndTime") - feedback.getProperty(f64, "GPUStartTime");
        if (std.math.isFinite(elapsed) and elapsed > 0)
            block.renderer.trace.emit("gpu", @intFromFloat(elapsed * std.time.ns_per_s), @intFromBool(health == .healthy), 0);
    }
    if (block.sync) {
        block.commands.health = health;
        block.commands.completed.post(global.io());
        return;
    }
    if (health == .unhealthy) {
        const description = objc.Object.fromId(err.?).getProperty(objc.Object, "localizedDescription");
        const message = description.msgSend([*:0]const u8, "UTF8String", .{});
        log.err("Metal 4 submission failed: {s}", .{message});
    }
    block.renderer.frameCompleted(Presentation.finish(&block.renderer.api, block.target.*, false, health));
}

pub fn renderPass(self: *const Self, attachments: []const RenderPass.Options.Attachment) RenderPass {
    return RenderPass.begin(.{ .attachments = attachments, .commands = self.commands });
}

pub fn complete(self: *Self, sync: bool) void {
    self.block.sync = sync;
    const c = self.commands;
    c.residency.msgSend(void, "commit", .{});
    c.buffer.msgSend(void, "useResidencySet:", .{c.residency});
    c.buffer.msgSend(void, "endCommandBuffer", .{});
    const options = object("MTL4CommitOptions");
    defer options.release();
    options.msgSend(void, "addFeedbackHandler:", .{&self.block});
    const buffers = [_]objc.c.id{c.buffer.value};
    self.queue.msgSend(void, "commit:count:options:", .{ &buffers, @as(c_ulong, 1), options });
    if (sync) {
        c.completed.waitUncancelable(global.io());
        // Core Animation's synchronous display callback must present on its
        // caller, never on the Metal feedback queue while the caller waits.
        self.block.renderer.frameCompleted(Presentation.finish(&self.block.renderer.api, self.block.target.*, true, c.health));
    }
}
