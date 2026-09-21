import os
import SwiftUI
import GhosttyKit

// MARK: C Extensions

extension Ghostty {
    // The user notification category identifier
    static let userNotificationCategory = "com.cjmvpu.cghostty.userNotification"

    // The user notification "Show" action
    static let userNotificationActionShow = "com.cjmvpu.cghostty.userNotification.Show"
}

// MARK: Build Info

extension Ghostty {
    struct Info {
        var mode: ghostty_build_mode_e
        var version: String
        var showsDebugOverlays: Bool { mode == GHOSTTY_BUILD_MODE_DEBUG || mode == GHOSTTY_BUILD_MODE_RELEASE_SAFE }
    }

    static var info: Info {
        let raw = ghostty_info()
        let version = NSString(
            bytes: raw.version,
            length: Int(raw.version_len),
            encoding: NSUTF8StringEncoding
        ) ?? "unknown"

        return Info(mode: raw.build_mode, version: String(version))
    }
}

// MARK: General Helpers

extension Ghostty {
    enum LaunchSource: String {
        case cli
        case app
        case zig_run
    }

    /// Returns the mechanism that launched the app. This is based on an env var so
    /// its up to the env var being set in the correct circumstance.
    static var launchSource: LaunchSource {
        guard let envValue = ProcessInfo.processInfo.environment["CGHOSTTY_MAC_LAUNCH_SOURCE"] else {
            // We default to the CLI because the app bundle always sets the
            // source. If its unset we assume we're in a CLI environment.
            return .cli
        }

        // If the env var is set but its unknown then we default back to the app.
        return LaunchSource(rawValue: envValue) ?? .app
    }
}

// MARK: Swift Types for C Types

extension Ghostty {
    nonisolated final class AllocatedString {
        private let cString: ghostty_string_s

        init(_ c: ghostty_string_s) {
            self.cString = c
        }

        var string: String {
            guard let ptr = cString.ptr else { return "" }
            let data = Data(bytes: ptr, count: Int(cString.len))
            return String(data: data, encoding: .utf8) ?? ""
        }

        deinit {
            ghostty_string_free(cString)
        }
    }
}

extension Ghostty {
    enum SetFloatWIndow {
        case on
        case off
        case toggle

        static func from(_ c: ghostty_action_float_window_e) -> Self? {
            switch c {
            case GHOSTTY_FLOAT_WINDOW_ON:
                return .on

            case GHOSTTY_FLOAT_WINDOW_OFF:
                return .off

            case GHOSTTY_FLOAT_WINDOW_TOGGLE:
                return .toggle

            default:
                return nil
            }
        }
    }

    enum SetSecureInput {
        case on
        case off
        case toggle

        static func from(_ c: ghostty_action_secure_input_e) -> Self? {
            switch c {
            case GHOSTTY_SECURE_INPUT_ON:
                return .on

            case GHOSTTY_SECURE_INPUT_OFF:
                return .off

            case GHOSTTY_SECURE_INPUT_TOGGLE:
                return .toggle

            default:
                return nil
            }
        }
    }

    /// An enum that is used for the directions that a split focus event can change.
    enum SplitFocusDirection {
        case previous, next, up, down, left, right

        /// Initialize from a Ghostty API enum.
        static func from(direction: ghostty_action_goto_split_e) -> Self? {
            switch direction {
            case GHOSTTY_GOTO_SPLIT_PREVIOUS:
                return .previous

            case GHOSTTY_GOTO_SPLIT_NEXT:
                return .next

            case GHOSTTY_GOTO_SPLIT_UP:
                return .up

            case GHOSTTY_GOTO_SPLIT_DOWN:
                return .down

            case GHOSTTY_GOTO_SPLIT_LEFT:
                return .left

            case GHOSTTY_GOTO_SPLIT_RIGHT:
                return .right

            default:
                return nil
            }
        }

        func toNative() -> ghostty_action_goto_split_e {
            switch self {
            case .previous:
                return GHOSTTY_GOTO_SPLIT_PREVIOUS

            case .next:
                return GHOSTTY_GOTO_SPLIT_NEXT

            case .up:
                return GHOSTTY_GOTO_SPLIT_UP

            case .down:
                return GHOSTTY_GOTO_SPLIT_DOWN

            case .left:
                return GHOSTTY_GOTO_SPLIT_LEFT

            case .right:
                return GHOSTTY_GOTO_SPLIT_RIGHT
            }
        }
    }

    /// Enum used for resizing splits. This is the direction the split divider will move.
    enum SplitResizeDirection {
        case up, down, left, right

        static func from(direction: ghostty_action_resize_split_direction_e) -> Self? {
            switch direction {
            case GHOSTTY_RESIZE_SPLIT_UP:
                return .up
            case GHOSTTY_RESIZE_SPLIT_DOWN:
                return .down
            case GHOSTTY_RESIZE_SPLIT_LEFT:
                return .left
            case GHOSTTY_RESIZE_SPLIT_RIGHT:
                return .right
            default:
                return nil
            }
        }

        func toNative() -> ghostty_action_resize_split_direction_e {
            switch self {
            case .up:
                return GHOSTTY_RESIZE_SPLIT_UP
            case .down:
                return GHOSTTY_RESIZE_SPLIT_DOWN
            case .left:
                return GHOSTTY_RESIZE_SPLIT_LEFT
            case .right:
                return GHOSTTY_RESIZE_SPLIT_RIGHT
            }
        }
    }
}

// MARK: SplitFocusDirection Extensions

extension Ghostty.SplitFocusDirection {
    /// Convert to a SplitTree.FocusDirection for the given ViewType.
    func toSplitTreeFocusDirection<ViewType>() -> SplitTree<ViewType>.FocusDirection {
        switch self {
        case .previous:
            return .previous

        case .next:
            return .next

        case .up:
            return .spatial(.up)

        case .down:
            return .spatial(.down)

        case .left:
            return .spatial(.left)

        case .right:
            return .spatial(.right)
        }
    }
}

extension Ghostty {
    /// One representation of clipboard contents. The data is binary-safe;
    /// textual consumers use `string`.
    struct ClipboardContent {
        let mime: String
        let data: Data

        /// The data as text, if it is valid UTF-8.
        var string: String? { String(data: data, encoding: .utf8) }

        static func from(content: ghostty_clipboard_content_s) -> ClipboardContent? {
            guard let mimePtr = content.mime,
                  let dataPtr = content.data else {
                return nil
            }

            let data: Data = if content.len > 0 {
                Data(bytes: dataPtr, count: content.len)
            } else {
                Data()
            }

            return ClipboardContent(
                mime: String(cString: mimePtr),
                data: data
            )
        }
    }

    /// Enum for the macos-window-buttons config option
    nonisolated enum MacOSWindowButtons: String, Sendable {
        case visible
        case hidden
    }

    /// Enum for the macos-titlebar-proxy-icon config option
    enum MacOSTitlebarProxyIcon: String {
        case visible
        case hidden
    }

    /// Enum for auto-update-channel config option

}

// Make the input enum hashable.
extension ghostty_input_key_e: @retroactive Hashable {}
