import AppKit
import GhosttyKit

extension NSPasteboard {
    /// The pasteboard for the Ghostty enum type. Returns nil for locations
    /// macOS can't serve; callers report those as unsupported.
    static func ghostty(_ clipboard: ghostty_clipboard_e) -> NSPasteboard? {
        switch clipboard {
        case GHOSTTY_CLIPBOARD_STANDARD:
            return Self.general

        case GHOSTTY_CLIPBOARD_SELECTION:
            return Self.ghosttySelection

        case GHOSTTY_CLIPBOARD_PRIMARY:
            // macOS has no primary selection.
            return nil

        default:
            return nil
        }
    }
}

// MARK: Ghostty Types
nonisolated extension NSColor {
    /// Create a color from a Ghostty color.
    convenience init(ghostty: ghostty_config_color_s) {
        let red = Double(ghostty.r) / 255
        let green = Double(ghostty.g) / 255
        let blue = Double(ghostty.b) / 255
        self.init(red: red, green: green, blue: blue, alpha: 1)
    }
}
