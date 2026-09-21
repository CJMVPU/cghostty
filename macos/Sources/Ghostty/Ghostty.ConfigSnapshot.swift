import SwiftUI
import GhosttyKit

extension Ghostty {
    /// One immutable native projection of an effective configuration.
    /// No handles, borrowed strings or mutable core storage escape into this value.
    nonisolated struct ConfigSnapshot: Sendable {
        let loaded: Bool
        let errors: [String]
        let window: WindowConfig
        let bellFeatures: Config.BellFeatures
        let bellAudioPath: ConfigPath?
        let bellAudioVolume: Float
        let notifyOnCommandFinish: Config.NotifyOnCommandFinish
        let notifyOnCommandFinishAction: Config.NotifyOnCommandFinishAction
        let notifyOnCommandFinishAfter: Duration
        let splitPreserveZoom: Config.SplitPreserveZoom
        let initialWindow: Bool
        let shouldQuitAfterLastWindowClosed: Bool
        let title: String?
        let windowSaveState: String
        let windowNewTabPosition: String
        let windowDecorations: Bool
        let windowTheme: String?
        let dragHandle: Config.DragHandle
        let windowFullscreen: FullscreenMode?
        let windowFullscreenMode: FullscreenMode
        let macosWindowButtons: MacOSWindowButtons
        let macosTitlebarStyle: Config.MacOSTitlebarStyle
        let macosTitlebarProxyIcon: MacOSTitlebarProxyIcon
        let macosDockDropBehavior: Config.MacDockDropBehavior
        let macosWindowShadow: Bool
        let macosHidden: Config.MacHidden
        let backgroundColor: Color
        let backgroundOpacity: Double
        let backgroundBlur: Config.BackgroundBlur
        let unfocusedSplitOpacity: Double
        let unfocusedSplitFill: Color
        let splitDividerColor: Color
        let quickTerminalPosition: QuickTerminalPosition
        let quickTerminalScreen: QuickTerminalScreen
        let quickTerminalAnimationDuration: Double
        let quickTerminalAutoHide: Bool
        let quickTerminalSpaceBehavior: QuickTerminalSpaceBehavior
        let quickTerminalSize: QuickTerminalSize
        let resizeOverlay: Config.ResizeOverlay
        let resizeOverlayPosition: Config.ResizeOverlayPosition
        let resizeOverlayDuration: UInt
        let undoTimeout: Duration
        let autoSecureInput: Bool
        let secureInputIndication: Bool
        let macosAppleScript: Bool
        let macosShortcuts: Config.MacShortcuts
        let abnormalCommandExitRuntime: Duration
        let scrollbar: Config.Scrollbar
        let commandPaletteEntries: [Ghostty.Command]
        let progressStyle: Bool

        @MainActor
        init(handle: ConfigHandle?) {
            loaded = handle != nil
            errors = handle?.errors ?? []
            window = WindowConfig(config: handle?.value)
            let reader = Reader(config: handle?.value)
            bellFeatures = reader.bellFeatures
            bellAudioPath = reader.bellAudioPath
            bellAudioVolume = reader.bellAudioVolume
            notifyOnCommandFinish = reader.notifyOnCommandFinish
            notifyOnCommandFinishAction = reader.notifyOnCommandFinishAction
            notifyOnCommandFinishAfter = reader.notifyOnCommandFinishAfter
            splitPreserveZoom = reader.splitPreserveZoom
            initialWindow = reader.initialWindow
            shouldQuitAfterLastWindowClosed = reader.shouldQuitAfterLastWindowClosed
            title = reader.title
            windowSaveState = reader.windowSaveState
            windowNewTabPosition = reader.windowNewTabPosition
            windowDecorations = reader.windowDecorations
            windowTheme = reader.windowTheme
            dragHandle = reader.dragHandle
            windowFullscreen = reader.windowFullscreen
            windowFullscreenMode = reader.windowFullscreenMode
            macosWindowButtons = reader.macosWindowButtons
            macosTitlebarStyle = reader.macosTitlebarStyle
            macosTitlebarProxyIcon = reader.macosTitlebarProxyIcon
            macosDockDropBehavior = reader.macosDockDropBehavior
            macosWindowShadow = reader.macosWindowShadow
            macosHidden = reader.macosHidden
            backgroundColor = reader.backgroundColor
            backgroundOpacity = reader.backgroundOpacity
            backgroundBlur = reader.backgroundBlur
            unfocusedSplitOpacity = reader.unfocusedSplitOpacity
            unfocusedSplitFill = reader.unfocusedSplitFill
            splitDividerColor = reader.splitDividerColor
            quickTerminalPosition = reader.quickTerminalPosition
            quickTerminalScreen = reader.quickTerminalScreen
            quickTerminalAnimationDuration = reader.quickTerminalAnimationDuration
            quickTerminalAutoHide = reader.quickTerminalAutoHide
            quickTerminalSpaceBehavior = reader.quickTerminalSpaceBehavior
            quickTerminalSize = reader.quickTerminalSize
            resizeOverlay = reader.resizeOverlay
            resizeOverlayPosition = reader.resizeOverlayPosition
            resizeOverlayDuration = reader.resizeOverlayDuration
            undoTimeout = reader.undoTimeout
            autoSecureInput = reader.autoSecureInput
            secureInputIndication = reader.secureInputIndication
            macosAppleScript = reader.macosAppleScript
            macosShortcuts = reader.macosShortcuts
            abnormalCommandExitRuntime = reader.abnormalCommandExitRuntime
            scrollbar = reader.scrollbar
            commandPaletteEntries = reader.commandPaletteEntries
            progressStyle = reader.progressStyle
        }

        /// Temporary decoder borrowing a live handle during snapshot creation only.
        @MainActor private struct Reader {
            let config: ghostty_config_t?

            private func value<Value>(
                _ key: ConfigSchema.Key<Value>,
                default defaultValue: Value,
                unloaded: Value? = nil
            ) -> Value {
                guard let config else { return unloaded ?? defaultValue }
                var result = defaultValue
                _ = key.read(from: config, into: &result)
                return result
            }

            private func string(_ key: ConfigSchema.Key<UnsafePointer<CChar>?>) -> String? {
                guard let config else { return nil }
                var pointer: UnsafePointer<CChar>?
                guard key.read(from: config, into: &pointer), let pointer else { return nil }
                return String(cString: pointer)
            }

            var bellFeatures: Config.BellFeatures {
                guard let config = self.config else { return .defaultValue }
                var v: CUnsignedInt = 0
                let key = ConfigSchema.bellFeatures
                guard key.read(from: config, into: &v) else { return .defaultValue }
                return .init(rawValue: v)
            }

            var bellAudioPath: ConfigPath? {
                guard let config = self.config else { return nil }
                var v = ghostty_config_path_s()
                let key = ConfigSchema.bellAudioPath
                guard key.read(from: config, into: &v) else { return nil }
                let path = String(cString: v.path)
                return path.isEmpty ? nil : ConfigPath(path: path, optional: v.optional)
            }

            var bellAudioVolume: Float {
                Float(value(ConfigSchema.bellAudioVolume, default: 0.5))
            }

            var notifyOnCommandFinish: Config.NotifyOnCommandFinish {
                guard let str = string(ConfigSchema.notifyOnCommandFinish) else { return .never }
                return Config.NotifyOnCommandFinish(rawValue: str) ?? .never
            }

            var notifyOnCommandFinishAction: Config.NotifyOnCommandFinishAction {
                let defaultValue = Config.NotifyOnCommandFinishAction.bell
                guard let config = self.config else { return defaultValue }
                var v: CUnsignedInt = 0
                let key = ConfigSchema.notifyOnCommandFinishAction
                guard key.read(from: config, into: &v) else { return defaultValue }
                return .init(rawValue: v)
            }

            var notifyOnCommandFinishAfter: Duration {
                .milliseconds(value(ConfigSchema.notifyOnCommandFinishAfter, default: 0, unloaded: 5000))
            }

            var splitPreserveZoom: Config.SplitPreserveZoom {
                guard let config = self.config else { return .init() }
                var v: CUnsignedInt = 0
                let key = ConfigSchema.splitPreserveZoom
                guard key.read(from: config, into: &v) else { return .init() }
                return .init(rawValue: v)
            }

            var initialWindow: Bool {
                value(ConfigSchema.initialWindow, default: true)
            }

            var shouldQuitAfterLastWindowClosed: Bool {
                value(ConfigSchema.quitAfterLastWindowClosed, default: false, unloaded: true)
            }

            var title: String? {
                string(ConfigSchema.title)
            }

            var windowSaveState: String {
                string(ConfigSchema.windowSaveState) ?? ""
            }

            var windowNewTabPosition: String {
                string(ConfigSchema.windowNewTabPosition) ?? ""
            }

            var windowDecorations: Bool {
                let defaultValue = true
                guard let str = string(ConfigSchema.windowDecoration) else { return defaultValue }
                return Config.WindowDecoration(rawValue: str)?.enabled() ?? defaultValue
            }

            var windowTheme: String? {
                string(ConfigSchema.windowTheme)
            }

            var dragHandle: Config.DragHandle {
                let defaultValue = Config.DragHandle.auto
                guard let str = string(ConfigSchema.dragHandle) else { return defaultValue }
                return Config.DragHandle(rawValue: str) ?? defaultValue
            }

            /// Returns the fullscreen mode if fullscreen is enabled, or nil if disabled.
            /// This parses the `fullscreen` enum config which supports both
            /// native and non-native fullscreen modes.
            var windowFullscreen: FullscreenMode? {
                guard let str = string(ConfigSchema.fullscreen) else { return nil }
                return switch str {
                case "false":
                    nil
                case "true":
                    .native
                case "non-native":
                    .nonNative
                case "non-native-visible-menu":
                    .nonNativeVisibleMenu
                case "non-native-padded-notch":
                    .nonNativePaddedNotch
                default:
                    nil
                }
            }

            /// Returns the fullscreen mode for toggle actions (keybindings).
            /// This is controlled by `macos-non-native-fullscreen` config.
            var windowFullscreenMode: FullscreenMode {
                let defaultValue: FullscreenMode = .native
                guard let str = string(ConfigSchema.macosNonNativeFullscreen) else { return defaultValue }
                return switch str {
                case "false":
                        .native
                case "true":
                        .nonNative
                case "visible-menu":
                        .nonNativeVisibleMenu
                case "padded-notch":
                        .nonNativePaddedNotch
                default:
                    defaultValue
                }
            }

            var macosWindowButtons: MacOSWindowButtons {
                let defaultValue = MacOSWindowButtons.visible
                guard let str = string(ConfigSchema.macosWindowButtons) else { return defaultValue }
                return MacOSWindowButtons(rawValue: str) ?? defaultValue
            }

            var macosTitlebarStyle: Config.MacOSTitlebarStyle {
                let defaultValue = Config.MacOSTitlebarStyle.transparent
                guard let str = string(ConfigSchema.macosTitlebarStyle) else { return defaultValue }
                return Config.MacOSTitlebarStyle(rawValue: str) ?? defaultValue
            }

            var macosTitlebarProxyIcon: MacOSTitlebarProxyIcon {
                let defaultValue = MacOSTitlebarProxyIcon.visible
                guard let str = string(ConfigSchema.macosTitlebarProxyIcon) else { return defaultValue }
                return MacOSTitlebarProxyIcon(rawValue: str) ?? defaultValue
            }

            var macosDockDropBehavior: Config.MacDockDropBehavior {
                let defaultValue = Config.MacDockDropBehavior.new_tab
                guard let str = string(ConfigSchema.macosDockDropBehavior) else { return defaultValue }
                return Config.MacDockDropBehavior(rawValue: str) ?? defaultValue
            }

            var macosWindowShadow: Bool {
                value(ConfigSchema.macosWindowShadow, default: false)
            }

            var macosHidden: Config.MacHidden {
                guard let str = string(ConfigSchema.macosHidden) else { return .never }
                return Config.MacHidden(rawValue: str) ?? .never
            }

            var backgroundColor: Color {
                guard let config else { return Color(NSColor.windowBackgroundColor) }
                var color: ghostty_config_color_s = .init()
                let bg_key = ConfigSchema.background
                if !bg_key.read(from: config, into: &color) {
                    return Color(NSColor.windowBackgroundColor)
                }

                return .init(
                    red: Double(color.r) / 255,
                    green: Double(color.g) / 255,
                    blue: Double(color.b) / 255
                )
            }

            var backgroundOpacity: Double {
                value(ConfigSchema.backgroundOpacity, default: 1)
            }

            var backgroundBlur: Config.BackgroundBlur {
                guard let config = self.config else { return .disabled }
                var v: Int16 = 0
                let key = ConfigSchema.backgroundBlur
                _ = key.read(from: config, into: &v)
                return Config.BackgroundBlur(fromCValue: v)
            }

            var unfocusedSplitOpacity: Double {
                guard let config = self.config else { return 1 }
                var opacity: Double = 0.85
                let key = ConfigSchema.unfocusedSplitOpacity
                _ = key.read(from: config, into: &opacity)
                return 1 - opacity
            }

            var unfocusedSplitFill: Color {
                guard let config = self.config else { return .white }

                var color: ghostty_config_color_s = .init()
                let key = ConfigSchema.unfocusedSplitFill
                if !key.read(from: config, into: &color) {
                    let bg_key = ConfigSchema.background
                    _ = bg_key.read(from: config, into: &color)
                }

                return .init(
                    red: Double(color.r) / 255,
                    green: Double(color.g) / 255,
                    blue: Double(color.b) / 255
                )
            }

            var splitDividerColor: Color {
                let backgroundColor = NSColor(backgroundColor)
                let isLightBackground = backgroundColor.isLightColor
                let newColor = isLightBackground ? backgroundColor.darken(by: 0.08) : backgroundColor.darken(by: 0.4)

                guard let config = self.config else { return Color(newColor) }

                var color: ghostty_config_color_s = .init()
                let key = ConfigSchema.splitDividerColor
                if !key.read(from: config, into: &color) {
                    return Color(newColor)
                }

                return .init(
                    red: Double(color.r) / 255,
                    green: Double(color.g) / 255,
                    blue: Double(color.b) / 255
                )
            }

            var quickTerminalPosition: QuickTerminalPosition {
                guard let str = string(ConfigSchema.quickTerminalPosition) else { return .top }
                return QuickTerminalPosition(rawValue: str) ?? .top
            }

            var quickTerminalScreen: QuickTerminalScreen {
                guard let str = string(ConfigSchema.quickTerminalScreen) else { return .main }
                return QuickTerminalScreen(fromGhosttyConfig: str) ?? .main
            }

            var quickTerminalAnimationDuration: Double {
                value(ConfigSchema.quickTerminalAnimationDuration, default: 0.2)
            }

            var quickTerminalAutoHide: Bool {
                value(ConfigSchema.quickTerminalAutohide, default: true)
            }

            var quickTerminalSpaceBehavior: QuickTerminalSpaceBehavior {
                guard let str = string(ConfigSchema.quickTerminalSpaceBehavior) else { return .move }
                return QuickTerminalSpaceBehavior(fromGhosttyConfig: str) ?? .move
            }

            var quickTerminalSize: QuickTerminalSize {
                guard let config = self.config else { return QuickTerminalSize() }
                var v = ghostty_config_quick_terminal_size_s()
                let key = ConfigSchema.quickTerminalSize
                guard key.read(from: config, into: &v) else { return QuickTerminalSize() }
                return QuickTerminalSize(from: v)
            }

            var resizeOverlay: Config.ResizeOverlay {
                guard let str = string(ConfigSchema.resizeOverlay) else { return .after_first }
                return Config.ResizeOverlay(rawValue: str) ?? .after_first
            }

            var resizeOverlayPosition: Config.ResizeOverlayPosition {
                let defaultValue = Config.ResizeOverlayPosition.center
                guard let str = string(ConfigSchema.resizeOverlayPosition) else { return defaultValue }
                return Config.ResizeOverlayPosition(rawValue: str) ?? defaultValue
            }

            var resizeOverlayDuration: UInt {
                value(ConfigSchema.resizeOverlayDuration, default: 0, unloaded: 1000)
            }

            var undoTimeout: Duration {
                .milliseconds(value(ConfigSchema.undoTimeout, default: 0, unloaded: 5000))
            }

            var autoSecureInput: Bool {
                value(ConfigSchema.macosAutoSecureInput, default: false, unloaded: true)
            }

            var secureInputIndication: Bool {
                value(ConfigSchema.macosSecureInputIndication, default: false, unloaded: true)
            }

            var macosAppleScript: Bool {
                value(ConfigSchema.macosApplescript, default: false, unloaded: true)
            }

            var macosShortcuts: Config.MacShortcuts {
                let defaultValue = Config.MacShortcuts.ask
                guard let str = string(ConfigSchema.macosShortcuts) else { return defaultValue }
                return Config.MacShortcuts(rawValue: str) ?? defaultValue
            }

            var abnormalCommandExitRuntime: Duration {
                let defaultValue: Duration = .milliseconds(250)
                guard let config = self.config else { return defaultValue }
                var v: CUnsignedInt = 0
                let key = ConfigSchema.abnormalCommandExitRuntime
                guard key.read(from: config, into: &v) else { return defaultValue }
                return .milliseconds(v)
            }

            var scrollbar: Config.Scrollbar {
                let defaultValue = Config.Scrollbar.system
                guard let str = string(ConfigSchema.scrollbar) else { return defaultValue }
                return Config.Scrollbar(rawValue: str) ?? defaultValue
            }

            var commandPaletteEntries: [Ghostty.Command] {
                guard let config = self.config else { return [] }
                var v: ghostty_config_command_list_s = .init()
                let key = ConfigSchema.commandPaletteEntry
                guard key.read(from: config, into: &v) else { return [] }
                guard v.len > 0 else { return [] }
                let buffer = UnsafeBufferPointer(start: v.commands, count: v.len)
                return buffer.map { Ghostty.Command(cValue: $0) }
            }

            var progressStyle: Bool {
                value(ConfigSchema.progressStyle, default: true)
            }
        }
    }
}
