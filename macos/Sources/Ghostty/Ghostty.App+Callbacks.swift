import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import GhosttyKit
import AppKit

// Borrowed C callback values are decoded/copied here before dispatch to native UI.
// Core invokes these callbacks synchronously on the main actor, except wakeup.
extension Ghostty.App {
    // MARK: Ghostty Callbacks (macOS)

    nonisolated static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
        guard let userdata else { return }
        let state = Unmanaged<Ghostty.App>.fromOpaque(userdata).takeUnretainedValue()

        guard state.wakeupGate.request() else { return }
        // Clear before draining: a producer racing with the drain can queue
        // the next tick. Keep the owner weak during teardown.
        DispatchQueue.main.async { [weak state] in
            guard let state else { return }
            state.wakeupGate.beginTick()
            state.appTick()
        }
    }

    /// Returns the GhosttyState from the given userdata value.
    static func appState(fromView view: Ghostty.SurfaceView) -> Ghostty.App? {
        guard let surface = view.surfaceModel?.unsafeCValue else { return nil }
        guard let app = ghostty_surface_app(surface) else { return nil }
        return appState(from: app)
    }

    static func appState(from app: ghostty_app_t) -> Ghostty.App? {
        guard let app_ud = ghostty_app_userdata(app) else { return nil }
        return Unmanaged<Ghostty.App>.fromOpaque(app_ud).takeUnretainedValue()
    }

    static func surfaceContext(from userdata: UnsafeMutableRawPointer?) -> Ghostty.SurfaceCallbackContext? {
        guard let userdata else { return nil }
        return Unmanaged<Ghostty.SurfaceCallbackContext>.fromOpaque(userdata).takeUnretainedValue()
    }

    static func surfaceUserdata(from userdata: UnsafeMutableRawPointer?) -> Ghostty.SurfaceView? {
        surfaceContext(from: userdata)?.view
    }

    static func surfaceView(from surface: ghostty_surface_t) -> Ghostty.SurfaceView? {
        surfaceUserdata(from: ghostty_surface_userdata(surface))
    }

    /// Decode surface-only action targets once; callers keep their own handling
    /// result and payload semantics. Borrowed payloads stay in this synchronous call.
    static func surfaceView(for target: ghostty_target_s, action: String = #function) -> Ghostty.SurfaceView? {
        guard target.tag == GHOSTTY_TARGET_SURFACE else {
            Ghostty.logger.warning("\(action, privacy: .public) requires a surface target")
            return nil
        }
        guard let surface = target.target.surface else { return nil }
        return surfaceView(from: surface)
    }

    // MARK: Actions (macOS)

    static func action(_ app: ghostty_app_t, target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        // Make sure it a target we understand so all our action handlers can assert
        switch target.tag {
        case GHOSTTY_TARGET_APP, GHOSTTY_TARGET_SURFACE:
            break

        default:
            Ghostty.logger.warning("unknown action target=\(target.tag.rawValue, privacy: .public)")
            return false
        }

        // Ghostty.Action dispatch
        switch action.tag {
        case GHOSTTY_ACTION_QUIT:
            quit(app)

        case GHOSTTY_ACTION_NEW_WINDOW:
            newWindow(app, target: target)

        case GHOSTTY_ACTION_NEW_TAB:
            newTab(app, target: target)

        case GHOSTTY_ACTION_NEW_SPLIT:
            newSplit(app, target: target, direction: action.action.new_split)

        case GHOSTTY_ACTION_CLOSE_TAB:
            closeTab(app, target: target, mode: action.action.close_tab_mode)

        case GHOSTTY_ACTION_CLOSE_WINDOW:
            closeWindow(app, target: target)

        case GHOSTTY_ACTION_TOGGLE_FULLSCREEN:
            toggleFullscreen(app, target: target, mode: action.action.toggle_fullscreen)

        case GHOSTTY_ACTION_MOVE_TAB:
            return moveTab(app, target: target, move: action.action.move_tab)

        case GHOSTTY_ACTION_MOVE_TAB_TO_NEW_WINDOW:
            return moveTabToNewWindow(app, target: target)

        case GHOSTTY_ACTION_GOTO_TAB:
            return gotoTab(app, target: target, tab: action.action.goto_tab)

        case GHOSTTY_ACTION_GOTO_SPLIT:
            return gotoSplit(app, target: target, direction: action.action.goto_split)

        case GHOSTTY_ACTION_GOTO_WINDOW:
            return gotoWindow(app, target: target, direction: action.action.goto_window)

        case GHOSTTY_ACTION_RESIZE_SPLIT:
            return resizeSplit(app, target: target, resize: action.action.resize_split)

        case GHOSTTY_ACTION_EQUALIZE_SPLITS:
            equalizeSplits(app, target: target)

        case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
            return toggleSplitZoom(app, target: target)

        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            showDesktopNotification(app, target: target, n: action.action.desktop_notification)

        case GHOSTTY_ACTION_SET_TITLE:
            setTitle(app, target: target, v: action.action.set_title)

        case GHOSTTY_ACTION_SET_TAB_TITLE:
            return setTabTitle(app, target: target, v: action.action.set_tab_title)

        case GHOSTTY_ACTION_PROMPT_TITLE:
            return promptTitle(app, target: target, v: action.action.prompt_title)

        case GHOSTTY_ACTION_PWD:
            pwdChanged(app, target: target, v: action.action.pwd)

        case GHOSTTY_ACTION_OPEN_CONFIG:
            openConfig(app)

        case GHOSTTY_ACTION_FLOAT_WINDOW:
            toggleFloatWindow(app, target: target, mode: action.action.float_window)

        case GHOSTTY_ACTION_SECURE_INPUT:
            toggleSecureInput(app, target: target, mode: action.action.secure_input)

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            setMouseShape(app, target: target, shape: action.action.mouse_shape)

        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            setMouseVisibility(app, target: target, v: action.action.mouse_visibility)

        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            setMouseOverLink(app, target: target, v: action.action.mouse_over_link)

        case GHOSTTY_ACTION_INITIAL_SIZE:
            setInitialSize(app, target: target, v: action.action.initial_size)

        case GHOSTTY_ACTION_RESET_WINDOW_SIZE:
            resetWindowSize(app, target: target)

        case GHOSTTY_ACTION_CELL_SIZE:
            setCellSize(app, target: target, v: action.action.cell_size)

        case GHOSTTY_ACTION_RENDERER_HEALTH:
            rendererHealth(app, target: target, v: action.action.renderer_health)

        case GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE:
            toggleCommandPalette(app, target: target)

        case GHOSTTY_ACTION_TOGGLE_MAXIMIZE:
            toggleMaximize(app, target: target)

        case GHOSTTY_ACTION_TOGGLE_QUICK_TERMINAL:
            toggleQuickTerminal(app, target: target)

        case GHOSTTY_ACTION_TOGGLE_VISIBILITY:
            toggleVisibility(app, target: target)

        case GHOSTTY_ACTION_TOGGLE_BACKGROUND_OPACITY:
            toggleBackgroundOpacity(app, target: target)

        case GHOSTTY_ACTION_KEY_SEQUENCE:
            keySequence(app, target: target, v: action.action.key_sequence)

        case GHOSTTY_ACTION_KEY_TABLE:
            keyTable(app, target: target, v: action.action.key_table)

        case GHOSTTY_ACTION_PROGRESS_REPORT:
            progressReport(app, target: target, v: action.action.progress_report)

        case GHOSTTY_ACTION_CONFIG_CHANGE:
            configChange(app, target: target, v: action.action.config_change)

        case GHOSTTY_ACTION_APPLY_THEME:
            applyTheme(app, target: target)

        case GHOSTTY_ACTION_COLOR_CHANGE:
            colorChange(app, target: target, change: action.action.color_change)

        case GHOSTTY_ACTION_RING_BELL:
            ringBell(app, target: target)

        case GHOSTTY_ACTION_SELECTION_CHANGED:
            selectionChanged(app, target: target)

        case GHOSTTY_ACTION_READONLY:
            setReadonly(app, target: target, v: action.action.readonly)

        case GHOSTTY_ACTION_CHECK_FOR_UPDATES:
            checkForUpdates(app)

        case GHOSTTY_ACTION_OPEN_URL:
            return openURL(action.action.open_url)

        case GHOSTTY_ACTION_UNDO:
            return undo(app, target: target)

        case GHOSTTY_ACTION_REDO:
            return redo(app, target: target)

        case GHOSTTY_ACTION_SCROLLBAR:
            scrollbar(app, target: target, v: action.action.scrollbar)

        case GHOSTTY_ACTION_CLOSE_ALL_WINDOWS:
            closeAllWindows(app, target: target)

        case GHOSTTY_ACTION_START_SEARCH:
            startSearch(app, target: target, v: action.action.start_search)

        case GHOSTTY_ACTION_END_SEARCH:
            return endSearch(app, target: target)

        case GHOSTTY_ACTION_SEARCH_TOTAL:
            searchTotal(app, target: target, v: action.action.search_total)

        case GHOSTTY_ACTION_SEARCH_SELECTED:
            searchSelected(app, target: target, v: action.action.search_selected)

        case GHOSTTY_ACTION_COMMAND_FINISHED:
            commandFinished(app, target: target, v: action.action.command_finished)

        case GHOSTTY_ACTION_PRESENT_TERMINAL:
            return presentTerminal(app, target: target)

        case GHOSTTY_ACTION_SURFACE_FAULT:
            return showSurfaceFault(target: target, value: action.action.surface_fault)

        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            return showChildExited(app, target: target, v: action.action.child_exited)

        case GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD:
            return copyTitleToClipboard(app, target: target)

        default:
            Ghostty.logger.warning("unknown action action=\(action.tag.rawValue, privacy: .public)")
            return false
        }

        // If we reached here then we assume performed since all unknown actions
        // are captured in the switch and return false.
        return true
    }

    private static func quit(_ app: ghostty_app_t) {
        // We want to quit, start that process
        NSApplication.shared.terminate(nil)
    }

    private static func checkForUpdates(
        _ app: ghostty_app_t
    ) {
        if let appDelegate = appState(from: app)?.delegate as? AppDelegate {
            appDelegate.checkForUpdates(nil)
        }
    }

    static func openURL(
        _ v: ghostty_action_open_url_s
    ) -> Bool {
        let action = Ghostty.Action.OpenURL(c: v)

        // OSC 8 targets are producer-controlled terminal output. Keep them
        // out of the unrestricted generic opener so unsafe local files and
        // deceptive targets cannot reach Launch Services directly.
        if action.kind == .osc8 {
            return openUntrustedURL(action.url)
        }

        // If the URL doesn't have a valid scheme we assume its a file path. The URL
        // initializer will gladly take invalid URLs (e.g. plain file paths) and turn
        // them into schema-less URLs, but these won't open properly in text editors.
        // See: https://github.com/ghostty-org/ghostty/issues/8763
        let url: URL
        if let candidate = URL(string: action.url), candidate.scheme != nil {
            url = candidate
        } else {
            // Expand ~ to the user's home directory so that file paths
            // like ~/Documents/file.txt resolve correctly.
            let expandedPath = NSString(string: action.url).standardizingPath
            url = URL(filePath: expandedPath)
        }

        switch action.kind {
        case .text:
            // Open with the default editor for `*.ghostty` file or just system text editor
            let editor = NSWorkspace.shared.defaultApplicationURL(forExtension: url.pathExtension) ?? NSWorkspace.shared.defaultTextEditor
            if let textEditor = editor {
                NSWorkspace.shared.open([url], withApplicationAt: textEditor, configuration: NSWorkspace.OpenConfiguration())
                return true
            }

        case .html:
            // The extension will be HTML and we do the right thing automatically.
            break

        case .unknown:
            break

        case .osc8:
            assertionFailure("OSC 8 URLs must use the safe-opening policy")
            return true
        }

        // Open with the default application for the URL
        NSWorkspace.shared.open(url)
        return true
    }

    private static func openUntrustedURL(_ value: String) -> Bool {
        let target = UntrustedURL(value)
        switch target.decision {
        case .allow(let url):
            _ = NSWorkspace.shared.open(url)

        case .confirm(let url):
            UntrustedURLAlert.presentConfirmation(
                for: url,
                displayString: target.displayString
            )

        case .deny(let reason):
            UntrustedURLAlert.presentBlock(
                reason: reason,
                displayString: target.displayString
            )
        }

        // Always report OSC 8 actions as handled. Returning false would
        // cause the core to retry with the unrestricted fallback opener.
        return true
    }

    private static func showDesktopNotification(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        n: ghostty_action_desktop_notification_s) {
        guard let surfaceView = self.surfaceView(for: target) else { return }
        guard let title = String(cString: n.title!, encoding: .utf8) else { return }
        guard let body = String(cString: n.body!, encoding: .utf8) else { return }
        showDesktopNotification(surfaceView, title: title, body: body)
    }

    private static func showDesktopNotification(
        _ surfaceView: Ghostty.SurfaceView,
        title: String,
        body: String,
        requireFocus: Bool = true) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error = error {
                Ghostty.logger.error("Error while requesting notification authorization: \(error, privacy: .public)")
            }
        }

        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            DispatchQueue.main.async {
                surfaceView.showUserNotification(
                    title: title,
                    body: body,
                    requireFocus: requireFocus
                )
            }
        }
    }

    private static func commandFinished(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_action_command_finished_s
    ) {
        guard let surfaceView = self.surfaceView(for: target) else { return }

        // Determine if we even care about command finish notifications
        guard let config = appState(from: app)?.config else { return }
        switch config.notifyOnCommandFinish {
        case .never:
            return

        case .unfocused:
            if surfaceView.focused { return }

        case .always:
            break
        }

        // Determine if the command was slow enough
        let duration = Duration.nanoseconds(v.duration)
        guard Duration.nanoseconds(v.duration) >= config.notifyOnCommandFinishAfter else { return }

        let actions = config.notifyOnCommandFinishAction

        if actions.contains(.bell) {
            surfaceView.ringBell()
        }

        if actions.contains(.notify) {
            let title: String
            if v.exit_code < 0 {
                title = "Command Finished"
            } else if v.exit_code == 0 {
                title = "Command Succeeded"
            } else {
                title = "Command Failed"
            }

            let body: String
            let formattedDuration = duration.formatted(
                .units(
                    allowed: [.hours, .minutes, .seconds, .milliseconds],
                    width: .abbreviated,
                    fractionalPart: .hide
                )
            )
            if v.exit_code < 0 {
                body = "Command took \(formattedDuration)."
            } else {
                body = "Command took \(formattedDuration) and exited with code \(v.exit_code)."
            }

            showDesktopNotification(
                surfaceView,
                title: title,
                body: body,
                requireFocus: false
            )
        }
    }

}
