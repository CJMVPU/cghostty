//! A deferred face represents a single font face with all the information
//! necessary to load it, but defers loading the full face until it is
//! needed.
//!
//! This allows us to have many fallback fonts to look for glyphs, but
//! only load them if they're really needed.
const DeferredFace = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const macos = @import("macos");
const font = @import("main.zig");
const Face = @import("main.zig").Face;
const Presentation = @import("main.zig").Presentation;

const log = std.log.scoped(.deferred_face);

/// CoreText
ct: ?CoreText = null,

/// CoreText discovery data, shared by all supported font backends.
pub const CoreText = struct {
    /// The initialized font
    font: *macos.text.Font,

    /// Variations to apply to this font. We apply the variations to the
    /// search descriptor but sometimes when the font collection is
    /// made the variation axes are reset so we have to reapply them.
    variations: []const font.face.Variation,

    pub fn deinit(self: *CoreText) void {
        self.font.release();
        self.* = undefined;
    }
};

pub fn deinit(self: *DeferredFace) void {
    if (self.ct) |*ct| ct.deinit();
    self.* = undefined;
}

/// Returns the family name in the caller's buffer.
pub fn familyName(self: DeferredFace, buf: []u8) ![]const u8 {
    if (self.ct) |ct| {
        const family_name = ct.font.copyAttribute(.family_name) orelse
            return "unknown";
        defer family_name.release();
        return family_name.cstring(buf, .utf8) orelse error.OutOfMemory;
    }

    return "";
}

/// Returns the name of this face in the caller's buffer.
pub fn name(self: DeferredFace, buf: []u8) ![]const u8 {
    if (self.ct) |ct| {
        const display_name = ct.font.copyDisplayName() orelse
            return self.familyName(buf);
        defer display_name.release();
        return display_name.cstring(buf, .utf8) orelse error.OutOfMemory;
    }

    return "";
}

/// Load the deferred font face. This does nothing if the face is loaded.
pub fn load(
    self: *DeferredFace,
    opts: font.face.Options,
) !Face {
    const ct = self.ct.?;
    var face = try Face.initFontCopy(ct.font, opts);
    errdefer face.deinit();
    try face.setVariations(ct.variations, opts);
    return face;
}

/// Returns true if this face can satisfy the given codepoint and
/// presentation. If presentation is null, then it just checks if the
/// codepoint is present at all.
///
/// This should not require the face to be loaded IF we're using a
/// discovery mechanism (i.e. fontconfig). If no discovery is used,
/// the face is always expected to be loaded.
pub fn hasCodepoint(self: DeferredFace, cp: u32, p: ?Presentation) bool {
    {
        // If we are using coretext, we check the loaded CT font.
        if (self.ct) |ct| {
            // This presentation check isn't as detailed as isColorGlyph
            // because forced presentation modes are only used for emoji and
            // emoji should always have color glyphs set. This can be
            // more correct by using the isColorGlyph logic but I'd want
            // to find a font that actually requires this so we can write
            // a test for it before changing it.
            if (p) |desired_p| {
                const traits = ct.font.getSymbolicTraits();
                const actual_p: Presentation = if (traits.color_glyphs) .emoji else .text;
                if (actual_p != desired_p) return false;
            }

            // Turn UTF-32 into UTF-16 for CT API
            var unichars: [2]u16 = undefined;
            const pair = macos.foundation.stringGetSurrogatePairForLongCharacter(cp, &unichars);
            const len: usize = if (pair) 2 else 1;

            // Get our glyphs
            var glyphs = [2]macos.graphics.Glyph{ 0, 0 };
            return ct.font.getGlyphsForCharacters(unichars[0..len], glyphs[0..len]);
        }
    }

    // This is unreachable because discovery mechanisms terminate, and
    // if we're not using a discovery mechanism, the face MUST be loaded.
    unreachable;
}

test "coretext" {
    const discovery = @import("main.zig").discovery;
    const testing = std.testing;
    const alloc = testing.allocator;

    // Initialize CoreText

    // Discover a deferred CoreText face
    var def = def: {
        var fc = discovery.CoreText.init();
        var it = try fc.discover(alloc, .{ .family = "Monaco", .size = 12 });
        defer it.deinit();
        break :def (try it.next()).?;
    };
    defer def.deinit();
    try testing.expect(def.hasCodepoint(' ', null));

    // Verify we can get the name
    var buf: [1024]u8 = undefined;
    const n = try def.name(&buf);
    try testing.expect(n.len > 0);

    // Load it and verify it works
    var face = try def.load(.{ .size = .{ .points = 12 } });
    defer face.deinit();
    try testing.expect(face.glyphIndex(' ') != null);
}
