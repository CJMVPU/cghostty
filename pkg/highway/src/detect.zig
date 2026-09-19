//! Runtime SIMD feature detection for Apple Silicon.
const HwyTargets = @import("targets.zig").Targets;
const darwin = @import("detect/aarch64_darwin.zig");
pub export fn ghostty_hwy_detect_targets() callconv(.c) i64 {
    var targets: HwyTargets = .{};
    targets.neon_without_aes = true;
    return darwin.detect(&targets);
}
