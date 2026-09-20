import SwiftUI
import Observation
import GhosttyKit

extension Ghostty {
    /// Observable publication of a matched core resource and immutable native snapshot.
    @MainActor @Observable class Config {
        /// One assignment publishes a coherent generation; observers cannot see a new
        /// snapshot paired with an old handle. Replacing state releases the old owner.
        private var state: State

        private struct State {
            let handle: ConfigHandle?
            let snapshot: ConfigSnapshot

            init(handle: ConfigHandle?) {
                self.handle = handle
                self.snapshot = ConfigSnapshot(handle: handle)
            }
        }

        /// Borrowed only by the internal bridge while this Config remains alive.
        var config: ghostty_config_t? { state.handle?.value }
        var snapshot: ConfigSnapshot { state.snapshot }
        var window: WindowConfig { snapshot.window }
        var loaded: Bool { snapshot.loaded }
        var errors: [String] { snapshot.errors }

        init(handle: ConfigHandle?) {
            state = State(handle: handle)
        }

        convenience init(at path: String? = nil, finalize: Bool = true) {
            self.init(handle: ConfigHandle.load(at: path, finalize: finalize))
        }

        convenience init(clone config: ghostty_config_t) {
            self.init(handle: ConfigHandle(cloning: config))
        }

        func replace(with handle: ConfigHandle) {
            state = State(handle: handle)
        }

        // MARK: - Keybindings

        /// Return the key equivalent for the given action. The action is the name of the action
        /// in the Ghostty configuration. For example `keybind = cmd+q=quit` in Ghostty
        /// configuration would be "quit" action.
        ///
        /// Returns nil if there is no key equivalent for the given action.
        @MainActor func keyboardShortcut(for action: String) -> KeyboardShortcut? {
            guard let trigger = keybindTrigger(for: action) else { return nil }
            return Ghostty.keyboardShortcut(for: trigger)
        }

        func keybindTrigger(for action: String) -> ghostty_input_trigger_s? {
            state.handle?.keybindTrigger(for: action)
        }

        // Existing native accessors are projections of the same snapshot, not C reads.
        var bellFeatures: BellFeatures { snapshot.bellFeatures }
        var bellAudioPath: ConfigPath? { snapshot.bellAudioPath }
        var bellAudioVolume: Float { snapshot.bellAudioVolume }
        var notifyOnCommandFinish: NotifyOnCommandFinish { snapshot.notifyOnCommandFinish }
        var notifyOnCommandFinishAction: NotifyOnCommandFinishAction { snapshot.notifyOnCommandFinishAction }
        var notifyOnCommandFinishAfter: Duration { snapshot.notifyOnCommandFinishAfter }
        var splitPreserveZoom: SplitPreserveZoom { snapshot.splitPreserveZoom }
        var initialWindow: Bool { snapshot.initialWindow }
        var shouldQuitAfterLastWindowClosed: Bool { snapshot.shouldQuitAfterLastWindowClosed }
        var title: String? { snapshot.title }
        var windowSaveState: String { snapshot.windowSaveState }
        var windowNewTabPosition: String { snapshot.windowNewTabPosition }
        var windowDecorations: Bool { snapshot.windowDecorations }
        var windowTheme: String? { snapshot.windowTheme }
        var dragHandle: DragHandle { snapshot.dragHandle }
        var windowFullscreen: FullscreenMode? { snapshot.windowFullscreen }
        var windowFullscreenMode: FullscreenMode { snapshot.windowFullscreenMode }
        var macosWindowButtons: MacOSWindowButtons { snapshot.macosWindowButtons }
        var macosTitlebarStyle: MacOSTitlebarStyle { snapshot.macosTitlebarStyle }
        var macosTitlebarProxyIcon: MacOSTitlebarProxyIcon { snapshot.macosTitlebarProxyIcon }
        var macosDockDropBehavior: MacDockDropBehavior { snapshot.macosDockDropBehavior }
        var macosWindowShadow: Bool { snapshot.macosWindowShadow }
        var macosHidden: MacHidden { snapshot.macosHidden }
        var backgroundColor: Color { snapshot.backgroundColor }
        var backgroundOpacity: Double { snapshot.backgroundOpacity }
        var backgroundBlur: BackgroundBlur { snapshot.backgroundBlur }
        var unfocusedSplitOpacity: Double { snapshot.unfocusedSplitOpacity }
        var unfocusedSplitFill: Color { snapshot.unfocusedSplitFill }
        var splitDividerColor: Color { snapshot.splitDividerColor }
        var quickTerminalPosition: QuickTerminalPosition { snapshot.quickTerminalPosition }
        var quickTerminalScreen: QuickTerminalScreen { snapshot.quickTerminalScreen }
        var quickTerminalAnimationDuration: Double { snapshot.quickTerminalAnimationDuration }
        var quickTerminalAutoHide: Bool { snapshot.quickTerminalAutoHide }
        var quickTerminalSpaceBehavior: QuickTerminalSpaceBehavior { snapshot.quickTerminalSpaceBehavior }
        var quickTerminalSize: QuickTerminalSize { snapshot.quickTerminalSize }
        var resizeOverlay: ResizeOverlay { snapshot.resizeOverlay }
        var resizeOverlayPosition: ResizeOverlayPosition { snapshot.resizeOverlayPosition }
        var resizeOverlayDuration: UInt { snapshot.resizeOverlayDuration }
        var undoTimeout: Duration { snapshot.undoTimeout }
        var autoSecureInput: Bool { snapshot.autoSecureInput }
        var secureInputIndication: Bool { snapshot.secureInputIndication }
        var macosAppleScript: Bool { snapshot.macosAppleScript }
        var macosShortcuts: MacShortcuts { snapshot.macosShortcuts }
        var abnormalCommandExitRuntime: Duration { snapshot.abnormalCommandExitRuntime }
        var scrollbar: Scrollbar { snapshot.scrollbar }
        var commandPaletteEntries: [Ghostty.Command] { snapshot.commandPaletteEntries }
        var progressStyle: Bool { snapshot.progressStyle }
    }
}

// MARK: Configuration Enums

extension Ghostty.Config {

    /// Background blur configuration that maps from the C API values.
    /// Positive values represent blur radius, special negative values
    /// represent macOS-specific glass effects.
    nonisolated enum BackgroundBlur: Equatable, Sendable {
        case disabled
        case radius(Int)
        case macosGlassRegular
        case macosGlassClear

        init(fromCValue value: Int16) {
            switch value {
            case 0:
                self = .disabled
            case -1:
                self = .macosGlassRegular
            case -2:
                self = .macosGlassClear
            default:
                self = .radius(Int(value))
            }
        }

        var isEnabled: Bool {
            switch self {
            case .disabled:
                return false
            default:
                return true
            }
        }

        /// Returns true if this is a macOS glass style (regular or clear).
        var isGlassStyle: Bool {
            switch self {
            case .macosGlassRegular, .macosGlassClear:
                return true
            default:
                return false
            }
        }

        /// Returns the blur radius if applicable, nil for glass effects.
        var radius: Int? {
            switch self {
            case .disabled:
                return nil
            case .radius(let r):
                return r
            case .macosGlassRegular, .macosGlassClear:
                return nil
            }
        }
    }

    nonisolated struct BellFeatures: OptionSet, Sendable {
        let rawValue: CUnsignedInt

        static let system = BellFeatures(rawValue: 1 << 0)
        static let audio = BellFeatures(rawValue: 1 << 1)
        static let attention = BellFeatures(rawValue: 1 << 2)
        static let title = BellFeatures(rawValue: 1 << 3)
        static let border = BellFeatures(rawValue: 1 << 4)

        static let defaultValue = BellFeatures([.attention, .title])
    }

    nonisolated struct SplitPreserveZoom: OptionSet, Sendable {
        let rawValue: CUnsignedInt

        static let navigation = SplitPreserveZoom(rawValue: 1 << 0)
    }

    nonisolated enum MacDockDropBehavior: String, Sendable {
        case new_tab = "new-tab"
        case new_window = "new-window"
    }

    nonisolated enum MacHidden: String, Sendable {
        case never
        case always
    }

    nonisolated enum MacShortcuts: String, Sendable {
        case allow
        case deny
        case ask
    }

    nonisolated enum Scrollbar: String, Sendable {
        case system
        case never
    }

    nonisolated enum ResizeOverlay: String, Sendable {
        case always
        case never
        case after_first = "after-first"
    }

    nonisolated enum ResizeOverlayPosition: String, Sendable {
        case center
        case top_left = "top-left"
        case top_center = "top-center"
        case top_right = "top-right"
        case bottom_left = "bottom-left"
        case bottom_center = "bottom-center"
        case bottom_right = "bottom-right"

        func top() -> Bool {
            switch self {
            case .top_left, .top_center, .top_right: return true
            default: return false
            }
        }

        func bottom() -> Bool {
            switch self {
            case .bottom_left, .bottom_center, .bottom_right: return true
            default: return false
            }
        }

        func left() -> Bool {
            switch self {
            case .top_left, .bottom_left: return true
            default: return false
            }
        }

        func right() -> Bool {
            switch self {
            case .top_right, .bottom_right: return true
            default: return false
            }
        }
    }

    nonisolated enum WindowDecoration: String, Sendable {
        case none
        case client
        case server
        case auto

        func enabled() -> Bool {
            switch self {
            case .client, .server, .auto: return true
            case .none: return false
            }
        }
    }

    nonisolated enum NotifyOnCommandFinish: String, Sendable {
        case never
        case unfocused
        case always
    }

    nonisolated struct NotifyOnCommandFinishAction: OptionSet, Sendable {
        let rawValue: CUnsignedInt

        static let bell = NotifyOnCommandFinishAction(rawValue: 1 << 0)
        static let notify = NotifyOnCommandFinishAction(rawValue: 1 << 1)
    }

    nonisolated enum MacOSTitlebarStyle: String, Sendable {
        static let `default` = MacOSTitlebarStyle.transparent
        case native, transparent, tabs, hidden
    }

    nonisolated enum DragHandle: String, Sendable {
        case always, auto, never
    }
}
