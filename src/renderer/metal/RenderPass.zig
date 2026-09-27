//! Wrapper for handling render passes.
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const objc = @import("objc");

const mtl = @import("api.zig");
const Pipeline = @import("Pipeline.zig");
const Sampler = @import("Sampler.zig");
const Texture = @import("Texture.zig");
const Target = @import("Target.zig");
const Frame = @import("Frame.zig");

const log = std.log.scoped(.metal);

/// Options for beginning a render pass.
pub const Options = struct {
    commands: *Frame.Commands,
    /// Color attachments for this render pass.
    attachments: []const Attachment,

    /// Describes a color attachment.
    pub const Attachment = struct {
        target: union(enum) {
            texture: Texture,
            target: Target,
        },
        clear_color: ?[4]f64 = null,
    };
};

/// Describes a step in a render pass.
pub const Step = struct {
    pipeline: Pipeline,
    /// MTLBuffer
    uniforms: ?objc.Object = null,
    /// MTLBuffer
    buffers: []const ?objc.Object = &.{},
    /// Byte offsets, defaulting to zero for omitted entries.
    buffer_offsets: []const usize = &.{},
    textures: []const ?Texture = &.{},
    /// Set of samplers to use for this step. The index maps to an index
    /// of a fragment texture in the Metal 4 argument table.
    samplers: []const ?Sampler = &.{},
    scissor: ?@import("../CursorOverlay.zig").Scissor = null,
    draw: Draw,

    /// Describes the draw call for this step.
    pub const Draw = struct {
        type: mtl.MTLPrimitiveType,
        vertex_count: usize,
        instance_count: usize = 1,
    };
};

/// MTL4RenderCommandEncoder
encoder: objc.Object,
commands: *Frame.Commands,
full_scissor: @import("../CursorOverlay.zig").Scissor,

/// Begin a render pass.
pub fn begin(
    opts: Options,
) Self {
    // Create a pass descriptor
    const desc = desc: {
        const desc = Frame.object("MTL4RenderPassDescriptor");

        // Set our color attachment to be our drawable surface.
        const attachments = objc.Object.fromId(
            desc.getProperty(?*anyopaque, "colorAttachments"),
        );
        for (opts.attachments, 0..) |at, i| {
            const attachment = attachments.msgSend(
                objc.Object,
                objc.sel("objectAtIndexedSubscript:"),
                .{@as(c_ulong, i)},
            );

            attachment.setProperty(
                "loadAction",
                @intFromEnum(@as(
                    mtl.MTLLoadAction,
                    if (at.clear_color != null)
                        .clear
                    else
                        .load,
                )),
            );
            attachment.setProperty(
                "storeAction",
                @intFromEnum(mtl.MTLStoreAction.store),
            );
            const texture = switch (at.target) {
                .texture => |t| t.texture,
                .target => |t| t.texture,
            };
            opts.commands.retainResource(texture, true);
            attachment.setProperty("texture", texture.value);
            if (at.clear_color) |c| attachment.setProperty(
                "clearColor",
                mtl.MTLClearColor{
                    .red = c[0],
                    .green = c[1],
                    .blue = c[2],
                    .alpha = c[3],
                },
            );
        }

        break :desc desc;
    };

    defer desc.release();
    const encoder = opts.commands.buffer.msgSend(
        objc.Object,
        objc.sel("renderCommandEncoderWithDescriptor:"),
        .{desc.value},
    );

    // Make earlier queue writes visible before this render pass consumes them.
    encoder.msgSend(void, "barrierAfterQueueStages:beforeStages:visibilityOptions:", .{ @as(c_ulong, 0x7fffffffffffffff), @as(c_ulong, 3), @as(c_ulong, 1) });
    const dimensions = switch (opts.attachments[0].target) {
        inline else => |t| .{ t.width, t.height },
    };
    return .{ .encoder = encoder, .commands = opts.commands, .full_scissor = .{ .x = 0, .y = 0, .width = dimensions[0], .height = dimensions[1] } };
}

/// Add a step to this render pass.
pub fn step(self: *const Self, s: Step) void {
    if (s.draw.instance_count == 0) return;

    if (s.scissor) |rect| self.encoder.msgSend(void, "setScissorRect:", .{rect});
    defer if (s.scissor != null) self.encoder.msgSend(void, "setScissorRect:", .{self.full_scissor});

    // Set pipeline state
    self.encoder.msgSend(
        void,
        objc.sel("setRenderPipelineState:"),
        .{s.pipeline.state.value},
    );

    const table = self.commands.arguments;
    self.commands.retainResource(s.pipeline.state, false);
    for (s.buffers, 0..) |buffer, i| if (buffer) |buf| {
        self.bindBuffer(buf, if (i == 0) 0 else i + 1, if (i < s.buffer_offsets.len) s.buffer_offsets[i] else 0);
    };
    if (s.uniforms) |buf| self.bindBuffer(buf, 1, 0);
    for (s.textures, 0..) |texture, i| if (texture) |tex| {
        self.commands.retainResource(tex.texture, true);
        const resource = tex.texture.getProperty(ResourceID, "gpuResourceID");
        table.msgSend(void, "setTexture:atIndex:", .{ resource, @as(c_ulong, i) });
    };
    for (s.samplers, 0..) |sampler, i| if (sampler) |samp| {
        self.commands.retainResource(samp.sampler, false);
        const resource = samp.sampler.getProperty(ResourceID, "gpuResourceID");
        table.msgSend(void, "setSamplerState:atIndex:", .{ resource, @as(c_ulong, i) });
    };
    self.encoder.msgSend(void, "setArgumentTable:atStages:", .{ table, @as(c_ulong, 3) });

    // Draw!
    self.encoder.msgSend(
        void,
        objc.sel("drawPrimitives:vertexStart:vertexCount:instanceCount:"),
        .{
            @intFromEnum(s.draw.type),
            @as(c_ulong, 0),
            @as(c_ulong, s.draw.vertex_count),
            @as(c_ulong, s.draw.instance_count),
        },
    );
}

/// Complete this render pass.
/// This struct can no longer be used after calling this.
pub fn complete(self: *const Self) void {
    self.encoder.msgSend(void, objc.sel("endEncoding"), .{});
}

const ResourceID = extern struct { value: u64 };
fn bindBuffer(self: *const Self, buffer: objc.Object, index: usize, offset: usize) void {
    self.commands.retainResource(buffer, true);
    const address = buffer.getProperty(u64, "gpuAddress") + offset;
    self.commands.arguments.msgSend(void, "setAddress:atIndex:", .{ address, @as(c_ulong, index) });
}
