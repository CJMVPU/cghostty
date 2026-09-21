pub const Backend = enum {
    coretext,
    coretext_freetype,
    coretext_harfbuzz,
    coretext_noshape,
    pub fn hasFreetype(self: Backend) bool {
        return self == .coretext_freetype;
    }
    pub fn hasHarfbuzz(self: Backend) bool {
        return self == .coretext_freetype or self == .coretext_harfbuzz;
    }
};
