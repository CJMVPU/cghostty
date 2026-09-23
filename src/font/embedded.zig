//! Fonts that can be embedded with Ghostty. Note they are only actually
//! embedded in the binary if they are referenced by the code, so fonts
//! used for tests will not result in the final binary being larger.
//!
//! Be careful to ensure that any fonts you embed are licensed for
//! redistribution and include their license as necessary.

/// Default terminal font embedded in the executable.
pub const default_font = @embedFile("lxgw_wenkai_medium");
pub const default_family = "LXGW WenKai Mono";
pub const default_style = "Medium";

/// Variable fonts used by font backend tests.
pub const variable = @embedFile("jetbrains_mono_variable");

/// Symbols-only nerd font.
pub const symbols_nerd_font = @embedFile("nerd_fonts_symbols_only");

/// Regular JetBrains Mono face used by font backend tests.
pub const regular = @embedFile("jetbrains_mono_regular");

/// Emoji fonts
pub const emoji_text = @embedFile("res/NotoEmoji-Regular.ttf");

// Fonts below are ONLY used for testing.

/// A font for testing which is patched with nerd font symbols.
pub const test_nerd_font = @embedFile("res/JetBrainsMonoNerdFont-Regular.ttf");

/// Specific font families below:
pub const code_new_roman = @embedFile("res/CodeNewRoman-Regular.otf");
pub const inconsolata = @embedFile("res/Inconsolata-Regular.ttf");
pub const geist_mono = @embedFile("res/GeistMono-Regular.ttf");
pub const jetbrains_mono = @embedFile("res/JetBrainsMonoNoNF-Regular.ttf");
pub const julia_mono = @embedFile("res/JuliaMono-Regular.ttf");

/// Monaspace has weird ligature behaviors we want to test in our shapers
/// so we embed it here.
pub const monaspace_neon = @embedFile("res/MonaspaceNeon-Regular.otf");
