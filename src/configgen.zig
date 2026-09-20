//! Generate the native typed config keys from Config and the actual C getter ABI.
const std = @import("std");
const Config = @import("config/Config.zig");
const key = @import("config/key.zig");
const c_get = @import("config/c_get.zig");

// Only selection is maintained here. Field names are checked by Key and storage
// types are derived, never duplicated in a separate native schema.
const native_keys = [_]key.Key{
    .@"abnormal-command-exit-runtime",
    .background,
    .@"background-blur",
    .@"background-opacity",
    .@"bell-audio-path",
    .@"bell-audio-volume",
    .@"bell-features",
    .@"command-palette-entry",
    .@"drag-handle",
    .@"focus-follows-mouse",
    .fullscreen,
    .@"initial-window",
    .@"macos-applescript",
    .@"macos-auto-secure-input",
    .@"macos-dock-drop-behavior",
    .@"macos-hidden",
    .@"macos-non-native-fullscreen",
    .@"macos-secure-input-indication",
    .@"macos-shortcuts",
    .@"macos-titlebar-proxy-icon",
    .@"macos-titlebar-style",
    .@"macos-window-buttons",
    .@"macos-window-shadow",
    .maximize,
    .@"notify-on-command-finish",
    .@"notify-on-command-finish-action",
    .@"notify-on-command-finish-after",
    .@"progress-style",
    .@"quick-terminal-animation-duration",
    .@"quick-terminal-autohide",
    .@"quick-terminal-position",
    .@"quick-terminal-screen",
    .@"quick-terminal-size",
    .@"quick-terminal-space-behavior",
    .@"quit-after-last-window-closed",
    .@"resize-overlay",
    .@"resize-overlay-duration",
    .@"resize-overlay-position",
    .scrollbar,
    .@"split-divider-color",
    .@"split-preserve-zoom",
    .title,
    .@"undo-timeout",
    .@"unfocused-split-fill",
    .@"unfocused-split-opacity",
    .@"window-decoration",
    .@"window-new-tab-position",
    .@"window-position-x",
    .@"window-position-y",
    .@"window-save-state",
    .@"window-step-resize",
    .@"window-theme",
    .@"window-title-font-family",
};

fn swiftType(comptime T: type) []const u8 {
    if (T == i16 or T == c_short) return "Int16";
    return switch (T) {
        bool => "Bool",
        c_uint => "CUnsignedInt",
        usize => "UInt",
        f32 => "Float",
        f64 => "Double",
        [*:0]const u8, ?[*:0]const u8 => "UnsafePointer<CChar>?",
        Config.Color.C => "ghostty_config_color_s",
        Config.Path.C => "ghostty_config_path_s",
        Config.QuickTerminalSize.C => "ghostty_config_quick_terminal_size_s",
        Config.RepeatableCommand.C => "ghostty_config_command_list_s",
        else => @compileError("Missing native config ABI mapping: " ++ @typeName(T)),
    };
}

pub fn main(init: std.process.Init) !void {
    @setEvalBranchQuota(100_000);
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    const writer = &stdout.interface;
    try writer.writeAll(@embedFile("config/ConfigSchema.swift.template"));
    inline for (native_keys) |k| {
        const name = @tagName(k);
        const C = c_get.CValue(key.Value(k)) orelse @compileError("Unsupported native config key: " ++ name);
        try writer.writeAll("        static let ");
        var uppercase = false;
        for (name) |char| {
            if (char == '-') {
                uppercase = true;
                continue;
            }
            try writer.writeByte(if (uppercase) std.ascii.toUpper(char) else char);
            uppercase = false;
        }
        try writer.print(" = Key<{s}>(\"{s}\")\n", .{ swiftType(C), name });
    }
    try writer.writeAll("    }\n}\n");
    try stdout.end();
}
