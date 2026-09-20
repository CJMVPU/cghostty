//! Provides libintl for macOS.
//!
//! IMPORTANT: This is only for macOS. We could support other platforms
//! if/when we need to but generally Linux provides libintl in libc.
//! Windows we'll have to figure out when we get there.
//!
//! Since this is only for macOS, there's a lot of hardcoded stuff
//! here that assumes macOS. For example, I generated the config.h
//! on my own machine (a Mac) and then copied it here. This isn't
//! ideal since we should do the same detection that gettext's configure
//! script does, but its quite a bit of work to do that.
//!
//! UPGRADING: See README.md for regenerating the configuration and gnulib
//! headers. Preserve the xlocale.h include added at the end of config.h,
//! and verify both Debug and Release links against the generated headers.

const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    var flags: std.ArrayList([]const u8) = .empty;
    defer flags.deinit(b.allocator);
    try flags.appendSlice(b.allocator, &.{
        "-DHAVE_CONFIG_H",
        "-DLOCALEDIR=\"\"",
    });

    {
        const lib = b.addLibrary(.{
            .name = "intl",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
            .linkage = .static,
        });
        lib.root_module.addIncludePath(b.path(""));
        lib.root_module.addIncludePath(b.path("gnulib"));

        if (target.result.os.tag.isDarwin()) {
            const apple_sdk = @import("apple_sdk");
            try apple_sdk.addPaths(b, lib);
        }

        if (b.lazyDependency("gettext", .{})) |upstream| {
            lib.root_module.addIncludePath(upstream.path("gettext-runtime/intl"));
            lib.root_module.addIncludePath(upstream.path("gettext-runtime/intl/gnulib-lib"));
            lib.root_module.addCSourceFiles(.{
                .root = upstream.path("gettext-runtime/intl"),
                .files = srcs,
                .flags = flags.items,
            });
        }

        lib.installHeader(b.path("libintl.h"), "libintl.h");
        b.installArtifact(lib);
    }
}

const srcs: []const []const u8 = &.{
    "bindtextdom.c",
    "dcgettext.c",
    "dcigettext.c",
    "dcngettext.c",
    "dgettext.c",
    "dngettext.c",
    "explodename.c",
    "finddomain.c",
    "gettext.c",
    "hash-string.c",
    "intl-compat.c",
    "l10nflist.c",
    "langprefs.c",
    "loadmsgcat.c",
    "localealias.c",
    "log.c",
    "ngettext.c",
    "plural-exp.c",
    "plural.c",
    "setlocale.c",
    "textdomain.c",
    "version.c",
    "compat.c",

    // There's probably a better way to detect that we need these, but
    // these are hardcoded for now for macOS.
    "gnulib-lib/getlocalename_l-unsafe.c",
    "gnulib-lib/localename.c",
    "gnulib-lib/localename-environ.c",
    "gnulib-lib/localename-unsafe.c",
    "gnulib-lib/setlocale-lock.c",
    "gnulib-lib/setlocale_null.c",
    "gnulib-lib/setlocale_null-unlocked.c",
    // Out-of-line definitions for gnulib string.h helpers, including streq.
    "gnulib-lib/string.c",

    // Not needed for macOS, but we might need them for other platforms.
    // If we expand this to support other platforms, we should uncomment
    // these.
    // "osdep.c",
    // "printf.c",
};
