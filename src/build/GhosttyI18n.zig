const GhosttyI18n = @This();

const std = @import("std");
const locales = @import("../os/i18n_locales.zig").locales;

const domain = "com.cjmvpu.cghostty";

owner: *std.Build,
steps: []*std.Build.Step,

/// This step updates the translation files on disk that should be
/// committed to the repo.
update_step: *std.Build.Step,

pub fn init(b: *std.Build) !GhosttyI18n {
    var steps: std.ArrayList(*std.Build.Step) = .empty;
    defer steps.deinit(b.allocator);

    inline for (locales) |locale| {
        const target_locale = locale;

        const msgfmt = b.addSystemCommand(&.{ "msgfmt", "-o", "-" });
        msgfmt.addFileArg(b.path("po/" ++ locale ++ ".po"));

        try steps.append(b.allocator, &b.addInstallFile(
            msgfmt.captureStdOut(.{}),
            std.fmt.comptimePrint(
                "share/locale/{s}/LC_MESSAGES/{s}.mo",
                .{ target_locale, domain },
            ),
        ).step);
    }

    return .{
        .owner = b,
        .update_step = try createUpdateStep(b),
        .steps = try steps.toOwnedSlice(b.allocator),
    };
}

pub fn install(self: *const GhosttyI18n) void {
    self.addStepDependencies(self.owner.getInstallStep());
}

pub fn addStepDependencies(
    self: *const GhosttyI18n,
    other_step: *std.Build.Step,
) void {
    for (self.steps) |step| other_step.dependOn(step);
}

fn createUpdateStep(b: *std.Build) !*std.Build.Step {
    const xgettext = b.addSystemCommand(&.{
        "xgettext",
        "--language=C", // Silence the "unknown extension" errors
        "--from-code=UTF-8",
        "--keyword=_",
        "--keyword=N_",
        "--keyword=C_:1c,2",
        "--add-comments=Translators",
        "--package-name=" ++ domain,
        "--copyright-holder=Mitchell Hashimoto, Ghostty contributors",
        "-o",
        "-",
    });

    // For localization of command palette
    const command_palette_path = "src/input/command.zig";
    xgettext.addArg(command_palette_path);
    xgettext.addFileInput(b.path(command_palette_path));

    // The command palette is the only gettext source; the GTK/Python
    // extraction and multi-catalog merge pipeline is no longer needed.
    const pot = xgettext.captureStdOut(.{});
    const usf = b.addUpdateSourceFiles();
    usf.addCopyFileToSource(
        pot,
        "po/" ++ domain ++ ".pot",
    );

    inline for (locales) |locale| {
        const msgmerge = b.addSystemCommand(&.{ "msgmerge", "--quiet", "--no-fuzzy-matching" });
        msgmerge.addFileArg(b.path("po/" ++ locale ++ ".po"));
        msgmerge.addFileArg(pot);
        const active = b.addSystemCommand(&.{ "msgattrib", "--no-obsolete" });
        active.addFileArg(msgmerge.captureStdOut(.{}));
        usf.addCopyFileToSource(active.captureStdOut(.{}), "po/" ++ locale ++ ".po");
    }

    return &usf.step;
}
