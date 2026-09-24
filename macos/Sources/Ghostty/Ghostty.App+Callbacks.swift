import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import GhosttyKit
import AppKit

// Borrowed C callback values are decoded/copied here before dispatch to native UI.
// Core invokes these callbacks synchronously on the main actor, except wakeup.
extension Ghostty.App {
    // MARK: Ghostty Callbacks (macOS)

    static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
        guard let surface = self.surfaceUserdata(from: userdata) else { return }
        surface.windowRegistry.owner(of: surface)?.closeSurface(surface, withConfirmation: processAlive)
    }

    static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?,
        mimes: UnsafePointer<UnsafePointer<CChar>?>?,
        mimesLen: Int,
        list: Bool
    ) -> ghostty_clipboard_read_result_e {
        guard let surfaceView = self.surfaceUserdata(from: userdata),
              let surface = surfaceView.surfaceModel else {
            return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
        }

        // Get our pasteboard
        guard let pasteboard = NSPasteboard.ghostty(location) else {
            return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
        }

        // Gather the representation for each requested MIME type that
        // the pasteboard can serve. We only ever read the requested
        // representations so unrelated (potentially large) clipboard
        // contents are never loaded.
        var contents: [Ghostty.ClipboardContent] = []
        var seen = Set<String>()
        if let mimes {
            for i in 0..<mimesLen {
                guard let ptr = mimes[i] else { continue }
                let mime = String(cString: ptr)
                guard !seen.contains(mime) else { continue }
                seen.insert(mime)
                guard let data = pasteboard.ghosttyData(forMime: mime) else { continue }
                contents.append(.init(mime: mime, data: data))
            }
        }

        // The listing of available types, only gathered when requested.
        let available: [String] = list ? pasteboard.ghosttyAvailableMimes() : []

        // With nothing to serve and no listing requested there is
        // nothing to complete the read with.
        if contents.isEmpty && !list {
            return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
        }

        Ghostty.Surface.ClipboardReadRequest(surface: surface, state: state)
            .complete(contents: contents, available: available)
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    static func confirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard let context = surfaceContext(from: userdata), let surface = context.surface else { return }
        let pending = Ghostty.Surface.ClipboardReadRequest(surface: surface, state: state)
        guard let surfaceView = context.view else {
            pending.deny()
            return
        }
        guard let confirm,
              let kind = Ghostty.ClipboardRequest.from(request: request) else {
            pending.deny()
            return
        }
        let c = confirm.pointee

        // Copy the borrowed C representations: the confirmation is
        // asynchronous and completes with exactly what the user
        // approved, so the clipboard is never re-read.
        var reps: [Ghostty.ClipboardContent] = []
        if let contents = c.contents {
            for i in 0..<c.contents_len {
                let content = contents[i]
                let data: Data = if content.len > 0 {
                    Data(bytes: content.data, count: content.len)
                } else {
                    Data()
                }
                reps.append(.init(mime: String(cString: content.mime), data: data))
            }
        }
        var avail: [String] = []
        if let available = c.available {
            for i in 0..<c.available_len {
                guard let ptr = available[i] else { continue }
                avail.append(String(cString: ptr))
            }
        }

        // The dialog can only display text: show the text
        // representation when there is one and summarize the rest.
        let display = reps.first(where: { $0.mime == "text/plain" })
            .flatMap { String(data: $0.data, encoding: .utf8) }
            ?? reps.map { "\($0.mime) (\($0.data.count) bytes)" }.joined(separator: "\n")

        // Decode an image representation so the dialog can preview
        // exactly what would be disclosed rather than a byte count.
        let previewImage: NSImage? = reps.lazy
            .filter { $0.mime.hasPrefix("image/") }
            .compactMap { NSImage(data: $0.data) }
            .first

        // libghostty reaches this callback only when the request attempted
        // by readClipboard requires confirmation. Reads allowed by policy
        // complete immediately and never become pending Swift state.
        let request = Ghostty.ClipboardConfirmationRequest(
            surface: surfaceView,
            contents: display,
            kind: kind,
            programName: c.name.map { String(cString: $0) },
            canRemember: c.can_remember,
            previewImage: previewImage
        ) { _, confirmed, remember in
            if confirmed {
                pending.complete(
                    contents: reps,
                    available: avail,
                    confirmed: true,
                    remember: remember)
            } else {
                pending.deny()
            }
        }
        surfaceView.pendingClipboardConfirmation = request
    }

    static func writeClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int,
        confirm: Bool
    ) {
        guard let surfaceView = self.surfaceUserdata(from: userdata) else { return }
        guard let pasteboard = NSPasteboard.ghostty(location) else { return }
        guard let content = content, len > 0 else { return }

        // Convert the C array to Swift array
        let contentArray = (0..<len).compactMap { i in
            Ghostty.ClipboardContent.from(content: content[i])
        }
        guard !contentArray.isEmpty else { return }

        // Assert there is only one text/plain entry. For security reasons we need
        // to guarantee this for now since our confirmation dialog only shows one.
        assert(contentArray.filter({ $0.mime == "text/plain" }).count <= 1,
               "clipboard contents should have at most one text/plain entry")

        if !confirm {
            // Apply writes allowed by policy immediately. Only writes that
            // require confirmation continue to the pending request below.
            let types = contentArray.compactMap { item in
                NSPasteboard.PasteboardType(mimeType: item.mime)
            }
            pasteboard.declareTypes(types, owner: nil)

            // Set data for each type
            for item in contentArray {
                guard let type = NSPasteboard.PasteboardType(mimeType: item.mime) else { continue }
                pasteboard.setData(item.data, forType: type)
            }
            return
        }

        // For confirmation, use the text/plain content if it exists
        guard let textPlainContent = contentArray.first(where: { $0.mime == "text/plain" }),
              let textPlainString = textPlainContent.string else {
            return
        }

        let request = Ghostty.ClipboardConfirmationRequest(
            surface: surfaceView,
            contents: textPlainString,
            kind: .osc_52_write
        ) { _, confirmed, _ in
            guard confirmed else { return }
            pasteboard.declareTypes([.string], owner: nil)
            pasteboard.setString(textPlainString, forType: .string)
        }
        surfaceView.pendingClipboardConfirmation = request
    }

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
    static private func appState(fromView view: Ghostty.SurfaceView) -> Ghostty.App? {
        guard let surface = view.surfaceModel?.unsafeCValue else { return nil }
        guard let app = ghostty_surface_app(surface) else { return nil }
        return appState(from: app)
    }

    static private func appState(from app: ghostty_app_t) -> Ghostty.App? {
        guard let app_ud = ghostty_app_userdata(app) else { return nil }
        return Unmanaged<Ghostty.App>.fromOpaque(app_ud).takeUnretainedValue()
    }

    static private func surfaceContext(from userdata: UnsafeMutableRawPointer?) -> Ghostty.SurfaceCallbackContext? {
        guard let userdata else { return nil }
        return Unmanaged<Ghostty.SurfaceCallbackContext>.fromOpaque(userdata).takeUnretainedValue()
    }

    static private func surfaceUserdata(from userdata: UnsafeMutableRawPointer?) -> Ghostty.SurfaceView? {
        surfaceContext(from: userdata)?.view
    }

    static private func surfaceView(from surface: ghostty_surface_t) -> Ghostty.SurfaceView? {
        surfaceUserdata(from: ghostty_surface_userdata(surface))
    }

    /// Decode surface-only action targets once; callers keep their own handling
    /// result and payload semantics. Borrowed payloads stay in this synchronous call.
    private static func surfaceView(for target: ghostty_target_s, action: String = #function) -> Ghostty.SurfaceView? {
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

    private static func undo(_ app: ghostty_app_t, target: ghostty_target_s) -> Bool {
        let undoManager: UndoManager?
        switch target.tag {
        case GHOSTTY_TARGET_APP:
            undoManager = appState(from: app)?.undoManager

        case GHOSTTY_TARGET_SURFACE:
            guard let surface = target.target.surface else { return false }
            guard let surfaceView = self.surfaceView(from: surface) else { return false }
            undoManager = surfaceView.windowRegistry.owner(of: surfaceView)?.undoManager

        default:
            assertionFailure()
            return false
        }

        guard let undoManager, undoManager.canUndo else { return false }
        undoManager.undo()
        return true
    }

    private static func redo(_ app: ghostty_app_t, target: ghostty_target_s) -> Bool {
        let undoManager: UndoManager?
        switch target.tag {
        case GHOSTTY_TARGET_APP:
            undoManager = appState(from: app)?.undoManager

        case GHOSTTY_TARGET_SURFACE:
            guard let surface = target.target.surface else { return false }
            guard let surfaceView = self.surfaceView(from: surface) else { return false }
            undoManager = surfaceView.windowRegistry.owner(of: surfaceView)?.undoManager

        default:
            assertionFailure()
            return false
        }

        guard let undoManager, undoManager.canRedo else { return false }
        undoManager.redo()
        return true
    }

    private static func newWindow(_ app: ghostty_app_t, target: ghostty_target_s) {
        guard let appState = appState(from: app) else { return }
        switch target.tag {
        case GHOSTTY_TARGET_APP:
            _ = TerminalController.newWindow(appState)
        case GHOSTTY_TARGET_SURFACE:
            guard let surface = target.target.surface else { return }
            let config = Ghostty.SurfaceConfiguration(from: ghostty_surface_inherited_config(surface, GHOSTTY_SURFACE_CONTEXT_WINDOW))
            _ = TerminalController.newWindow(appState, withBaseConfig: config)
        default:
            assertionFailure()
        }
    }

    private static func newTab(_ app: ghostty_app_t, target: ghostty_target_s) {
        switch target.tag {
        case GHOSTTY_TARGET_APP:
            return

        case GHOSTTY_TARGET_SURFACE:
            guard let surface = target.target.surface else { return }
            guard let surfaceView = self.surfaceView(from: surface) else { return }
            guard let appState = self.appState(fromView: surfaceView) else { return }
            guard appState.config.windowDecorations else {
                let alert = NSAlert()
                alert.messageText = "Tabs are disabled"
                alert.informativeText = "Enable window decorations to use tabs"
                alert.addButton(withTitle: "OK")
                alert.alertStyle = .warning
                _ = alert.runModal()
                return
            }

            let config = Ghostty.SurfaceConfiguration(from: ghostty_surface_inherited_config(surface, GHOSTTY_SURFACE_CONTEXT_TAB))
            surfaceView.windowRegistry.owner(of: surfaceView)?.requestNewTab(from: surfaceView, baseConfig: config)

        default:
            assertionFailure()
        }
    }

    private static func newSplit(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        direction: ghostty_action_split_direction_e) {
        switch target.tag {
        case GHOSTTY_TARGET_APP:
            // New split does nothing with an app target
            Ghostty.logger.warning("new split does nothing with an app target")
            return

        case GHOSTTY_TARGET_SURFACE:
            guard let surface = target.target.surface else { return }
            guard let surfaceView = self.surfaceView(from: surface) else { return }

            let splitDirection: SplitTree<Ghostty.SurfaceView>.NewDirection
            switch direction {
            case GHOSTTY_SPLIT_DIRECTION_RIGHT: splitDirection = .right
            case GHOSTTY_SPLIT_DIRECTION_LEFT: splitDirection = .left
            case GHOSTTY_SPLIT_DIRECTION_DOWN: splitDirection = .down
            case GHOSTTY_SPLIT_DIRECTION_UP: splitDirection = .up
            default: return
            }
            let config = Ghostty.SurfaceConfiguration(from: ghostty_surface_inherited_config(surface, GHOSTTY_SURFACE_CONTEXT_SPLIT))
            surfaceView.windowRegistry.owner(of: surfaceView)?.newSplit(at: surfaceView, direction: splitDirection, baseConfig: config)

        default:
            assertionFailure()
        }
    }

    private static func presentTerminal(
        _ app: ghostty_app_t,
        target: ghostty_target_s
    ) -> Bool {
        switch target.tag {
        case GHOSTTY_TARGET_APP:
            return false

        case GHOSTTY_TARGET_SURFACE:
            guard let surface = target.target.surface else { return false }
            guard let surfaceView = self.surfaceView(from: surface) else { return false }

            guard let controller = surfaceView.windowRegistry.owner(of: surfaceView) else { return false }
            controller.presentTerminal(surfaceView)
            return true

        default:
            assertionFailure()
            return false
        }
    }

    private static func closeTab(_ app: ghostty_app_t, target: ghostty_target_s, mode: ghostty_action_close_tab_mode_e) {
        guard let surfaceView = self.surfaceView(for: target) else { return }

        switch mode {
        case GHOSTTY_ACTION_CLOSE_TAB_MODE_THIS:
            (surfaceView.windowRegistry.owner(of: surfaceView) as? TerminalController)?.closeTab(surfaceView)
            return

        case GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER:
            (surfaceView.windowRegistry.owner(of: surfaceView) as? TerminalController)?.closeOtherTabs(surfaceView)
            return

        case GHOSTTY_ACTION_CLOSE_TAB_MODE_RIGHT:
            (surfaceView.windowRegistry.owner(of: surfaceView) as? TerminalController)?.closeTabsOnTheRight(surfaceView)
            return

        default:
            assertionFailure()
        }
    }

    private static func closeWindow(_ app: ghostty_app_t, target: ghostty_target_s) {
        guard let surfaceView = self.surfaceView(for: target) else { return }

        surfaceView.windowRegistry.owner(of: surfaceView)?.closeWindow(surfaceView)
    }

    private static func closeAllWindows(_ app: ghostty_app_t, target: ghostty_target_s) {
        guard let appState = appState(from: app) else { return }
        TerminalController.closeAllWindows(appState)
    }

    private static func toggleFullscreen(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        mode raw: ghostty_action_fullscreen_e) {
        guard let surfaceView = self.surfaceView(for: target) else { return }
        guard let mode = FullscreenMode.from(ghostty: raw) else {
            Ghostty.logger.warning("unknown fullscreen mode raw=\(raw.rawValue, privacy: .public)")
            return
        }
        surfaceView.windowRegistry.owner(of: surfaceView)?.requestFullscreen(from: surfaceView, mode: mode)
    }

    private static func toggleCommandPalette(
        _ app: ghostty_app_t,
        target: ghostty_target_s) {
        guard let surfaceView = self.surfaceView(for: target) else { return }
        surfaceView.windowRegistry.owner(of: surfaceView)?.toggleCommandPalette(from: surfaceView)
    }

    private static func toggleMaximize(
        _ app: ghostty_app_t,
        target: ghostty_target_s
    ) {
        guard let surfaceView = self.surfaceView(for: target) else { return }
        surfaceView.windowRegistry.owner(of: surfaceView)?.toggleMaximize(from: surfaceView)
    }

    private static func toggleVisibility(
        _ app: ghostty_app_t,
        target: ghostty_target_s
    ) {
        guard let appDelegate = appState(from: app)?.delegate as? AppDelegate else { return }
        appDelegate.toggleVisibility(self)
    }

    private static func ringBell(
        _ app: ghostty_app_t,
        target: ghostty_target_s) {
        switch target.tag {
        case GHOSTTY_TARGET_APP:
            // Technically we could still request app attention here but there
            // are no known cases where the bell is rang with an app target so
            // I think its better to warn.
            Ghostty.logger.warning("ring bell does nothing with an app target")
            return

        case GHOSTTY_TARGET_SURFACE:
            guard let surface = target.target.surface else { return }
            guard let surfaceView = self.surfaceView(from: surface) else { return }
            surfaceView.ringBell()

        default:
            assertionFailure()
        }
    }

    private static func selectionChanged(
        _ app: ghostty_app_t,
        target: ghostty_target_s) {
        guard let surfaceView = self.surfaceView(for: target) else { return }
        surfaceView.selectionDidChange()
    }

    private static func setReadonly(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_action_readonly_e) {
        guard let surfaceView = self.surfaceView(for: target) else { return }
        surfaceView.setReadonly(v == GHOSTTY_READONLY_ON)
    }

    private static func moveTab(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        move: ghostty_action_move_tab_s) -> Bool {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("move tab does nothing with an app target")
                return false

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return false }
                guard let surfaceView = self.surfaceView(from: surface) else { return false }

                // See gotoTab for notes on this check.
                guard (surfaceView.window?.tabGroup?.windows.count ?? 0) > 1 else { return false }

                guard let controller = surfaceView.windowRegistry.owner(of: surfaceView) as? TerminalController else { return false }
                controller.moveTab(from: surfaceView, action: Ghostty.Action.MoveTab(c: move))

            default:
                assertionFailure()
            }

            return true
    }

    private static func moveTabToNewWindow(
        _ app: ghostty_app_t,
        target: ghostty_target_s) -> Bool {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("move tab to new window does nothing with an app target")
                return false

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return false }
                guard let surfaceView = self.surfaceView(from: surface) else { return false }

                // See gotoTab for notes on this check. A lone tab is already
                // a window of its own, so there is nothing to move.
                guard (surfaceView.window?.tabGroup?.windows.count ?? 0) > 1 else { return false }

                surfaceView.window?.moveTabToNewWindow(nil)

            default:
                assertionFailure()
            }

            return true
    }

    private static func gotoTab(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        tab: ghostty_action_goto_tab_e) -> Bool {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("goto tab does nothing with an app target")
                return false

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return false }
                guard let surfaceView = self.surfaceView(from: surface) else { return false }

                // Similar to goto_split (see comment there) about our performability,
                // we should make this more accurate later.
                guard (surfaceView.window?.tabGroup?.windows.count ?? 0) > 1 else { return false }

                guard let controller = surfaceView.windowRegistry.owner(of: surfaceView) as? TerminalController else { return false }
                if let destination = Ghostty.TabDestination(coreValue: tab) {
                    controller.gotoTab(from: surfaceView, tab: destination)
                }

            default:
                assertionFailure()
            }

            return true
    }

    private static func gotoSplit(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        direction: ghostty_action_goto_split_e) -> Bool {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("goto split does nothing with an app target")
                return false

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return false }
                guard let surfaceView = self.surfaceView(from: surface) else { return false }
                guard let controller = surfaceView.windowRegistry.owner(of: surfaceView) else { return false }

                // If the window has no splits, the action is not performable
                guard controller.surfaceTree.isSplit else { return false }

                // Convert the C API direction to our Swift type
                guard let splitDirection = Ghostty.SplitFocusDirection.from(direction: direction) else { return false }

                // Find the current node in the tree
                guard let targetNode = controller.surfaceTree.root?.node(view: surfaceView) else { return false }

                // Check if a split actually exists in the target direction before
                // returning true. This ensures performable keybinds only consume
                // the key event when we actually perform navigation.
                let focusDirection: SplitTree<Ghostty.SurfaceView>.FocusDirection = splitDirection.toSplitTreeFocusDirection()
                guard controller.surfaceTree.focusTarget(for: focusDirection, from: targetNode) != nil else {
                    return false
                }

                // We have a valid target, perform the navigation.
                controller.focusSplit(from: surfaceView, direction: splitDirection)

                return true

            default:
                assertionFailure()
                return false
            }
    }

    private static func gotoWindow(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        direction: ghostty_action_goto_window_e
    ) -> Bool {
        // Collect candidate windows: visible terminal windows that are either
        // standalone or the currently selected tab in their tab group. This
        // treats each native tab group as a single "window" for navigation
        // purposes, since goto_tab handles per-tab navigation.
        guard let state = appState(from: app) else { return false }
        let candidates = state.windowRegistry.windowControllers.compactMap(\.window).filter { window in
            guard window.isVisible, !window.isMiniaturized else { return false }
            // For native tabs, only include the selected tab in each group
            if let group = window.tabGroup, group.selectedWindow !== window {
                return false
            }
            return true
        }

        // Need at least two windows to navigate between
        guard candidates.count > 1 else { return false }

        // Find starting index from the current key/main window
        let startIndex = candidates.firstIndex(where: { $0.isKeyWindow })
            ?? candidates.firstIndex(where: { $0.isMainWindow })
            ?? 0

        let step: Int
        switch direction {
        case GHOSTTY_GOTO_WINDOW_NEXT:
            step = 1
        case GHOSTTY_GOTO_WINDOW_PREVIOUS:
            step = -1
        default:
            return false
        }

        // Iterate with wrap-around until we find a valid window or return to start
        let count = candidates.count
        var index = (startIndex + step + count) % count

        while index != startIndex {
            let candidate = candidates[index]
            if candidate.isVisible, !candidate.isMiniaturized {
                candidate.makeKeyAndOrderFront(nil)
                // Also focus the terminal surface within the window
                if let controller = candidate.windowController as? BaseTerminalController,
                   let surface = controller.focusedSurface {
                    Ghostty.moveFocus(to: surface)
                }
                return true
            }
            index = (index + step + count) % count
        }

        return false
    }

    private static func resizeSplit(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        resize: ghostty_action_resize_split_s) -> Bool {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("resize split does nothing with an app target")
                return false

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return false }
                guard let surfaceView = self.surfaceView(from: surface) else { return false }
                guard let controller = surfaceView.windowRegistry.owner(of: surfaceView) else { return false }

                // If the window has no splits, the action is not performable
                guard controller.surfaceTree.isSplit else { return false }

                guard let resizeDirection = Ghostty.SplitResizeDirection.from(direction: resize.direction) else { return false }
                controller.resizeSplit(from: surfaceView, direction: resizeDirection, amount: resize.amount)
                return true

            default:
                assertionFailure()
                return false
            }
    }

    private static func equalizeSplits(
        _ app: ghostty_app_t,
        target: ghostty_target_s) {
        guard let surfaceView = self.surfaceView(for: target) else { return }
        surfaceView.windowRegistry.owner(of: surfaceView)?.equalizeSplits(from: surfaceView)
    }

    private static func toggleSplitZoom(
        _ app: ghostty_app_t,
        target: ghostty_target_s) -> Bool {
        guard let surfaceView = self.surfaceView(for: target) else { return false }
        guard let controller = surfaceView.windowRegistry.owner(of: surfaceView) else { return false }

        // If the window has no splits, the action is not performable
        guard controller.surfaceTree.isSplit else { return false }

        controller.toggleSplitZoom(on: surfaceView)
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

    private static func toggleFloatWindow(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        mode mode_raw: ghostty_action_float_window_e
    ) {
        guard let mode = Ghostty.SetFloatWIndow.from(mode_raw) else { return }

        guard let surfaceView = self.surfaceView(for: target) else { return }
        guard let window = surfaceView.window as? TerminalWindow else { return }

        switch mode {
        case .on:
            window.level = .floating

        case .off:
            window.level = .normal

        case .toggle:
            window.level = window.level == .floating ? .normal : .floating
        }

        if let appDelegate = appState(from: app)?.delegate as? AppDelegate {
            appDelegate.syncFloatOnTopMenu(window)
        }
    }

    private static func toggleBackgroundOpacity(
        _ app: ghostty_app_t,
        target: ghostty_target_s
    ) {
        switch target.tag {
        case GHOSTTY_TARGET_APP:
            Ghostty.logger.warning("toggle background opacity does nothing with an app target")
            return

        case GHOSTTY_TARGET_SURFACE:
            guard let surface = target.target.surface,
                let surfaceView = self.surfaceView(from: surface),
                let controller = surfaceView.windowRegistry.owner(of: surfaceView) else { return }

            controller.toggleBackgroundOpacity()

        default:
            assertionFailure()
        }
    }

    private static func toggleSecureInput(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        mode mode_raw: ghostty_action_secure_input_e
    ) {
        guard let mode = Ghostty.SetSecureInput.from(mode_raw) else { return }

        switch target.tag {
        case GHOSTTY_TARGET_APP:
            guard let appDelegate = appState(from: app)?.delegate as? AppDelegate else { return }
            appDelegate.setSecureInput(mode)

        case GHOSTTY_TARGET_SURFACE:
            guard let surface = target.target.surface else { return }
            guard let surfaceView = self.surfaceView(from: surface) else { return }
            guard let appState = self.appState(fromView: surfaceView) else { return }
            guard appState.config.autoSecureInput else { return }

            switch mode {
            case .on:
                surfaceView.passwordInput = true

            case .off:
                surfaceView.passwordInput = false

            case .toggle:
                surfaceView.passwordInput = !surfaceView.passwordInput
            }

        default:
            assertionFailure()
        }
    }

    private static func toggleQuickTerminal(
        _ app: ghostty_app_t,
        target: ghostty_target_s
    ) {
        guard let appDelegate = appState(from: app)?.delegate as? AppDelegate else { return }
        appDelegate.toggleQuickTerminal(self)
    }

    private static func setTitle(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_action_set_title_s) {
        guard let surfaceView = self.surfaceView(for: target) else { return }
        guard let title = String(cString: v.title!, encoding: .utf8) else { return }
        surfaceView.setTitle(title)
    }

    private static func setTabTitle(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_action_set_title_s
    ) -> Bool {
        switch target.tag {
        case GHOSTTY_TARGET_APP:
            Ghostty.logger.warning("set tab title does nothing with an app target")
            return false

        case GHOSTTY_TARGET_SURFACE:
            guard let title = String(cString: v.title!, encoding: .utf8) else { return false }
            let titleOverride = title.isEmpty ? nil : title
            guard let surface = target.target.surface else { return false }
            guard let surfaceView = self.surfaceView(from: surface) else { return false }
            guard let controller = surfaceView.windowRegistry.owner(of: surfaceView) else { return false }
            controller.titleOverride = titleOverride
            return true

        default:
            assertionFailure()
            return false
        }
    }

    private static func showSurfaceFault(
        target: ghostty_target_s,
        value: ghostty_surface_fault_s
    ) -> Bool {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface,
              let view = surfaceView(from: surface) else { return false }
        // Publish synchronously on the app thread, even before window attachment.
        // Returning true means the native view owns a visible, durable explanation.
        view.state.fault = Ghostty.SurfaceFault(value)
        view.state.childExitedMessage = nil
        return true
    }

    private static func showChildExited(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_surface_message_childexited_s,
    ) -> Bool {
        switch target.tag {
        case GHOSTTY_TARGET_SURFACE:
            guard let surface = target.target.surface else { return false }
            guard let surfaceView = self.surfaceView(from: surface) else { return false }
            // We handle this when the window is visible and timetime_ms is greater than 0,
            // which will rule out exit codes on launch
            guard surfaceView.window != nil, v.timetime_ms > 0 else { return false }
            guard let config = appState(from: app)?.config else { return false }
            surfaceView.setChildExitedMessage(.init(v, threshold: config.abnormalCommandExitRuntime))
            return true
        default:
            return false
        }
    }

    private static func copyTitleToClipboard(
        _ app: ghostty_app_t,
        target: ghostty_target_s) -> Bool {
        switch target.tag {
        case GHOSTTY_TARGET_SURFACE:
            guard let surface = target.target.surface else { return false }
            guard let surfaceView = self.surfaceView(from: surface) else { return false }
            let title = surfaceView.title
            if title.isEmpty { return false }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(title, forType: .string)
            return true

        default:
            return false
        }
    }

    private static func promptTitle(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_action_prompt_title_e) -> Bool {
        let promptTitle = Ghostty.Action.PromptTitle(v)
        switch promptTitle {
        case .surface:
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("set title prompt does nothing with an app target")
                return false

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return false }
                guard let surfaceView = self.surfaceView(from: surface) else { return false }
                surfaceView.promptTitle()
                return true

            default:
                assertionFailure()
                return false
            }

        case .tab:
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                guard let registry = appState(from: app)?.windowRegistry,
                      let controller = registry.windowControllers.first(where: { $0.window?.isMainWindow == true })
                        ?? registry.windowControllers.first(where: { $0.window?.isKeyWindow == true })
                else { return false }
                controller.promptTabTitle()
                return true

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return false }
                guard let surfaceView = self.surfaceView(from: surface) else { return false }
                guard let controller = surfaceView.windowRegistry.owner(of: surfaceView) else { return false }
                controller.promptTabTitle()
                return true

            default:
                assertionFailure()
                return false
            }
        }
    }

    private static func pwdChanged(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_action_pwd_s) {
        guard let surfaceView = self.surfaceView(for: target) else { return }
        guard let pwd = String(cString: v.pwd!, encoding: .utf8) else { return }
        surfaceView.pwd = pwd
    }

    private static func setMouseShape(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        shape: ghostty_action_mouse_shape_e) {
        guard let surfaceView = self.surfaceView(for: target) else { return }
        if let style = CursorStyle(coreShape: shape) { surfaceView.setCursorShape(style) }
    }

    private static func setMouseVisibility(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_action_mouse_visibility_e) {
        guard let surfaceView = self.surfaceView(for: target) else { return }
        switch v {
        case GHOSTTY_MOUSE_VISIBLE:
            surfaceView.setCursorVisibility(true)

        case GHOSTTY_MOUSE_HIDDEN:
            surfaceView.setCursorVisibility(false)

        default:
            return
        }
    }

    private static func setMouseOverLink(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_action_mouse_over_link_s) {
        guard let surfaceView = self.surfaceView(for: target) else { return }
        guard v.len > 0 else {
            surfaceView.hoverUrl = nil
            return
        }

        let buffer = Data(bytes: v.url!, count: v.len)
        surfaceView.hoverUrl = String(data: buffer, encoding: .utf8)
    }

    private static func setInitialSize(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_action_initial_size_s) {
        guard let surfaceView = self.surfaceView(for: target) else { return }
        surfaceView.initialSize = NSSize(width: Double(v.width), height: Double(v.height))
    }

    private static func resetWindowSize(
        _ app: ghostty_app_t,
        target: ghostty_target_s) {
        guard let surfaceView = self.surfaceView(for: target) else { return }
        (surfaceView.windowRegistry.owner(of: surfaceView) as? TerminalController)?.returnToDefaultSize(nil)
    }

    private static func setCellSize(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_action_cell_size_s) {
        guard let surfaceView = self.surfaceView(for: target) else { return }
        let backingSize = NSSize(width: Double(v.width), height: Double(v.height))
        DispatchQueue.main.async { [weak surfaceView] in
            guard let surfaceView else { return }
            surfaceView.cellSize = surfaceView.convertFromBacking(backingSize)
        }
    }

    private static func rendererHealth(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_action_renderer_health_e) {
        guard let surfaceView = self.surfaceView(for: target) else { return }
        surfaceView.updateRendererHealth(v == GHOSTTY_RENDERER_HEALTH_HEALTHY)
    }

    private static func keySequence(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_action_key_sequence_s) {
        guard let surfaceView = self.surfaceView(for: target) else { return }
        DispatchQueue.main.async {
            if v.active {
                guard let key = Ghostty.keyboardShortcut(for: v.trigger) else { return }
                surfaceView.continueKeySequence(key)
            } else {
                surfaceView.endKeySequence()
            }
        }
    }

    private static func keyTable(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_action_key_table_s) {
        guard let surfaceView = self.surfaceView(for: target) else { return }
        guard let action = Ghostty.Action.KeyTable(c: v) else { return }

        surfaceView.updateKeyTable(action)
    }

    private static func progressReport(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_action_progress_report_s) {
        guard let surfaceView = self.surfaceView(for: target) else { return }
        guard let config = appState(from: app)?.config else { return }

        guard config.progressStyle else {
            Ghostty.logger.debug("progress_report action blocked by config")
            DispatchQueue.main.async {
                surfaceView.progressReport = nil
            }
            return
        }

        let progressReport = Ghostty.Action.ProgressReport(c: v)
        DispatchQueue.main.async {
            if progressReport.state == .remove {
                surfaceView.progressReport = nil
            } else {
                surfaceView.progressReport = progressReport
            }
        }
    }

    private static func scrollbar(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_action_scrollbar_s) {
        guard let surfaceView = self.surfaceView(for: target) else { return }

        let scrollbar = Ghostty.Action.Scrollbar(c: v)
        surfaceView.updateScrollbar(scrollbar)
    }

    private static func startSearch(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_action_start_search_s) {
        guard let surfaceView = self.surfaceView(for: target) else { return }

        let startSearch = Ghostty.Action.StartSearch(c: v)
        DispatchQueue.main.async {
            if let searchState = surfaceView.searchState {
                if let needle = startSearch.needle, !needle.isEmpty {
                    searchState.setNeedle(needle)
                }
            } else {
                surfaceView.searchState = Ghostty.SearchState(from: startSearch)
            }

            surfaceView.searchState?.requestFocus()
        }
    }

    private static func endSearch(
        _ app: ghostty_app_t,
        target: ghostty_target_s) -> Bool {
        guard let surfaceView = self.surfaceView(for: target) else { return false }

        DispatchQueue.main.async {
            surfaceView.endSearch()
        }
        return true
    }

    private static func searchTotal(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_action_search_total_s) {
        guard let surfaceView = self.surfaceView(for: target) else { return }

        let total: UInt? = v.total >= 0 ? UInt(v.total) : nil
        DispatchQueue.main.async {
            surfaceView.searchState?.total = total
        }
    }

    private static func searchSelected(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_action_search_selected_s) {
        guard let surfaceView = self.surfaceView(for: target) else { return }

        let selected: UInt? = v.selected >= 0 ? UInt(v.selected) : nil
        DispatchQueue.main.async {
            surfaceView.searchState?.selected = selected
        }
    }

    private static func applyTheme(
        _ app: ghostty_app_t,
        target: ghostty_target_s) {
        Ghostty.logger.info("apply theme notification")

        guard let app_ud = ghostty_app_userdata(app) else { return }
        let ghostty = Unmanaged<Ghostty.App>.fromOpaque(app_ud).takeUnretainedValue()

        switch target.tag {
        case GHOSTTY_TARGET_APP:
            ghostty.applyTheme()
            return

        case GHOSTTY_TARGET_SURFACE:
            guard let surface = target.target.surface else { return }
            if let model = surfaceView(from: surface)?.surfaceModel {
                ghostty.applyTheme(surface: model)
            }

        default:
            assertionFailure()
        }
    }

    private static func configChange(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_action_config_change_s) {
            Ghostty.logger.info("config change notification")

            // Clone the config so we own the memory. It'd be nicer to not have to do
            // this but since we async send the config out below we have to own the lifetime.
            // A future improvement might be to add reference counting to config or
            // something so apprt's do not have to do this.
            let config = Ghostty.Config(clone: v.config)

            switch target.tag {
            case GHOSTTY_TARGET_APP:
                // We also REPLACE our app-level config when this happens. This lets
                // all the various things that depend on this but are still theme specific
                // such as split border color work.
                guard let app_ud = ghostty_app_userdata(app) else { return }
                let ghostty = Unmanaged<Ghostty.App>.fromOpaque(app_ud).takeUnretainedValue()
                ghostty.acceptConfiguration(config)

                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                surfaceView.acceptConfiguration(config)

            default:
                assertionFailure()
            }
        }

    private static func colorChange(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        change: ghostty_action_color_change_s) {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("color change does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                surfaceView.acceptColorChange(Ghostty.Action.ColorChange(c: change))

            default:
                assertionFailure()
            }
    }

}
