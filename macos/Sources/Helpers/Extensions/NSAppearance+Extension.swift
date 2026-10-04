import AppKit
import SwiftUI

extension NSAppearance {
    /// Returns true if the appearance is some kind of dark.
    var isDark: Bool {
        return name.rawValue.lowercased().contains("dark")
    }

    /// Initialize a desired NSAppearance for the Ghostty configuration.
    convenience init?(ghosttyConfig config: Ghostty.ConfigSnapshot) {
        self.init(windowTheme: config.windowTheme, backgroundColor: config.backgroundColor)
    }

    convenience init?(windowTheme: String?, backgroundColor: Color) {
        guard let theme = windowTheme else { return nil }
        switch theme {
        case "dark":
            self.init(named: .darkAqua)

        case "light":
            self.init(named: .aqua)

        case "auto":
            let color = NSColor(backgroundColor)
            if color.isLightColor {
                self.init(named: .aqua)
            } else {
                self.init(named: .darkAqua)
            }

        default:
            return nil
        }
    }
}
