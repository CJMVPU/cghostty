//! Wraps a Darwin static archive with the libsystem_override.sh
//! post-processing step so that consumers linking the archive bind
//! well-known libc/libm symbols (memcpy, memmove, memset, cos, sin,
//! ...) to Apple's libSystem instead of the bundled Zig compiler-rt.
//! See src/build/libsystem_override.sh for the full rationale.
//!
//! Keep compiler-rt bundled for intrinsics and the UBSan runtime while
//! allowing the application to use Apple's optimized libc/libm routines.
const std = @import("std");

pub const Result = struct {
    step: *std.Build.Step,
    output: std.Build.LazyPath,
};

/// Post-process the internal archive using Apple's nmedit tool.
pub fn create(
    b: *std.Build,
    input: std.Build.LazyPath,
    out_name: []const u8,
) Result {
    const run = b.addSystemCommand(&.{"/bin/sh"});
    run.setName("libsystem override");
    run.addFileArg(b.path("src/build/libsystem_override.sh"));
    run.addFileArg(input);
    const output = run.addOutputFileArg(out_name);
    return .{ .step = &run.step, .output = output };
}
