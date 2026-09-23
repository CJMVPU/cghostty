import Foundation
import GhosttyKit

extension Ghostty {
    /// `ghostty_command_s`
    struct Command: Sendable {
        /// The title of the command.
        let title: String

        /// Human-friendly description of what this command will do.
        let description: String

        /// The full action that must be performed to invoke this command.
        let action: String

        /// Only the key portion of the action so you can compare action types, e.g. `goto_split`
        /// instead of `goto_split:left`.
        let actionKey: String

        init(cValue: ghostty_command_s) {
            self.title = Self.localizedText(String(cString: cValue.title), builtIn: cValue.localize)
            self.description = Self.localizedText(String(cString: cValue.description), builtIn: cValue.localize)
            self.action = String(cString: cValue.action)
            self.actionKey = String(cString: cValue.action_key)
        }

        /// Custom command prose is always literal, even when it matches an
        /// English built-in title. Action identifiers are never localized.
        static func localizedText(_ value: String, builtIn: Bool, bundle: Bundle = .main) -> String {
            guard builtIn, !value.isEmpty else { return value }
            return String(localized: String.LocalizationValue(value), table: "CommandPalette", bundle: bundle)
        }
    }
}
