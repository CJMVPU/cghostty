const std = @import("std");

/// Application terminal options; there is no standalone terminal SDK.
pub const Options = struct {
    simd: bool,
    slow_runtime_safety: bool,
    version: std.SemanticVersion,

    /// Add the required build options for the terminal module.
    ///
    /// The memory referenced by self is expected to stick around (it isn't
    /// copied), since we expect we're in a build environment.
    pub fn add(
        self: Options,
        b: *std.Build,
        m: *std.Build.Module,
    ) void {
        const opts = b.addOptions();
        opts.addOption(bool, "simd", self.simd);
        opts.addOption(bool, "slow_runtime_safety", self.slow_runtime_safety);

        // Version information.
        opts.addOption(
            []const u8,
            "version_string",
            b.fmt(
                "{f}",
                .{self.version},
            ),
        );
        opts.addOption(usize, "version_major", self.version.major);
        opts.addOption(usize, "version_minor", self.version.minor);
        opts.addOption(usize, "version_patch", self.version.patch);
        opts.addOption(?[]const u8, "version_pre", self.version.pre);
        opts.addOption(?[]const u8, "version_build", self.version.build);

        m.addOptions("terminal_options", opts);
    }
};
