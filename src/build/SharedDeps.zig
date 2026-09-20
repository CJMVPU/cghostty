const SharedDeps = @This();

const std = @import("std");

const Config = @import("Config.zig");
const HelpStrings = @import("HelpStrings.zig");
const MetallibStep = @import("MetallibStep.zig");
const UnicodeTables = @import("UnicodeTables.zig");
const translate_c = @import("translate_c");

const dynamic_link_opts: std.Build.Module.LinkSystemLibraryOptions = .{
    .preferred_link_mode = .dynamic,
    .search_strategy = .mode_first,
};

config: *const Config,

options: *std.Build.Step.Options,
help_strings: HelpStrings,
metallib: *MetallibStep,
unicode_tables: UnicodeTables,
uucode_tables: std.Build.LazyPath,

/// Singleton uucode module, instantiated once in `init` and reused
/// everywhere so that ghostty and vaxis share the same compiled tables in
/// each final binary instead of each linking its own copy.
///
/// Sharing one instance is also a hard requirement (not just an
/// optimization) for Zig 0.16's strict module model. `SharedDeps.add` runs
/// for the macOS arm64 artifacts in Debug and ReleaseFast modes. On each
/// call we have to wire uucode into both the step's root module and into
/// vaxis_mod (because vaxis's `Parser.zig` does `@import("uucode")` and
/// we pass `external_uucode = true` to vaxis's build.zig so vaxis doesn't
/// instantiate its own uucode dep). If those two import bindings ever
/// resolve to *different* `*Module` pointers within a single Compile
/// step's analysis, Zig fails with:
///
///     vaxis/src/Parser.zig: file exists in modules 'uucode' and 'uucode0'
///
/// because all those uucode module instances share the same physical
/// `uucode/src/root.zig` file on disk, and Zig requires every file to belong
/// to exactly one module within a Compile graph.
///
/// The natural way to keep them the same would be to call
/// `b.lazyDependency("uucode", .{ .tables_path, .build_config_path })`
/// from each call site and let Zig's dependency cache deduplicate
/// identical args. That fails because of a bug in Zig's
/// `userLazyPathsAreTheSame` (Build.zig) where the `.src_path` and
/// `.generated` equality checks are inverted: `if (std.mem.eql(...))
/// return false` instead of `if (!std.mem.eql(...)) return false`. The
/// dep cache key therefore always misses whenever any arg is a
/// `b.path(...)` LazyPath, so each call returns a fresh `*Dependency`
/// with a fresh `*Module`. Hoisting the dep into one eager
/// `b.dependency` call here sidesteps the cache entirely.
///
/// This conflict is independent of whether vaxis itself is acquired as a
/// singleton or per-target dep.
uucode_mod: *std.Build.Module,

/// Used to keep track of a list of file sources.
pub const LazyPathList = std.ArrayList(std.Build.LazyPath);

pub fn init(b: *std.Build, cfg: *const Config) !SharedDeps {
    const uucode_tables = blk: {
        const uucode = b.dependency("uucode", .{
            .build_config_path = b.path("src/build/uucode_config.zig"),
        });

        break :blk uucode.namedLazyPath("tables.zig");
    };

    // Instantiate the singleton uucode module that both ghostty and vaxis
    // import. See the doc comment on `uucode_mod`.
    const uucode_mod = b.dependency("uucode", .{
        .tables_path = uucode_tables,
        .build_config_path = b.path("src/build/uucode_config.zig"),
    }).module("uucode");

    var result: SharedDeps = .{
        .config = cfg,
        .help_strings = try .init(b, cfg),
        .unicode_tables = try .init(b, uucode_tables),
        .uucode_tables = uucode_tables,
        .uucode_mod = uucode_mod,

        // Setup by initTarget
        .options = undefined,
        .metallib = undefined,
    };
    try result.initTarget(b, cfg.target);
    if (cfg.emit_unicode_table_gen) result.unicode_tables.install(b);
    return result;
}

/// Change the exe entrypoint.
pub fn changeEntrypoint(
    self: *const SharedDeps,
    b: *std.Build,
    entrypoint: Config.ExeEntrypoint,
) !SharedDeps {
    // Change our config
    const config = try b.allocator.create(Config);
    config.* = self.config.*;
    config.exe_entrypoint = entrypoint;

    var result = self.*;
    result.config = config;
    result.options = b.addOptions();
    try config.addOptions(result.options);

    return result;
}

fn initTarget(
    self: *SharedDeps,
    b: *std.Build,
    target: std.Build.ResolvedTarget,
) !void {
    // Update our metallib
    self.metallib = .create(b, .{
        .name = "Ghostty",
        .target = target,
        .sources = &.{b.path("src/renderer/shaders/shaders.metal")},
    });

    // Change our config
    const config = try b.allocator.create(Config);
    config.* = self.config.*;
    config.target = target;
    self.config = config;

    // Setup our shared build options
    self.options = b.addOptions();
    try self.config.addOptions(self.options);
}

pub fn add(
    self: *const SharedDeps,
    step: *std.Build.Step.Compile,
) !LazyPathList {
    const b = step.step.owner;

    // We could use our config.target/optimize fields here but its more
    // correct to always match our step.
    const target = step.root_module.resolved_target.?;
    const optimize = step.root_module.optimize.?;

    // We maintain a list of our static libraries and return it so that
    // we can build a single fat static library for the final app.
    var static_libs: LazyPathList = .empty;
    errdefer static_libs.deinit(b.allocator);

    // Every exe gets build options populated
    step.root_module.addOptions("build_options", self.options);

    // Every exe needs the terminal options
    self.config.terminalOptions(.ghostty, optimize).add(b, step.root_module);

    // Every exe needs the uucode module
    step.root_module.addImport("uucode", self.uucode_mod);

    // C imports for locale constants and functions
    try translate_c.addImportToModule(b, "locale-c", step.root_module, .{
        .source = .{ .file = b.path("src/os/locale.c") },
        .target = target,
        .optimize = optimize,
    });

    // C imports needed to manage/create PTYs
    try translate_c.addImportToModule(b, "pty-c", step.root_module, .{
        .source = .{ .file = b.path("src/pty.c") },
        .target = target,
        .optimize = optimize,
    });

    // POSIX C imports that are used throughout Ghostty on a general basis.
    // (note: errno is C stdlib but we just include it here because that's
    // where it's generally included otherwise)
    try translate_c.addImportToModule(b, "posix_c", step.root_module, .{
        .source = .{ .includes = .{ .files = &.{
            .{ .path = "errno.h" },
            .{ .path = "pwd.h" },
            .{ .path = "signal.h" },
            .{ .path = "sys/types.h" },
            .{ .path = "unistd.h" },
        } } },
        .target = target,
        .optimize = optimize,
    });

    // Freetype. We always include this even if our font backend doesn't
    // use it because Dear Imgui uses Freetype.
    _ = b.systemIntegrationOption("freetype", .{}); // Shows it in help
    if (b.lazyDependency("freetype", .{
        .target = target,
        .optimize = optimize,
        .@"enable-libpng" = true,
    })) |freetype_dep| {
        step.root_module.addImport(
            "freetype",
            freetype_dep.module("freetype"),
        );

        if (b.systemIntegrationOption("freetype", .{})) {
            step.root_module.linkSystemLibrary("bzip2", dynamic_link_opts);
            step.root_module.linkSystemLibrary("freetype2", dynamic_link_opts);
        } else {
            step.root_module.linkLibrary(freetype_dep.artifact("freetype"));
            try static_libs.append(
                b.allocator,
                freetype_dep.artifact("freetype").getEmittedBin(),
            );
        }
    }

    // Harfbuzz
    _ = b.systemIntegrationOption("harfbuzz", .{}); // Shows it in help
    if (self.config.font_backend.hasHarfbuzz()) {
        if (b.lazyDependency("harfbuzz", .{
            .target = target,
            .optimize = optimize,
            .@"enable-freetype" = self.config.font_backend.hasFreetype(),
            .@"enable-coretext" = self.config.font_backend.hasCoretext(),
        })) |harfbuzz_dep| {
            step.root_module.addImport(
                "harfbuzz",
                harfbuzz_dep.module("harfbuzz"),
            );
            if (b.systemIntegrationOption("harfbuzz", .{})) {
                step.root_module.linkSystemLibrary("harfbuzz", dynamic_link_opts);
            } else {
                step.root_module.linkLibrary(harfbuzz_dep.artifact("harfbuzz"));
                try static_libs.append(
                    b.allocator,
                    harfbuzz_dep.artifact("harfbuzz").getEmittedBin(),
                );
            }
        }
    }

    // Fontconfig
    // Libpng - Ghostty doesn't actually use this directly, its only used
    // through dependencies, so we only need to add it to our static
    // libs list if we're not using system integration. The dependencies
    // will handle linking it.
    if (!b.systemIntegrationOption("libpng", .{})) {
        if (b.lazyDependency("libpng", .{
            .target = target,
            .optimize = optimize,
        })) |libpng_dep| {
            step.root_module.linkLibrary(libpng_dep.artifact("png"));
            try static_libs.append(
                b.allocator,
                libpng_dep.artifact("png").getEmittedBin(),
            );
        }
    }

    // Zlib - same as libpng, only used through dependencies.
    if (!b.systemIntegrationOption("zlib", .{})) {
        if (b.lazyDependency("zlib", .{
            .target = target,
            .optimize = optimize,
        })) |zlib_dep| {
            step.root_module.linkLibrary(zlib_dep.artifact("z"));
            try static_libs.append(
                b.allocator,
                zlib_dep.artifact("z").getEmittedBin(),
            );
        }
    }

    // PCRE2: the pinned UTF-8 static library, shared by link consumers.
    if (b.lazyDependency("pcre2", .{
        .target = target,
        .optimize = optimize,
    })) |pcre2_dep| {
        step.root_module.addImport("pcre2", pcre2_dep.module("pcre2"));
        step.root_module.linkLibrary(pcre2_dep.artifact("pcre2-8"));
        try static_libs.append(b.allocator, pcre2_dep.artifact("pcre2-8").getEmittedBin());
    }

    // Simd
    if (self.config.simd) try addSimd(
        b,
        step.root_module,
        &static_libs,
    );

    // nothings/stb headers
    try translate_c.addImportToModule(b, "stb_c", step.root_module, .{
        .source = .{ .includes = .{ .files = &.{
            .{ .path = "stb_image.h" },
            .{ .path = "stb_image_resize.h" },
        } } },
        .target = target,
        .optimize = optimize,
        .include_paths = &.{b.path("src/stb")},
    });

    // C files
    step.root_module.link_libc = true;
    step.root_module.addIncludePath(b.path("src/stb"));
    step.root_module.addCSourceFiles(.{
        .files = &.{"src/stb/stb.c"},
        .flags = &.{},
    });

    // libc++ is required for the app's C++ dependencies.
    step.root_module.link_libcpp = true;

    // System SDK headers and the Metal library are required by every artifact.
    try @import("apple_sdk").addPaths(b, step);
    self.metallib.output.addStepDependencies(&step.step);
    step.root_module.addAnonymousImport("ghostty_metallib", .{
        .root_source_file = self.metallib.output,
    });

    // Other dependencies, mostly pure Zig
    if (b.lazyDependency("vaxis", .{
        .target = target,
        .optimize = optimize,
        .external_uucode = true,
    })) |dep| {
        const vaxis = dep.module("vaxis");
        step.root_module.addImport("vaxis", vaxis);
        vaxis.addImport("uucode", self.uucode_mod);
    }
    if (b.lazyDependency("wuffs", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        step.root_module.addImport("wuffs", dep.module("wuffs"));
    }
    if (b.lazyDependency("libxev", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        step.root_module.addImport("xev", dep.module("xev"));
    }
    if (b.lazyDependency("z2d", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        step.root_module.addImport("z2d", dep.module("z2d"));
    }
    if (b.lazyDependency("zf", .{
        .target = target,
        .optimize = optimize,
        .with_tui = false,
    })) |dep| {
        step.root_module.addImport("zf", dep.module("zf"));
    }

    // Native macOS dependencies.
    if (b.lazyDependency("zig_objc", .{
        .target = target,
        .optimize = optimize,
    })) |objc_dep| {
        step.root_module.addImport(
            "objc",
            objc_dep.module("objc"),
        );
    }

    if (b.lazyDependency("macos", .{
        .target = target,
        .optimize = optimize,
    })) |macos_dep| {
        step.root_module.addImport(
            "macos",
            macos_dep.module("macos"),
        );
        step.root_module.linkLibrary(
            macos_dep.artifact("macos"),
        );
        try static_libs.append(
            b.allocator,
            macos_dep.artifact("macos").getEmittedBin(),
        );
    }

    // Apple platforms do not include libc libintl so we bundle it.
    // This is LGPL but since our source code is open source we are
    // in compliance with the LGPL since end users can modify this
    // build script to replace the bundled libintl with their own.
    if (b.lazyDependency("libintl", .{
        .target = target,
        .optimize = optimize,
    })) |libintl_dep| {
        step.root_module.linkLibrary(libintl_dep.artifact("intl"));
        try static_libs.append(
            b.allocator,
            libintl_dep.artifact("intl").getEmittedBin(),
        );
    }

    // cimgui
    if (b.lazyDependency("dcimgui", .{
        .target = target,
        .optimize = optimize,
        .freetype = true,
        .@"backend-metal" = true,
        .@"backend-osx" = true,
        .@"backend-opengl3" = false,
    })) |dep| {
        step.root_module.addImport("dcimgui", dep.module("dcimgui"));
        step.root_module.linkLibrary(dep.artifact("dcimgui"));
        try static_libs.append(
            b.allocator,
            dep.artifact("dcimgui").getEmittedBin(),
        );
    }

    // Fonts
    {
        // JetBrains Mono
        if (b.lazyDependency("jetbrains_mono", .{})) |jb_mono| {
            step.root_module.addAnonymousImport(
                "jetbrains_mono_regular",
                .{ .root_source_file = jb_mono.path("fonts/ttf/JetBrainsMono-Regular.ttf") },
            );
            step.root_module.addAnonymousImport(
                "jetbrains_mono_bold",
                .{ .root_source_file = jb_mono.path("fonts/ttf/JetBrainsMono-Bold.ttf") },
            );
            step.root_module.addAnonymousImport(
                "jetbrains_mono_italic",
                .{ .root_source_file = jb_mono.path("fonts/ttf/JetBrainsMono-Italic.ttf") },
            );
            step.root_module.addAnonymousImport(
                "jetbrains_mono_bold_italic",
                .{ .root_source_file = jb_mono.path("fonts/ttf/JetBrainsMono-BoldItalic.ttf") },
            );
            step.root_module.addAnonymousImport(
                "jetbrains_mono_variable",
                .{ .root_source_file = jb_mono.path("fonts/variable/JetBrainsMono[wght].ttf") },
            );
            step.root_module.addAnonymousImport(
                "jetbrains_mono_variable_italic",
                .{ .root_source_file = jb_mono.path("fonts/variable/JetBrainsMono-Italic[wght].ttf") },
            );
        }

        // Symbols-only nerd font
        if (b.lazyDependency("nerd_fonts_symbols_only", .{})) |nf_symbols| {
            step.root_module.addAnonymousImport(
                "nerd_fonts_symbols_only",
                .{ .root_source_file = nf_symbols.path("SymbolsNerdFont-Regular.ttf") },
            );
        }
    }

    self.help_strings.addImport(step);
    self.unicode_tables.addImport(step);

    return static_libs;
}

/// Add only the dependencies required for `Config.simd` enabled. This also
/// adds all the simd source files for compilation.
pub fn addSimd(
    b: *std.Build,
    m: *std.Build.Module,
    static_libs: ?*LazyPathList,
) !void {
    const target = m.resolved_target.?;
    const optimize = m.optimize.?;
    const system_highway = b.systemIntegrationOption("highway", .{ .default = false });

    // Simdutf
    if (b.systemIntegrationOption("simdutf", .{})) {
        m.linkSystemLibrary("simdutf", dynamic_link_opts);
    } else {
        if (b.lazyDependency("simdutf", .{
            .target = target,
            .optimize = optimize,
            .no_libcxx = true,
        })) |simdutf_dep| {
            m.linkLibrary(simdutf_dep.artifact("simdutf"));
            if (static_libs) |v| try v.append(
                b.allocator,
                simdutf_dep.artifact("simdutf").getEmittedBin(),
            );
        }
    }

    // Highway
    if (system_highway) {
        m.linkSystemLibrary("libhwy", dynamic_link_opts);
    } else {
        if (b.lazyDependency("highway", .{
            .target = target,
            .optimize = optimize,
        })) |highway_dep| {
            m.linkLibrary(highway_dep.artifact("highway"));
            if (static_libs) |v| try v.append(
                b.allocator,
                highway_dep.artifact("highway").getEmittedBin(),
            );
        }
    }

    // SIMD C++ files
    m.addIncludePath(b.path("src"));
    {
        // From hwy/detect_targets.h
        var flags: std.ArrayListUnmanaged([]const u8) = .empty;

        // Application SIMD sources require C++17.
        try flags.append(
            b.allocator,
            "-std=c++17",
        );

        // Keep our SIMD sources in the same Highway header mode as the
        // vendored package build so HWY's inline dispatch/runtime helpers
        // have a consistent ABI.
        if (!system_highway) try flags.append(
            b.allocator,
            "-DHWY_NO_LIBCXX",
        );

        // When using the vendored simdutf, build its headers in no-libcxx
        // mode so we don't need C++ standard library headers at all.
        // System simdutf headers may not support this define.
        if (!b.systemIntegrationOption("simdutf", .{})) try flags.append(
            b.allocator,
            "-DSIMDUTF_NO_LIBCXX",
        );

        m.addCSourceFiles(.{
            .files = &.{
                "src/simd/base64.cpp",
                "src/simd/codepoint_width.cpp",
                "src/simd/index_of.cpp",
                "src/simd/vt.cpp",
            },
            .flags = flags.items,
        });
    }
}
