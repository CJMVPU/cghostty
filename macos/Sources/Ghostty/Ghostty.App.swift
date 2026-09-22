import SwiftUI
import Observation
import UniformTypeIdentifiers
import UserNotifications
import GhosttyKit
import AppKit

protocol GhosttyAppDelegate: AnyObject {
    /// Called when a callback needs access to a specific surface. This should return nil
    /// when the surface is no longer valid.
    func findSurface(forUUID uuid: UUID) -> Ghostty.SurfaceView?
}

extension Ghostty {
    @MainActor @Observable final class App {
        enum Readiness: String {
            case loading, error, ready
        }

        /// Optional delegate
        @ObservationIgnored weak var delegate: GhosttyAppDelegate?

        /// The readiness value of the state.
        var readiness: Readiness = .loading

        /// The global app configuration. This defines the app level configuration plus any behavior
        /// for new windows, tabs, etc. Note that when creating a new window, it may inherit some
        /// configuration (i.e. font size) from the previously focused window. This would override this.
        private(set) var config: Config

        /// Weak topology lookup, separate from loaded-window retention.
        @ObservationIgnored let windowRegistry = WindowRegistry()
        @ObservationIgnored let undoManager = ExpiringUndoManager()

        /// Preferred config file than the default ones
        @ObservationIgnored private var configPath: String?
        @ObservationIgnored private var configurationStore: ConfigStore?
        private(set) var startupConfigurationErrors: [String] = []
        /// The ghostty app instance. We only have one of these for the entire app, although I guess
        /// in theory you can have multiple... I don't know why you would...
        @ObservationIgnored private(set) var app: ghostty_app_t? {
            didSet {
                guard let old = oldValue else { return }
                ghostty_app_free(old)
            }
        }

        /// True if we need to confirm before quitting.
        var needsConfirmQuit: Bool {
            guard let app = app else { return false }
            return ghostty_app_needs_confirm_quit(app)
        }

        init(configPath: String? = nil) {
            self.configPath = configPath
            // Initialize the global configuration.
            if configPath == "/dev/null" {
                self.config = Config(at: configPath)
            } else {
                let path = configPath ?? ConfigHandle.defaultPath
                let source = URL(fileURLWithPath: path)
                let directory = configPath == nil ? nil : source.deletingLastPathComponent()
                    .appendingPathComponent(".config-state-" + source.lastPathComponent)
                let store = ConfigStore(source: source, directory: directory)
                self.configurationStore = store
                self.config = Config(handle: store.load())
                self.startupConfigurationErrors = self.config.errors
            }
            if self.config.config == nil {
                readiness = .error
                return
            }

            // Create our "runtime" config. The "runtime" is the configuration that ghostty
            // uses to interface with the application runtime environment.
            var runtime_cfg = ghostty_runtime_config_s(
                userdata: Unmanaged.passUnretained(self).toOpaque(),
                supports_selection_clipboard: true,
                wakeup_cb: { @Sendable userdata in App.wakeup(userdata) },
                action_cb: { app, target, action in App.action(app!, target: target, action: action) },
                read_clipboard_cb: { userdata, loc, state, mimes, mimesLen, list in
                    App.readClipboard(
                        userdata,
                        location: loc,
                        state: state,
                        mimes: mimes,
                        mimesLen: mimesLen,
                        list: list) },
                confirm_read_clipboard_cb: { userdata, confirm, state, request in
                    App.confirmReadClipboard(
                        userdata,
                        confirm: confirm,
                        state: state,
                        request: request) },
                write_clipboard_cb: { userdata, loc, content, len, confirm in
                    App.writeClipboard(userdata, location: loc, content: content, len: len, confirm: confirm) },
                close_surface_cb: { userdata, processAlive in App.closeSurface(userdata, processAlive: processAlive) }
            )

            // Create the ghostty app.
            guard let app = ghostty_app_new(&runtime_cfg, config.config) else {
                logger.critical("ghostty_app_new failed")
                readiness = .error
                return
            }
            self.app = app
            // Set our initial focus state
            ghostty_app_set_focus(app, NSApp.isActive)

            let center = NotificationCenter.default
            center.addObserver(
                self,
                selector: #selector(keyboardSelectionDidChange(notification:)),
                name: NSTextInputContext.keyboardSelectionDidChangeNotification,
                object: nil)
            center.addObserver(
                self,
                selector: #selector(applicationDidBecomeActive(notification:)),
                name: NSApplication.didBecomeActiveNotification,
                object: nil)
            center.addObserver(
                self,
                selector: #selector(applicationDidResignActive(notification:)),
                name: NSApplication.didResignActiveNotification,
                object: nil)
            self.readiness = .ready
        }

        isolated deinit {
            // This will force the didSet callbacks to run which free.
            self.app = nil
            NotificationCenter.default.removeObserver(self)
        }

        func acceptConfiguration(_ config: Config) {
            self.config = config
            windowRegistry.registeredControllers.forEach { $0.acceptConfiguration(config) }
            (delegate as? AppDelegate)?.acceptConfiguration(config)
        }

        var isReady: Bool { app != nil }

        var hasGlobalKeyBindings: Bool {
            guard let app else { return false }
            return ghostty_app_has_global_keybinds(app)
        }

        @discardableResult
        func sendKeyEvent(_ event: Input.KeyEvent, onlyIfBinding: Bool = false) -> Bool {
            guard let app else { return false }
            return event.withCValue { value in
                if onlyIfBinding {
                    guard let config = config.config, ghostty_config_key_is_binding(config, value) else { return false }
                }
                return ghostty_app_key(app, value)
            }
        }

        func setColorScheme(dark: Bool) {
            guard let app else { return }
            ghostty_app_set_color_scheme(app, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
        }

        func applyBackgroundBlur(to window: NSWindow) {
            guard let app else { return }
            ghostty_set_window_background_blur(app, Unmanaged.passUnretained(window).toOpaque())
        }

        func makeSurface(view: SurfaceView, configuration: SurfaceConfiguration) -> Surface? {
            guard let app else { return nil }
            let context = SurfaceCallbackContext(view: view)
            return configuration.withCValue(view: view, callbackContext: context) { value in
                guard let handle = ghostty_surface_new(app, &value) else { return nil }
                return Surface(cSurface: handle, app: self, callbackContext: context)
            }
        }

        // MARK: App Operations

        func appTick() {
            guard let app = self.app else { return }
            ghostty_app_tick(app)
        }

        static func openConfig(_ app: ghostty_app_t) {
            guard let app_ud = ghostty_app_userdata(app) else { return }
            let app = Unmanaged<App>.fromOpaque(app_ud).takeUnretainedValue()
            app.openConfig()
        }

        func openConfig() {
            let str = ConfigHandle.prepareForEditing(at: configPath)
            guard !str.isEmpty else {
                let alert = NSAlert()
                alert.messageText = "无法打开配置 / Could Not Open Settings"
                alert.informativeText = "无法准备配置文件。请检查文件路径和写入权限后重试。\nCould not prepare the configuration file. Check its path and write permissions, then try again."
                alert.runModal()
                return
            }
            let fileURL = URL(fileURLWithPath: str).absoluteString
            var action = ghostty_action_open_url_s()
            action.kind = GHOSTTY_ACTION_OPEN_URL_KIND_TEXT
            fileURL.withCString { cStr in
                action.url = cStr
                action.len = UInt(fileURL.count)
                _ = App.openURL(action)
            }
        }

        /// Reload the configuration.
        func reloadConfig(soft: Bool = false) {
            guard let app = self.app else { return }

            // Soft updates just call with our existing config
            if soft {
                ghostty_app_update_config(app, config.config!)
                return
            }

            // User file changes apply on the next application launch only.
            Ghostty.logger.notice("Configuration changes require an application restart")
        }

        func reloadConfig(surface: Surface, soft: Bool = false) {
            if soft { surface.updateConfig(config) } else { Ghostty.logger.notice("Configuration changes require an application restart") }
        }

        @discardableResult
        func restoreDefaultSettings() throws -> URL? {
            guard let configurationStore else { return nil }
            return try configurationStore.restoreDefaults()
        }

        // MARK: Notifications

        // Called when the selected keyboard changes. We have to notify Ghostty so that
        // it can reload the keyboard mapping for input.
        @objc private func keyboardSelectionDidChange(notification: NSNotification) {
            guard let app = self.app else { return }
            ghostty_app_keyboard_changed(app)
        }

        // Called when the app becomes active.
        @objc private func applicationDidBecomeActive(notification: NSNotification) {
            guard let app = self.app else { return }
            ghostty_app_set_focus(app, true)
            for controller in windowRegistry.windowControllers {
                for surface in controller.surfaceTree { surface.searchState?.readPasteboardNeedle() }
            }
        }

        // Called when the app becomes inactive.
        @objc private func applicationDidResignActive(notification: NSNotification) {
            guard let app = self.app else { return }
            ghostty_app_set_focus(app, false)
        }

        /// Determine if a given notification should be presented to the user when Ghostty is running in the foreground.
        func shouldPresentNotification(notification: UNNotification) -> Bool {
            let userInfo = notification.request.content.userInfo

            // We always require the notification to be attached to a surface.
            guard let uuidString = userInfo["surface"] as? String,
                  let uuid = UUID(uuidString: uuidString),
                  let surface = windowRegistry.surface(id: uuid),
                  let window = surface.window else { return false }

            // If we don't require focus then we're good!
            let requireFocus = userInfo["requireFocus"] as? Bool ?? true
            if !requireFocus { return true }

            return !window.isKeyWindow || !surface.focused
        }

        // MARK: User Notifications

        /// Handle a received user notification. This is called when a user notification is clicked or dismissed by the user
        func handleUserNotification(response: UNNotificationResponse) {
            let userInfo = response.notification.request.content.userInfo
            guard let uuidString = userInfo["surface"] as? String,
                  let uuid = UUID(uuidString: uuidString),
                  let surface = windowRegistry.surface(id: uuid) else { return }

            switch response.actionIdentifier {
            case UNNotificationDefaultActionIdentifier, Ghostty.userNotificationActionShow:
                // The user clicked on a notification
                surface.handleUserNotification(notification: response.notification, focus: true)
            case UNNotificationDismissActionIdentifier:
                // The user dismissed the notification
                surface.handleUserNotification(notification: response.notification, focus: false)
            default:
                break
            }
        }
    }
}
