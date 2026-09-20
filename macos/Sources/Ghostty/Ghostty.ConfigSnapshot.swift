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
                guard let config = self.config else { return 0.5 }
                var v: Double = 0.5
                let key = ConfigSchema.bellAudioVolume
                _ = key.read(from: config, into: &v)
                return Float(v)
            }

            var notifyOnCommandFinish: Config.NotifyOnCommandFinish {
                guard let config = self.config else { return .never }
                var v: UnsafePointer<Int8>?
                let key = ConfigSchema.notifyOnCommandFinish
                guard key.read(from: config, into: &v) else { return .never }
                guard let ptr = v else { return .never }
                return Config.NotifyOnCommandFinish(rawValue: String(cString: ptr)) ?? .never
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
                guard let config = self.config else { return .seconds(5) }
                var v: UInt = 0
                let key = ConfigSchema.notifyOnCommandFinishAfter
                _ = key.read(from: config, into: &v)
                return .milliseconds(v)
            }

            var splitPreserveZoom: Config.SplitPreserveZoom {
                guard let config = self.config else { return .init() }
                var v: CUnsignedInt = 0
                let key = ConfigSchema.splitPreserveZoom
                guard key.read(from: config, into: &v) else { return .init() }
                return .init(rawValue: v)
            }

            var initialWindow: Bool {
                guard let config = self.config else { return true }
                var v = true
                let key = ConfigSchema.initialWindow
                _ = key.read(from: config, into: &v)
                return v
            }

            var shouldQuitAfterLastWindowClosed: Bool {
                guard let config = self.config else { return true }
                var v = false
                let key = ConfigSchema.quitAfterLastWindowClosed
                _ = key.read(from: config, into: &v)
                return v
            }

            var title: String? {
                guard let config = self.config else { return nil }
                var v: UnsafePointer<Int8>?
                let key = ConfigSchema.title
                guard key.read(from: config, into: &v) else { return nil }
                guard let ptr = v else { return nil }
                return String(cString: ptr)
            }

            var windowSaveState: String {
                guard let config = self.config else { return "" }
                var v: UnsafePointer<Int8>?
                let key = ConfigSchema.windowSaveState
                guard key.read(from: config, into: &v) else { return "" }
                guard let ptr = v else { return "" }
                return String(cString: ptr)
            }

            var windowNewTabPosition: String {
                guard let config = self.config else { return "" }
                var v: UnsafePointer<Int8>?
                let key = ConfigSchema.windowNewTabPosition
                guard key.read(from: config, into: &v) else { return "" }
                guard let ptr = v else { return "" }
                return String(cString: ptr)
            }

            var windowDecorations: Bool {
                let defaultValue = true
                guard let config = self.config else { return defaultValue }
                var v: UnsafePointer<Int8>?
                let key = ConfigSchema.windowDecoration
                guard key.read(from: config, into: &v) else { return defaultValue }
                guard let ptr = v else { return defaultValue }
                let str = String(cString: ptr)
                return Config.WindowDecoration(rawValue: str)?.enabled() ?? defaultValue
            }

            var windowTheme: String? {
                guard let config = self.config else { return nil }
                var v: UnsafePointer<Int8>?
                let key = ConfigSchema.windowTheme
                guard key.read(from: config, into: &v) else { return nil }
                guard let ptr = v else { return nil }
                return String(cString: ptr)
            }

            var dragHandle: Config.DragHandle {
                let defaultValue = Config.DragHandle.auto
                guard let config = self.config else { return defaultValue }
                var v: UnsafePointer<Int8>?
                let key = ConfigSchema.dragHandle
                guard key.read(from: config, into: &v) else { return defaultValue }
                guard let ptr = v else { return defaultValue }
                return Config.DragHandle(rawValue: String(cString: ptr)) ?? defaultValue
            }

            /// Returns the fullscreen mode if fullscreen is enabled, or nil if disabled.
            /// This parses the `fullscreen` enum config which supports both
            /// native and non-native fullscreen modes.
            var windowFullscreen: FullscreenMode? {
                guard let config = self.config else { return nil }
                var v: UnsafePointer<Int8>?
                let key = ConfigSchema.fullscreen
                guard key.read(from: config, into: &v) else { return nil }
                guard let ptr = v else { return nil }
                let str = String(cString: ptr)
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
                guard let config = self.config else { return defaultValue }
                var v: UnsafePointer<Int8>?
                let key = ConfigSchema.macosNonNativeFullscreen
                guard key.read(from: config, into: &v) else { return defaultValue }
                guard let ptr = v else { return defaultValue }
                let str = String(cString: ptr)
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
                guard let config = self.config else { return defaultValue }
                var v: UnsafePointer<Int8>?
                let key = ConfigSchema.macosWindowButtons
                guard key.read(from: config, into: &v) else { return defaultValue }
                guard let ptr = v else { return defaultValue }
                let str = String(cString: ptr)
                return MacOSWindowButtons(rawValue: str) ?? defaultValue
            }

            var macosTitlebarStyle: Config.MacOSTitlebarStyle {
                let defaultValue = Config.MacOSTitlebarStyle.transparent
                guard let config = self.config else { return defaultValue }
                var v: UnsafePointer<Int8>?
                let key = ConfigSchema.macosTitlebarStyle
                guard key.read(from: config, into: &v) else { return defaultValue }
                guard let ptr = v else { return defaultValue }
                return Config.MacOSTitlebarStyle(rawValue: String(cString: ptr)) ?? defaultValue
            }

            var macosTitlebarProxyIcon: MacOSTitlebarProxyIcon {
                let defaultValue = MacOSTitlebarProxyIcon.visible
                guard let config = self.config else { return defaultValue }
                var v: UnsafePointer<Int8>?
                let key = ConfigSchema.macosTitlebarProxyIcon
                guard key.read(from: config, into: &v) else { return defaultValue }
                guard let ptr = v else { return defaultValue }
                let str = String(cString: ptr)
                return MacOSTitlebarProxyIcon(rawValue: str) ?? defaultValue
            }

            var macosDockDropBehavior: Config.MacDockDropBehavior {
                let defaultValue = Config.MacDockDropBehavior.new_tab
                guard let config = self.config else { return defaultValue }
                var v: UnsafePointer<Int8>?
                let key = ConfigSchema.macosDockDropBehavior
                guard key.read(from: config, into: &v) else { return defaultValue }
                guard let ptr = v else { return defaultValue }
                let str = String(cString: ptr)
                return Config.MacDockDropBehavior(rawValue: str) ?? defaultValue
            }

            var macosWindowShadow: Bool {
                guard let config = self.config else { return false }
                var v = false
                let key = ConfigSchema.macosWindowShadow
                _ = key.read(from: config, into: &v)
                return v
            }

            var macosHidden: Config.MacHidden {
                guard let config = self.config else { return .never }
                var v: UnsafePointer<Int8>?
                let key = ConfigSchema.macosHidden
                guard key.read(from: config, into: &v) else { return .never }
                guard let ptr = v else { return .never }
                let str = String(cString: ptr)
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
                guard let config = self.config else { return 1 }
                var v: Double = 1
                let key = ConfigSchema.backgroundOpacity
                _ = key.read(from: config, into: &v)
                return v
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
                guard let config = self.config else { return .top }
                var v: UnsafePointer<Int8>?
                let key = ConfigSchema.quickTerminalPosition
                guard key.read(from: config, into: &v) else { return .top }
                guard let ptr = v else { return .top }
                let str = String(cString: ptr)
                return QuickTerminalPosition(rawValue: str) ?? .top
            }

            var quickTerminalScreen: QuickTerminalScreen {
                guard let config = self.config else { return .main }
                var v: UnsafePointer<Int8>?
                let key = ConfigSchema.quickTerminalScreen
                guard key.read(from: config, into: &v) else { return .main }
                guard let ptr = v else { return .main }
                let str = String(cString: ptr)
                return QuickTerminalScreen(fromGhosttyConfig: str) ?? .main
            }

            var quickTerminalAnimationDuration: Double {
                guard let config = self.config else { return 0.2 }
                var v: Double = 0.2
                let key = ConfigSchema.quickTerminalAnimationDuration
                _ = key.read(from: config, into: &v)
                return v
            }

            var quickTerminalAutoHide: Bool {
                guard let config = self.config else { return true }
                var v = true
                let key = ConfigSchema.quickTerminalAutohide
                _ = key.read(from: config, into: &v)
                return v
            }

            var quickTerminalSpaceBehavior: QuickTerminalSpaceBehavior {
                guard let config = self.config else { return .move }
                var v: UnsafePointer<Int8>?
                let key = ConfigSchema.quickTerminalSpaceBehavior
                guard key.read(from: config, into: &v) else { return .move }
                guard let ptr = v else { return .move }
                let str = String(cString: ptr)
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
                guard let config = self.config else { return .after_first }
                var v: UnsafePointer<Int8>?
                let key = ConfigSchema.resizeOverlay
                guard key.read(from: config, into: &v) else { return .after_first }
                guard let ptr = v else { return .after_first }
                let str = String(cString: ptr)
                return Config.ResizeOverlay(rawValue: str) ?? .after_first
            }

            var resizeOverlayPosition: Config.ResizeOverlayPosition {
                let defaultValue = Config.ResizeOverlayPosition.center
                guard let config = self.config else { return defaultValue }
                var v: UnsafePointer<Int8>?
                let key = ConfigSchema.resizeOverlayPosition
                guard key.read(from: config, into: &v) else { return defaultValue }
                guard let ptr = v else { return defaultValue }
                let str = String(cString: ptr)
                return Config.ResizeOverlayPosition(rawValue: str) ?? defaultValue
            }

            var resizeOverlayDuration: UInt {
                guard let config = self.config else { return 1000 }
                var v: UInt = 0
                let key = ConfigSchema.resizeOverlayDuration
                _ = key.read(from: config, into: &v)
                return v
            }

            var undoTimeout: Duration {
                guard let config = self.config else { return .seconds(5) }
                var v: UInt = 0
                let key = ConfigSchema.undoTimeout
                _ = key.read(from: config, into: &v)
                return .milliseconds(v)
            }

            var autoSecureInput: Bool {
                guard let config = self.config else { return true }
                var v = false
                let key = ConfigSchema.macosAutoSecureInput
                _ = key.read(from: config, into: &v)
                return v
            }

            var secureInputIndication: Bool {
                guard let config = self.config else { return true }
                var v = false
                let key = ConfigSchema.macosSecureInputIndication
                _ = key.read(from: config, into: &v)
                return v
            }

            var macosAppleScript: Bool {
                guard let config = self.config else { return true }
                var v = false
                let key = ConfigSchema.macosApplescript
                _ = key.read(from: config, into: &v)
                return v
            }

            var macosShortcuts: Config.MacShortcuts {
                let defaultValue = Config.MacShortcuts.ask
                guard let config = self.config else { return defaultValue }
                var v: UnsafePointer<Int8>?
                let key = ConfigSchema.macosShortcuts
                guard key.read(from: config, into: &v) else { return defaultValue }
                guard let ptr = v else { return defaultValue }
                let str = String(cString: ptr)
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
                guard let config = self.config else { return defaultValue }
                var v: UnsafePointer<Int8>?
                let key = ConfigSchema.scrollbar
                guard key.read(from: config, into: &v) else { return defaultValue }
                guard let ptr = v else { return defaultValue }
                let str = String(cString: ptr)
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
                guard let config = self.config else { return true }
                var v = true
                let key = ConfigSchema.progressStyle
                _ = key.read(from: config, into: &v)
                return v
            }
        }
    }
}
