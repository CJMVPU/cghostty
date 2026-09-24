import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import GhosttyKit
import AppKit

extension Ghostty.App {
    static func undo(_ app: ghostty_app_t, target: ghostty_target_s) -> Bool {
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

    static func redo(_ app: ghostty_app_t, target: ghostty_target_s) -> Bool {
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

    static func newWindow(_ app: ghostty_app_t, target: ghostty_target_s) {
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

    static func newTab(_ app: ghostty_app_t, target: ghostty_target_s) {
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

    static func newSplit(
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

    static func presentTerminal(
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

    static func closeTab(_ app: ghostty_app_t, target: ghostty_target_s, mode: ghostty_action_close_tab_mode_e) {
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

    static func closeWindow(_ app: ghostty_app_t, target: ghostty_target_s) {
        guard let surfaceView = self.surfaceView(for: target) else { return }

        surfaceView.windowRegistry.owner(of: surfaceView)?.closeWindow(surfaceView)
    }

    static func closeAllWindows(_ app: ghostty_app_t, target: ghostty_target_s) {
        guard let appState = appState(from: app) else { return }
        TerminalController.closeAllWindows(appState)
    }

    static func toggleFullscreen(
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

    static func toggleCommandPalette(
        _ app: ghostty_app_t,
        target: ghostty_target_s) {
        guard let surfaceView = self.surfaceView(for: target) else { return }
        surfaceView.windowRegistry.owner(of: surfaceView)?.toggleCommandPalette(from: surfaceView)
    }

    static func toggleMaximize(
        _ app: ghostty_app_t,
        target: ghostty_target_s
    ) {
        guard let surfaceView = self.surfaceView(for: target) else { return }
        surfaceView.windowRegistry.owner(of: surfaceView)?.toggleMaximize(from: surfaceView)
    }

    static func toggleVisibility(
        _ app: ghostty_app_t,
        target: ghostty_target_s
    ) {
        guard let appDelegate = appState(from: app)?.delegate as? AppDelegate else { return }
        appDelegate.toggleVisibility(self)
    }

    static func ringBell(
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

    static func selectionChanged(
        _ app: ghostty_app_t,
        target: ghostty_target_s) {
        guard let surfaceView = self.surfaceView(for: target) else { return }
        surfaceView.selectionDidChange()
    }

    static func setReadonly(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_action_readonly_e) {
        guard let surfaceView = self.surfaceView(for: target) else { return }
        surfaceView.setReadonly(v == GHOSTTY_READONLY_ON)
    }

    static func moveTab(
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

    static func moveTabToNewWindow(
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

    static func gotoTab(
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

    static func gotoSplit(
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

    static func gotoWindow(
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

    static func resizeSplit(
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

    static func equalizeSplits(
        _ app: ghostty_app_t,
        target: ghostty_target_s) {
        guard let surfaceView = self.surfaceView(for: target) else { return }
        surfaceView.windowRegistry.owner(of: surfaceView)?.equalizeSplits(from: surfaceView)
    }

    static func toggleSplitZoom(
        _ app: ghostty_app_t,
        target: ghostty_target_s) -> Bool {
        guard let surfaceView = self.surfaceView(for: target) else { return false }
        guard let controller = surfaceView.windowRegistry.owner(of: surfaceView) else { return false }

        // If the window has no splits, the action is not performable
        guard controller.surfaceTree.isSplit else { return false }

        controller.toggleSplitZoom(on: surfaceView)
        return true
    }

    static func toggleFloatWindow(
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

    static func toggleBackgroundOpacity(
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

    static func toggleSecureInput(
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

    static func toggleQuickTerminal(
        _ app: ghostty_app_t,
        target: ghostty_target_s
    ) {
        guard let appDelegate = appState(from: app)?.delegate as? AppDelegate else { return }
        appDelegate.toggleQuickTerminal(self)
    }

}
