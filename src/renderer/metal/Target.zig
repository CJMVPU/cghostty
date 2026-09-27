//! Represents a render target.
//!
//! Borrowed window drawable view, or an owned shared Metal texture for snapshots.
const Self = @This();

const objc = @import("objc");

const mtl = @import("api.zig");

/// Options for initializing a Target
pub const Options = struct {
    /// MTLDevice
    device: objc.Object,

    /// Desired width
    width: usize,
    /// Desired height
    height: usize,

    /// Pixel format for the MTLTexture
    pixel_format: mtl.MTLPixelFormat,
    /// Storage mode for the MTLTexture
    storage_mode: mtl.MTLResourceOptions.StorageMode,
};

/// Only explicit snapshot targets own their texture.
owned: bool = false,

/// The underlying MTLTexture.
texture: objc.Object,

/// Current width of this target.
width: usize,
/// Current height of this target.
height: usize,

pub fn init(opts: Options) !Self {
    // Create our descriptor
    const desc = init: {
        const Class = objc.getClass("MTLTextureDescriptor").?;
        const id_alloc = Class.msgSend(objc.Object, objc.sel("alloc"), .{});
        const id_init = id_alloc.msgSend(objc.Object, objc.sel("init"), .{});
        break :init id_init;
    };
    defer desc.release();

    // Set our properties
    desc.setProperty("width", @as(c_ulong, @intCast(opts.width)));
    desc.setProperty("height", @as(c_ulong, @intCast(opts.height)));
    desc.setProperty("pixelFormat", @intFromEnum(opts.pixel_format));
    desc.setProperty("usage", mtl.MTLTextureUsage{ .render_target = true });
    desc.setProperty(
        "resourceOptions",
        mtl.MTLResourceOptions{
            // Explicit snapshots are read back by the CPU.
            .cpu_cache_mode = .default,
            .storage_mode = opts.storage_mode,
        },
    );

    const id = opts.device.msgSend(?*anyopaque, "newTextureWithDescriptor:", .{desc}) orelse return error.MetalFailed;

    const texture = objc.Object.fromId(id);

    return .{
        .owned = true,
        .texture = texture,
        .width = opts.width,
        .height = opts.height,
    };
}

pub fn deinit(self: *Self) void {
    if (self.owned) self.texture.release();
}
