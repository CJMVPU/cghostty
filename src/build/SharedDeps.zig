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

/// One module instance shared by build artifacts to keep Zig module identity
/// stable when generated table paths are used as dependency arguments.
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

    // Reuse one uucode module with the generated tables.
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

    step.root_module.link_libc = true;

    // libc++ is required for the app's C++ dependencies.
    step.root_module.link_libcpp = true;

    // System SDK headers and the Metal library are required by every artifact.
    try @import("apple_sdk").addPaths(b, step);
    self.metallib.output.addStepDependencies(&step.step);
    step.root_module.addAnonymousImport("ghostty_metallib", .{
        .root_source_file = self.metallib.output,
    });

    // Other dependencies, mostly pure Zig
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
        if (b.lazyDependency("lxgw_wenkai", .{})) |wenkai| {
            const resources = b.addOptions();
            resources.addOption([]const u8, "wenkai", wenkai.path("LXGWWenKaiMono-Medium.ttf").getPath(b));
            step.root_module.addOptions("font_resources", resources);
        }

        // JetBrains Mono
        if (b.lazyDependency("jetbrains_mono", .{})) |jb_mono| {
            step.root_module.addAnonymousImport(
                "jetbrains_mono_regular",
                .{ .root_source_file = jb_mono.path("fonts/ttf/JetBrainsMono-Regular.ttf") },
            );
            step.root_module.addAnonymousImport(
                "jetbrains_mono_variable",
                .{ .root_source_file = jb_mono.path("fonts/variable/JetBrainsMono[wght].ttf") },
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
