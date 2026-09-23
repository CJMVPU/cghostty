/// The visual style of the cursor. Whether or not it blinks
/// is determined by mode 12 (modes.zig). This mode is synchronized
/// with CSI q, the same as xterm.
///
/// Bar, block, and underline correspond to DECSCUSR 5/6, 1/2, and 3/4.
/// Hollow block is Ghostty-specific and is reported as DECSCUSR 1 or 2.
pub const Style = enum(u2) {
    bar = 0,
    block = 1,
    underline = 2,
    block_hollow = 3,
};
