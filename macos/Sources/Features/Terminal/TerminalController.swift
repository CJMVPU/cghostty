import Foundation
import Cocoa
import SwiftUI
import Observation

/// A classic, tabbed terminal experience.
class TerminalController: BaseTerminalController, TabGroupCloseCoordinator.Controller {
    /// AppKit's window/controller link is weak. Keep loaded windows' coordinators
    /// alive independently of SwiftUI view state, and release them on close.
    private static var openControllers: [ObjectIdentifier: TerminalController] = [:]
    override func loadWindow() {
        let config = ghostty.config
        let windowType: TerminalWindow.Type = if !config.windowDecorations {
            TerminalWindow.self
        } else {
            switch config.macosTitlebarStyle {
            case .native: TerminalWindow.self
            case .hidden: HiddenTitlebarTerminalWindow.self
            case .transparent: TransparentTitlebarTerminalWindow.self
            case .tabs: TitlebarTabsTahoeTerminalWindow.self
            }
        }
        let terminalWindow = windowType.init(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        terminalWindow.title = "👻 cghostty"
        terminalWindow.isReleasedWhenClosed = false
        terminalWindow.autorecalculatesKeyViewLoop = false
        terminalWindow.contentView?.wantsLayer = true
        window = terminalWindow
        terminalWindow.delegate = self
        terminalWindow.configure(for: ghostty)
    }

    private weak var observedTabGroup: NSWindowTabGroup?
    private var tabOrderObservation: NSKeyValueObservation?
    private var pendingTabRelabel: DispatchWorkItem?

    /// The initial window presentation is deferred by one runloop turn in a few places so
    /// AppKit can settle tab/window state first. Close actions must cancel it to avoid
    /// re-showing a tab/window that was already closed.
    private var pendingInitialPresentation: DispatchWorkItem?

    /// This is set to false by init if the window managed by this controller should not be restorable.
    /// For example, terminals executing custom scripts are not restorable.
    private var restorable: Bool = true

    /// The configuration derived from the Ghostty config so we don't need to rely on references.
    private(set) var derivedConfig: DerivedConfig

    /// Observation of the focused surface's native window appearance.
    private var appearanceObservation: Task<Void, Never>?

    init(_ ghostty: Ghostty.App,
         withBaseConfig base: Ghostty.SurfaceConfiguration? = nil,
         withSurfaceTree tree: SplitTree<Ghostty.SurfaceView>? = nil,
         parent: NSWindow? = nil,
         restorable: Bool? = nil
    ) {
        // The window we manage is not restorable if we've specified a command
        // to execute. We do this because the restored window is meaningless at the
        // time of writing this: it'd just restore to a shell in the same directory
        // as the script. We may want to revisit this behavior when we have scrollback
        // restoration.
        self.restorable = restorable ?? ((base?.command ?? "") == "")

        // Setup our initial derived config based on the current app config
        self.derivedConfig = DerivedConfig(ghostty.config.snapshot)

        super.init(ghostty, baseConfig: base, surfaceTree: tree)

    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    isolated deinit {
        appearanceObservation?.cancel()
        // Remove all of our notificationcenter subscriptions
        let center = NotificationCenter.default
        center.removeObserver(self)
    }

    private func cancelPendingInitialPresentation() {
        pendingInitialPresentation?.cancel()
        pendingInitialPresentation = nil
    }

    private func scheduleInitialPresentation(_ block: @escaping () -> Void) {
        cancelPendingInitialPresentation()

        var scheduledWorkItem: DispatchWorkItem?
        scheduledWorkItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            defer { self.pendingInitialPresentation = nil }
            guard pendingInitialPresentation?.isCancelled == false else { return }
            block()
        }

        let workItem = scheduledWorkItem!
        pendingInitialPresentation = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    // MARK: Base Controller Overrides

    override func surfaceTreeDidChange(from: SplitTree<Ghostty.SurfaceView>, to: SplitTree<Ghostty.SurfaceView>) {
        super.surfaceTreeDidChange(from: from, to: to)

        // Whenever our surface tree changes in any way (new split, close split, etc.)
        // we want to invalidate our state.
        invalidateRestorableState()

        // Update our zoom state
        if let window = window as? TerminalWindow {
            window.surfaceIsZoomed = to.zoomed != nil
        }

        // If our surface tree is now nil then we close our window.
        if to.isEmpty {
            self.window?.close()
        }
    }

    override func replaceSurfaceTree(
        _ newTree: SplitTree<Ghostty.SurfaceView>,
        moveFocusTo newView: Ghostty.SurfaceView? = nil,
        moveFocusFrom oldView: Ghostty.SurfaceView? = nil,
        undoAction: String? = nil
    ) {
        // We have a special case if our tree is empty to close our tab immediately.
        // This makes it so that undo is handled properly.
        if newTree.isEmpty {
            closeTabImmediately()
            return
        }

        super.replaceSurfaceTree(
            newTree,
            moveFocusTo: newView,
            moveFocusFrom: oldView,
            undoAction: undoAction)
    }

    // MARK: Terminal Creation

    /// The "new window" action.
    static func newWindow(
        _ ghostty: Ghostty.App,
        withBaseConfig baseConfig: Ghostty.SurfaceConfiguration? = nil,
        withParent explicitParent: NSWindow? = nil
    ) -> TerminalController {
        let c = TerminalController.init(ghostty, withBaseConfig: baseConfig)

        // Get our parent. Our parent is the one explicitly given to us,
        // otherwise the focused terminal, otherwise an arbitrary one.
        let parent: NSWindow? = explicitParent ?? ghostty.windowRegistry.preferredParent?.window
        if let parentController = parent?.windowController as? TerminalController {
            c.isBackgroundOpaque = parentController.isBackgroundOpaque
        }

        c.scheduleInitialPresentation {
            // We're dispatching this async because in some cases AppKit will tab this window,
            // although we have a check in `windowDidLoad` and it works in most cases, but not for AppIntent
            //
            // That weird tabbing behavior only happens in the following cases at the point of writing.
            // - Creating a window via the Shortcuts app for now.
            // - Creating a window via `New Ghostty Window Here` service.
            c.showWindowSafely(self)

            if let window = c.window {
                let hasFixedPos = c.derivedConfig.windowPositionX != nil && c.derivedConfig.windowPositionY != nil
                // We're dispatching this async because otherwise the lastCascadePoint doesn't
                // take effect after positioning in `showWindow`. Our best theory is there is
                // some next-event-loop-tick logic that Cocoa is doing that we need to be after.
                DispatchQueue.main.async {
                    ghostty.windowRegistry.applyCascade(to: window, hasFixedPos: hasFixedPos)
                }
            }

            // All new_window actions force our app to be active, so that the new
            // window is focused and visible.
            NSApp.activate(ignoringOtherApps: true)
        }

        // Setup our undo
        let approval: @MainActor (TerminalController) async -> Bool = { await $0.approveCreationUndo() }
        if let undoManager = c.undoManager {
            undoManager.setActionName("New Window")
            undoManager.registerUndo(
                withTarget: c,
                expiresAfter: c.undoExpiration,
                approval: approval
            ) { target in
                // Approval finished before the undo group was consumed.
                undoManager.disableUndoRegistration {
                    target.closeTabImmediately()
                }

                // Register redo action
                undoManager.registerUndo(
                    withTarget: ghostty,
                    expiresAfter: target.undoExpiration
                ) { ghostty in
                    _ = TerminalController.newWindow(
                        ghostty,
                        withBaseConfig: baseConfig,
                        withParent: explicitParent)
                }
            }
        }

        return c
    }

    /// Create a new window with an existing split tree.
    /// The new window uses the startup size, independently of the moved tree.
    /// - Parameters:
    ///   - ghostty: The Ghostty app instance.
    ///   - tree: The split tree to use for the new window.
    ///   - position: Optional screen position (top-left corner) for the new window.
    ///               If nil, the window will cascade from the last cascade point.
    static func newWindow(
        _ ghostty: Ghostty.App,
        tree: SplitTree<Ghostty.SurfaceView>,
        position: NSPoint? = nil,
        confirmUndo: Bool = true,
        inheritBackgroundOpacity: Bool? = nil
    ) -> TerminalController {
        let c = TerminalController.init(ghostty, withSurfaceTree: tree)
        if let inheritBackgroundOpacity {
            c.isBackgroundOpaque = inheritBackgroundOpacity
        }

        // Showing window in current event loop works so far with dragging surface into
        // a new window, but remember to defer the cascade when you move it inside
        // `scheduleInitialPresentation` to solve other issues in the future.
        c.showWindowSafely(self)
        c.scheduleInitialPresentation {
            if let window = c.window {
                if let position {
                    window.setFrameTopLeftPoint(position)
                    window.constrainToScreen()
                } else {
                    let hasFixedPos = c.derivedConfig.windowPositionX != nil && c.derivedConfig.windowPositionY != nil
                    ghostty.windowRegistry.applyCascade(to: window, hasFixedPos: hasFixedPos)
                }
            }
        }

        // A moved split belongs to the whole synchronous Move Split group.
        let approval: (@MainActor (TerminalController) async -> Bool)?
        if confirmUndo {
            approval = { (controller: TerminalController) in
                await controller.approveCreationUndo()
            }
        } else {
            approval = nil
        }
        if let undoManager = c.undoManager {
            undoManager.setActionName("New Window")
            undoManager.registerUndo(
                withTarget: c,
                expiresAfter: c.undoExpiration,
                approval: approval
            ) { target in
                undoManager.disableUndoRegistration {
                    target.closeTabImmediately()
                }

                undoManager.registerUndo(
                    withTarget: ghostty,
                    expiresAfter: target.undoExpiration
                ) { ghostty in
                    _ = TerminalController.newWindow(
                        ghostty,
                        tree: tree,
                        position: position,
                        confirmUndo: confirmUndo,
                        inheritBackgroundOpacity: inheritBackgroundOpacity
                    )
                }
            }
        }

        return c
    }

    static func newTab(
        _ ghostty: Ghostty.App,
        from parent: NSWindow? = nil,
        withBaseConfig baseConfig: Ghostty.SurfaceConfiguration? = nil
    ) -> TerminalController? {
        // Making sure that we're dealing with a TerminalController. If not,
        // then we just create a new window.
        guard let parent,
              let parentController = parent.windowController as? TerminalController else {
            return newWindow(ghostty, withBaseConfig: baseConfig, withParent: parent)
        }

        guard TerminalWindow.canAddTab(to: parent) else {
            TerminalWindow.reportTabLimit(parent)
            return nil
        }

        // Create a new window and add it to the parent
        let controller = TerminalController.init(ghostty, withBaseConfig: baseConfig)
        controller.isBackgroundOpaque = parentController.isBackgroundOpaque
        guard let window = controller.window else { return controller }

        // If the parent is miniaturized, then macOS exhibits really strange behaviors
        // so we have to bring it back out.
        if parent.isMiniaturized { parent.deminiaturize(self) }

        // If our parent tab group already has this window, macOS added it and
        // we need to remove it so we can set the correct order in the next line.
        // If we don't do this, macOS gets really confused and the tabbedWindows
        // state becomes incorrect.
        //
        // At the time of writing this code, the only known case this happens
        // is when the "+" button is clicked in the tab bar.
        if let tg = parent.tabGroup,
           tg.windows.firstIndex(of: window) != nil {
            tg.removeWindow(window)
        }

        // If we don't allow tabs then we create a new window instead.
        if window.tabbingMode != .disallowed {
            let tabCreated: Bool
            // Add the window to the tab group and show it.
            switch ghostty.config.windowNewTabPosition {
            case "end":
                // If we already have a tab group and we want the new tab to open at the end,
                // then we use the last window in the tab group as the parent.
                if let last = parent.tabGroup?.windows.last {
                    tabCreated = last.addTabbedWindowSafely(window, ordered: .above)
                } else {
                    fallthrough
                }

            case "current": fallthrough
            default:
                tabCreated = parent.addTabbedWindowSafely(window, ordered: .above)
            }
            if tabCreated {
                // We set the selectedWindow early here because we want the next window
                // to become first responder as quickly as possible. Usually this is
                // set while `-[NSWindowController showWindow:]` is called, but we're
                // dispatching it to resolve other issues.
                parent.tabGroup?.selectedWindow = window
            }
        }

        // showWindow makes regular windows key and ordered front. AppKit can
        // throw while selecting a tab if its fullscreen stack is inconsistent,
        // so this must cross the Objective-C exception bridge.
        controller.showWindowSafely(self)

        // We're dispatching this async because otherwise the lastCascadePoint doesn't
        // take effect after position in `showWindow`. Our best theory is there is some
        // next-event-loop-tick logic that Cocoa is doing that we need to be after.
        controller.scheduleInitialPresentation {
            // Cascade only when alone in the tab group.
            if window.tabGroup?.windows.count ?? 1 == 1 {
                let hasFixedPos = controller.derivedConfig.windowPositionX != nil && controller.derivedConfig.windowPositionY != nil
                ghostty.windowRegistry.applyCascade(to: window, hasFixedPos: hasFixedPos)
            }

            // We also activate our app so that it becomes front. This may be
            // necessary for the dock menu.
            NSApp.activate(ignoringOtherApps: true)
        }

        controller.scheduleTabRelabel()

        // Setup our undo
        let approval: @MainActor (TerminalController) async -> Bool = { await $0.approveCreationUndo() }
        if let undoManager = parentController.undoManager {
            undoManager.setActionName("New Tab")
            undoManager.registerUndo(
                withTarget: controller,
                expiresAfter: controller.undoExpiration,
                approval: approval
            ) { target in
                undoManager.disableUndoRegistration {
                    target.closeTabImmediately()
                }

                // Register redo action
                undoManager.registerUndo(
                    withTarget: ghostty,
                    expiresAfter: target.undoExpiration
                ) { ghostty in
                    _ = TerminalController.newTab(
                        ghostty,
                        from: parent,
                        withBaseConfig: baseConfig)
                }
            }
        }

        return controller
    }

    // MARK: - Methods

    override func acceptConfiguration(_ config: Ghostty.Config) {
        super.acceptConfiguration(config)
        derivedConfig = DerivedConfig(config.snapshot)
        if surfaceTree.isEmpty { syncAppearance(.init(config.snapshot)) }
    }

    /// Update the accessory view of each tab according to the keyboard
    /// shortcut that activates it (if any). This is called when the key window
    /// changes, when a window is closed, and when tabs are reordered
    /// with the mouse.
    func relabelTabs() {
        guard isWindowLoaded,
              ghostty.windowRegistry.registeredControllers.contains(where: { $0 === self }) else { return }
        (window as? HiddenTitlebarTerminalWindow)?.refreshChrome()
        let group = window?.tabGroup
        if observedTabGroup !== group {
            observedTabGroup = group
            // NSWindowTabGroup.windows explicitly supports KVO, including drag reorder.
            tabOrderObservation = group?.observe(\.windows) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.scheduleTabRelabel() }
            }
        }

        if let windows = window?.tabbedWindows as? [TerminalWindow] {
            for (tab, window) in zip(1..., windows) {
                // We need to clear any windows beyond this because they have had
                // a keyEquivalent set previously.
                guard tab <= 9 else {
                    window.keyEquivalent = ""
                    continue
                }

                if let equiv = ghostty.config.keyboardShortcut(for: "goto_tab:\(tab)") {
                    window.keyEquivalent = "\(equiv)"
                } else {
                    window.keyEquivalent = ""
                }
            }
        }
    }

    private func fixTabBar() {
        // We do this to make sure that the tab bar will always re-composite. If we don't,
        // then the it will "drag" pieces of the background with it when a transparent
        // window is moved around.
        //
        // There might be a better way to make the tab bar "un-lazy", but I can't find it.
        if let window = window, !window.isOpaque {
            window.isOpaque = true
            window.isOpaque = false
        }
    }

    /// Coalesce group mutations until AppKit has finished changing membership.
    /// This also rebinds observation if a window moved to a different group.
    func scheduleTabRelabel() {
        pendingTabRelabel?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pendingTabRelabel?.isCancelled == false else { return }
            self.pendingTabRelabel = nil
            self.relabelTabs()
        }
        pendingTabRelabel = work
        DispatchQueue.main.async(execute: work)
    }

    override func syncAppearance() {
        // When our focus changes, we update our window appearance based on the
        // currently focused surface.
        guard let focusedSurface else { return }
        syncAppearance(focusedSurface.derivedConfig)
    }

    private func syncAppearance(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        // Let our window handle its own appearance
        guard let window = window as? TerminalWindow else { return }

        // Sync our zoom state for splits
        window.surfaceIsZoomed = surfaceTree.zoomed != nil

        // Set the font for the window and tab titles.
        if let titleFontName = surfaceConfig.windowTitleFontFamily {
            window.titlebarFont = NSFont(name: titleFontName, size: NSFont.systemFontSize)
        } else {
            window.titlebarFont = nil
        }

        // Call this last in case it uses any of the properties above.
        window.syncAppearance(surfaceConfig)
        terminalViewContainer?.ghosttyConfigDidChange(ghostty.config, preferredBackgroundColor: window.preferredBackgroundColor)
    }

    /// Adjusts the given frame for the configured window position.
    func adjustForWindowPosition(frame: NSRect, on screen: NSScreen) -> NSRect {
        guard let x = derivedConfig.windowPositionX else { return frame }
        guard let y = derivedConfig.windowPositionY else { return frame }

        // Convert top-left coordinates to bottom-left origin using our utility extension
        let origin = screen.origin(
            fromTopLeftOffsetX: CGFloat(x),
            offsetY: CGFloat(y),
            windowSize: frame.size)

        // Clamp the origin to ensure the window stays fully visible on screen
        var safeOrigin = origin
        let vf = screen.visibleFrame
        safeOrigin.x = min(max(safeOrigin.x, vf.minX), vf.maxX - frame.width)
        safeOrigin.y = min(max(safeOrigin.y, vf.minY), vf.maxY - frame.height)

        // Return our new origin
        var result = frame
        result.origin = safeOrigin
        return result
    }

    /// This is called anytime a node in the surface tree is being removed.
    override func closeSurface(
        _ node: SplitTree<Ghostty.SurfaceView>.Node,
        withConfirmation: Bool = true
    ) {
        // If this isn't the root then we're dealing with a split closure.
        if surfaceTree.root != node {
            super.closeSurface(node, withConfirmation: withConfirmation)
            return
        }

        // More than 1 window means we have tabs and we're closing a tab
        if window?.tabGroup?.windows.count ?? 0 > 1 {
            if withConfirmation {
                closeTab(nil)
            } else {
                closeTabImmediately()
            }
            return
        }

        // 1 window, closing the window
        if withConfirmation {
            closeWindow(nil)
        } else {
            closeWindowImmediately()
        }
    }

    func closeTabImmediately(registerRedo: Bool = true) {
        Self.closeControllerSnapshot([self], actionName: "Close Tab", registerRedo: registerRedo)
    }

    /// Closes exactly the current group. Redo retains the restored identities.
    func closeWindowImmediately() {
        guard let window else { return }
        let targets = (window.tabGroup?.windows ?? [window]).compactMap {
            $0.windowController as? TerminalController
        }
        Self.closeControllerSnapshot(targets, actionName: "Close Window")
    }

    private struct ClosedControllerState {
        let state: UndoState
        let groupID: ObjectIdentifier?
        let selected: Bool
    }

    /// One identity transaction for a tab, a whole window, or a batch of tabs.
    /// Existing siblings survive redo even if they joined after restoration.
    static func closeControllerSnapshot(
        _ targets: [TerminalController],
        actionName: String,
        registerRedo: Bool = true
    ) {
        let targets = targets.filter { controller in
            controller.ghostty.windowRegistry.registeredControllers.contains { $0 === controller }
        }
        guard let first = targets.first else { return }
        let ghostty = first.ghostty
        let manager = ghostty.undoManager
        let expiration = first.undoExpiration
        let previouslySelected = first.window?.tabGroup?.selectedWindow
        let states = targets.compactMap { controller -> ClosedControllerState? in
            guard var state = controller.undoState, let window = controller.window else { return nil }
            let group = window.tabGroup
            let groupID = group.map(ObjectIdentifier.init)
            let selected = group?.selectedWindow === window || window.isKeyWindow
            // Fully closed groups must be rebuilt, while surviving siblings
            // remain a valid insertion destination for a restored subset.
            if let group, group.windows.allSatisfy({ window in
                targets.contains { $0.window === window }
            }) { state.tabGroup = nil }
            return .init(state: state, groupID: groupID, selected: selected)
        }
        let registersUndo = manager.isUndoRegistrationEnabled && !states.isEmpty
        if registersUndo { manager.beginUndoGrouping() }
        defer { if registersUndo { manager.endUndoGrouping() } }
        if registersUndo {
            manager.setActionName(actionName)
            manager.registerUndo(withTarget: ghostty, expiresAfter: expiration) { [weak previouslySelected] ghostty in
                var restored: [TerminalController] = []
                var groupTails: [ObjectIdentifier: NSWindow] = [:]
                var selectedWindow: NSWindow?
                // Preserve tab order even when targets were collected out of order.
                let ordered = states.sorted {
                    ($0.state.tabIndex ?? 0) < ($1.state.tabIndex ?? 0)
                }
                for saved in ordered {
                    let controller = TerminalController(ghostty, with: saved.state)
                    restored.append(controller)
                    guard let window = controller.window else { continue }
                    if let groupID = saved.groupID {
                        if saved.state.tabGroup == nil, let tail = groupTails[groupID] {
                            tail.addTabbedWindowSafely(window, ordered: .above)
                        }
                        groupTails[groupID] = window
                    }
                    if saved.selected { selectedWindow = window }
                }
                if let previouslySelected,
                   let controller = previouslySelected.windowController as? TerminalController,
                   ghostty.windowRegistry.registeredControllers.contains(where: { $0 === controller }) {
                    previouslySelected.makeKeyAndOrderFront(nil)
                } else {
                    selectedWindow?.makeKeyAndOrderFront(nil)
                }
                if registerRedo {
                    manager.registerUndo(withTarget: ghostty, expiresAfter: expiration) { _ in
                        closeControllerSnapshot(restored, actionName: actionName)
                    }
                }
            }
        }
        for controller in targets {
            controller.cancelPendingInitialPresentation()
            // Keep the saved trees alive only through undo; clearing before
            // NSWindow.close also avoids AppKit's delayed close registration.
            if controller.surfaceTree.isEmpty {
                controller.window?.close()
            } else {
                controller.surfaceTree = .init()
            }
        }
    }

    private func approveCreationUndo() async -> Bool {
        guard ghostty.windowRegistry.registeredControllers.contains(where: { $0 === self }) else { return false }
        guard !windowCanBeClosedWithoutConfirmation() else { return true }
        return await confirmCloseAsync(
            messageText: "Close Terminal?",
            informativeText: "The terminal still has a running process. If you close the terminal the process will be killed."
        ) == .allowed
    }

    /// Close all windows, asking for confirmation if necessary.
    static func closeAllWindows(_ ghostty: Ghostty.App) {
        // The window we use for confirmations. Try to find the first window that
        // needs quit confirmation. This lets us attach the confirmation to something
        // that is running.
        guard let confirmWindow = ghostty.windowRegistry.all
            .first(where: { $0.surfaceTree.contains(where: { $0.needsConfirmQuit }) })?
            .surfaceTree.first(where: { $0.needsConfirmQuit })?
            .window
        else {
            closeAllWindowsImmediately(ghostty)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Close All Windows?"
        alert.informativeText = "All terminal sessions will be terminated."
        alert.addButton(withTitle: "Close All Windows")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: confirmWindow, completionHandler: { response in
            if response == .alertFirstButtonReturn {
                // This is important so that we avoid losing focus when Stage
                // Manager is used (#8336)
                alert.window.orderOut(nil)
                closeAllWindowsImmediately(ghostty)
            }
        })
    }

    static private func closeAllWindowsImmediately(_ ghostty: Ghostty.App) {
        let undoManager = ghostty.undoManager
        undoManager.beginUndoGrouping()
        ghostty.windowRegistry.all.forEach { $0.closeWindowImmediately() }
        undoManager.setActionName("Close All Windows")
        undoManager.endUndoGrouping()
    }

    // MARK: Undo/Redo

    /// The state that we require to recreate a TerminalController from an undo.
    struct UndoState {
        let frame: NSRect
        let surfaceTree: SplitTree<Ghostty.SurfaceView>
        let focusedSurface: UUID?
        let tabIndex: Int?
        weak var tabGroup: NSWindowTabGroup?
        let tabColor: TerminalTabColor
        let titleOverride: String?
        let isBackgroundOpaque: Bool
        let restorable: Bool
    }

    convenience init(_ ghostty: Ghostty.App, with undoState: UndoState) {
        self.init(ghostty, withSurfaceTree: undoState.surfaceTree, restorable: undoState.restorable)
        isBackgroundOpaque = undoState.isBackgroundOpaque
        titleOverride = undoState.titleOverride

        // Restore placement while keeping the configured content size
        showWindow(nil)
        syncAppearance()
        if let window {
            window.setFrameOrigin(undoState.frame.origin)
            if let terminalWindow = window as? TerminalWindow {
                terminalWindow.tabColor = undoState.tabColor
            }

            // If we have a tab group and index, restore the tab to its original position
            if let tabGroup = undoState.tabGroup,
               let tabIndex = undoState.tabIndex {
                if tabIndex < tabGroup.windows.count {
                    // Find the window that is currently at that index
                    let currentWindow = tabGroup.windows[tabIndex]
                    currentWindow.addTabbedWindowSafely(window, ordered: .below)
                } else {
                    tabGroup.windows.last?.addTabbedWindowSafely(window, ordered: .above)
                }

                // Make it the key window
                window.makeKeyAndOrderFront(nil)
            }

            // Restore focus to the previously focused surface
            if let focusedUUID = undoState.focusedSurface,
               let focusTarget = surfaceTree.first(where: { $0.id == focusedUUID }) {
                DispatchQueue.main.async {
                    Ghostty.moveFocus(to: focusTarget, from: nil)
                }
            } else if let focusedSurface = surfaceTree.first {
                // No prior focused surface or we can't find it, let's focus
                // the first.
                self.focusedSurface = focusedSurface
                DispatchQueue.main.async {
                    Ghostty.moveFocus(to: focusedSurface, from: nil)
                }
            }
        }
    }

    /// The current undo state for this controller
    var undoState: UndoState? {
        guard let window else { return nil }
        guard !surfaceTree.isEmpty else { return nil }
        return .init(
            frame: window.frame,
            surfaceTree: surfaceTree,
            focusedSurface: focusedSurface?.id,
            tabIndex: window.tabGroup?.windows.firstIndex(of: window),
            tabGroup: window.tabGroup,
            tabColor: (window as? TerminalWindow)?.tabColor ?? .none,
            titleOverride: titleOverride,
            isBackgroundOpaque: isBackgroundOpaque,
            restorable: restorable)
    }

    // MARK: - NSWindowController

    override func windowWillLoad() {
        // We do NOT want to cascade because we handle this manually from the manager.
        shouldCascadeWindows = false
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        guard let window else { return }
        Self.openControllers[ObjectIdentifier(self)] = self

        // I copy this because we may change the source in the future but also because
        // I regularly audit our codebase for "ghostty.config" access because generally
        // you shouldn't use it. Its safe in this case because for a new window we should
        // use whatever the latest app-level config is.
        let config = ghostty.config

        // Setting all three of these is required for restoration to work.
        window.isRestorable = restorable
        if restorable {
            window.restorationClass = TerminalWindowRestoration.self
            window.identifier = .init(String(describing: TerminalWindowRestoration.self))
        }

        // If we have only a single surface (no splits) and there is a default size then
        // we should resize to that default size.
        if case let .leaf(view) = surfaceTree.root {
            // If this is our first surface then our focused surface will be nil
            // so we force the focused surface to the leaf.
            focusedSurface = view
        }

        // Initialize our content view to the SwiftUI root
        let container = TerminalViewContainer {
            TerminalView(ghostty: ghostty, viewModel: uiState, delegate: self)
        }

        // Use the startup grid even when restoring or moving a split tree.
        container.initialContentSize = ghostty.initialWindowContentSize ?? NSSize(width: 800, height: 600)

        if let hidden = window as? HiddenTitlebarTerminalWindow {
            window.contentView = TerminalChromeView(content: container, window: hidden)
        } else { window.contentView = container }

        if let terminalWindow = window as? TerminalWindow,
           let size = container.initialContentSize {
            terminalWindow.fixContentSize(size)
            if let screen = window.screen ?? NSScreen.main {
                let frame = adjustForWindowPosition(frame: window.frame, on: screen)
                window.setFrameOrigin(frame.origin)
            }
        }

        // In various situations, macOS automatically tabs new windows. Ghostty handles
        // its own tabbing so we DONT want this behavior. This detects this scenario and undoes
        // it.
        //
        // Example scenarios where this happens:
        //   - When the system user tabbing preference is "always"
        //   - When the "+" button in the tab bar is clicked
        //
        // We don't run this logic in fullscreen because in fullscreen this will end up
        // removing the window and putting it into its own dedicated fullscreen, which is not
        // the expected or desired behavior of anyone I've found.
        //
        // We also only run this when the system tabbing preference is "always",
        // which is the only scenario AppKit will have auto-tabbed a fresh window
        // at this point: the tab bar "+" button goes through newWindowForTab
        // which we route through our own tab logic. This check matters because
        // accessing `window.tabGroup` materializes the window's tab group
        // machinery, which takes ~15-20ms and is otherwise not needed during
        // window creation.
        if NSWindow.userTabbingPreference == .always {
            // If we have more than 1 window in our tab group we know we're a new window.
            // Since Ghostty manages tabbing manually this will never be more than one
            // at this point in the AppKit lifecycle (we add to the group after this).
            if let tabGroup = window.tabGroup, tabGroup.windows.count > 1 {
                window.tabGroup?.removeWindow(window)
            }
        }

        // Apply any additional appearance-related properties to the new window. We
        // apply this based on the root config but change it later based on surface
        // config (see focused surface change callback).
        syncAppearance(.init(config.snapshot))
    }

    /// Setup correct window frame before showing the window
    override func showWindow(_ sender: Any?) {
        guard let terminalWindow = window as? TerminalWindow else { return }

        // Set the initial window position. This must happen after the window
        // is fully set up (content view, toolbar, default size) so that
        // decorations added by subclass configuration (e.g. toolbar for tabs
        // style) don't change the frame after the position is restored.
        let originChanged = terminalWindow.setInitialWindowPosition(
            x: derivedConfig.windowPositionX,
            y: derivedConfig.windowPositionY,
        )
        let restored = LastWindowPosition.shared.restore(
            terminalWindow,
            origin: !originChanged,
            size: false,
        )

        // If nothing is changed for the frame,
        // we should center the window
        if !originChanged, !restored {
            // This doesn't work in `windowDidLoad` somehow
            terminalWindow.center()
        }

        super.showWindow(sender)

        syncAppearance()
    }

    // Shows the "+" button in the tab bar, responds to that click.
    override func newWindowForTab(_ sender: Any?) {
        // Trigger the ghostty core event logic for a new tab.
        guard let surface = self.focusedSurface?.surfaceModel else { return }
        surface.perform(.newTab)
    }

    // MARK: NSWindowDelegate

    // TabGroupCloseCoordinator.Controller
    lazy private(set) var tabGroupCloseCoordinator = TabGroupCloseCoordinator()

    override func windowShouldClose(_ sender: NSWindow) -> Bool {
        tabGroupCloseCoordinator.windowShouldClose(sender) { [weak self] scope in
            guard let self else { return }
            switch scope {
            case .tab: closeTab(nil)
            case .window:
                guard self.window?.isFirstWindowInTabGroup ?? false else { return }
                closeWindow(nil)
            }
        }

        // We will always explicitly close the window using the above
        return false
    }

    override func windowWillClose(_ notification: Notification) {
        pendingTabRelabel?.cancel()
        pendingTabRelabel = nil
        tabOrderObservation = nil
        observedTabGroup = nil
        defer { Self.openControllers[ObjectIdentifier(self)] = nil }
        appearanceObservation?.cancel()
        ghostty.windowRegistry.windowWillClose(self, keyWindow: NSApp.keyWindow)
        super.windowWillClose(notification)
        cancelPendingInitialPresentation()
        for tab in window?.tabGroup?.windows ?? [] where tab !== window {
            (tab.windowController as? TerminalController)?.scheduleTabRelabel()
        }
    }

    override func windowDidBecomeKey(_ notification: Notification) {
        super.windowDidBecomeKey(notification)
        self.relabelTabs()
        self.fixTabBar()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard let window = notification.object as? TerminalWindow,
              window === self.window, window.fixedContentSize != nil else { return }
        // Reapply the screen constraint without changing the configured size.
        window.setFrame(window.frame, display: true)
        window.constrainToScreen()
    }

    override func windowDidMove(_ notification: Notification) {
        super.windowDidMove(notification)
        self.fixTabBar()

        // Whenever we move save our last position for the next start.
        LastWindowPosition.shared.save(window)
    }

    override func windowDidResize(_ notification: Notification) {
        super.windowDidResize(notification)

        // Whenever we resize save our last position and size for the next start.
        LastWindowPosition.shared.save(window)

        if let window = self.window as? TerminalWindow {
            // Expand the title frame to new width.
            // This is needed because when the new window size becomes bigger,
            // window's title will be clipped again.
            window.syncWindowTitleAppearance()
        }
    }

    func windowDidBecomeMain(_ notification: Notification) {
        // Whenever we get focused, use that as our last window position for
        // restart. This differs from Terminal.app but matches iTerm2 behavior
        // and I think its sensible.
        LastWindowPosition.shared.save(window)

        // Remember our last main
        ghostty.windowRegistry.didBecomeMain(self)
    }

    // Called when the window will be encoded. We handle the data encoding here in the
    // window controller.
    func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
        let data = TerminalRestorableState(from: self)
        data.encode(with: state)
    }

    // MARK: First Responder

    @IBAction func newWindow(_ sender: Any?) {
        guard let surface = focusedSurface?.surfaceModel else { return }
        surface.perform(.newWindow)
    }

    @IBAction func newTab(_ sender: Any?) {
        guard let surface = focusedSurface?.surfaceModel else { return }
        surface.perform(.newTab)
    }

    @IBAction func closeTab(_ sender: Any?) {
        guard let window = window else { return }
        guard window.tabGroup?.windows.count ?? 0 > 1 else {
            closeWindow(sender)
            return
        }

        guard surfaceTree.contains(where: { $0.needsConfirmQuit }) else {
            closeTabImmediately()
            return
        }

        confirmClose(
            messageText: "Close Tab?",
            informativeText: "The terminal still has a running process. If you close the tab the process will be killed."
        ) {
            self.closeTabImmediately()
        }
    }

    @IBAction func returnToDefaultSize(_ sender: Any?) {
        // Kept for old keybindings; window size is controlled by startup configuration.
    }

    /// A close request owns every original tab until review finishes, including idle
    /// tabs. Mark all participants so another tab cannot start an overlapping review.
    private var windowCloseInFlight = false

    @IBAction override func closeWindow(_ sender: Any?) {
        startCloseWindow()
    }

    /// The async decisions are injectable so tests can change tab membership while
    /// a review is suspended without presenting interactive sheets.
    @discardableResult
    func startCloseWindow(
        needsConfirmation: (TerminalController) -> Bool = {
            $0.surfaceTree.contains(where: { $0.needsConfirmQuit })
        },
        review: @escaping @MainActor (NSWindow, Int) async -> NSApplication.ModalResponse = { window, count in
            let alert = NSAlert.reviewWindowsAlert(
                messageText: "You have \(count) windows with running processes. Do you want to review these windows before closing?",
                terminateNowButtonTitle: "Close"
            )
            return await alert.beginSheetModal(for: window)
        },
        confirm: @escaping @MainActor (TerminalController) async -> CloseConfirmationResult = { controller in
            await controller.confirmCloseAsync(
                messageText: "Close Window?",
                informativeText: "All terminal sessions in this window will be terminated."
            )
        }
    ) -> Task<Void, Never>? {
        guard let window else { return nil }
        let targets = (window.tabGroup?.windows ?? [window]).compactMap { window -> WindowCloseTarget? in
            guard let controller = window.windowController as? TerminalController else { return nil }
            return WindowCloseTarget(controller: controller, window: window)
        }
        guard !targets.isEmpty, !targets.contains(where: { $0.controller.windowCloseInFlight }) else { return nil }
        let confirmations = targets.filter { needsConfirmation($0.controller) }
        guard !confirmations.isEmpty else {
            closeWindowImmediately()
            return nil
        }

        targets.forEach { $0.controller.windowCloseInFlight = true }
        return Task {
            defer { targets.forEach { $0.controller.windowCloseInFlight = false } }
            guard !Task.isCancelled else { return }
            if confirmations.count > 1 {
                let response = await review(window, confirmations.count)
                guard !Task.isCancelled else { return }
                switch response {
                case .alertFirstButtonReturn:
                    break
                case .alertSecondButtonReturn:
                    closeWindowTargets(targets)
                    return
                default:
                    return
                }
            }

            for target in confirmations where target.isOpen {
                guard await confirm(target.controller) == .allowed, !Task.isCancelled else { return }
            }
            closeWindowTargets(targets)
        }
    }

    @MainActor private struct WindowCloseTarget {
        let controller: TerminalController
        let window: NSWindow

        var isOpen: Bool {
            controller.isWindowLoaded && controller.window === window &&
                controller.ghostty.windowRegistry.windowControllers.contains { $0 === controller }
        }
    }

    private func closeWindowTargets(_ targets: [WindowCloseTarget]) {
        let remaining = targets.filter(\.isOpen)
        guard let first = remaining.first else { return }
        let currentWindows = first.window.tabGroup?.windows ?? [first.window]
        if currentWindows.count == remaining.count,
           currentWindows.allSatisfy({ window in remaining.contains { $0.window === window } }) {
            // Keep the existing whole-window undo when membership is unchanged.
            first.controller.closeWindowImmediately()
            return
        }

        // Never expand the approved snapshot to the current tab group. Original
        // tabs can have moved, closed, or acquired new siblings during a sheet.
        let undoManager = ghostty.undoManager
        undoManager.beginUndoGrouping()
        defer {
            undoManager.setActionName("Close Window")
            undoManager.endUndoGrouping()
        }
        for target in remaining where target.isOpen {
            target.controller.closeTabImmediately()
        }
    }

    // MARK: - TerminalViewDelegate

    override func focusedSurfaceDidChange(to: Ghostty.SurfaceView?) {
        super.focusedSurfaceDidChange(to: to)

        appearanceObservation?.cancel()
        appearanceObservation = nil
        guard let focusedSurface else { return }
        syncAppearance(focusedSurface.derivedConfig)
        let appearance = Observations { [weak focusedSurface] in
            (focusedSurface?.derivedConfig, focusedSurface?.backgroundColor)
        }
        appearanceObservation = Task { [weak self, weak focusedSurface] in
            for await _ in appearance {
                guard !Task.isCancelled else { break }
                guard let self, let focusedSurface, self.focusedSurface === focusedSurface else { break }
                syncAppearance(focusedSurface.derivedConfig)
            }
        }
    }

    override func requestNewTab(from target: Ghostty.SurfaceView, baseConfig: Ghostty.SurfaceConfiguration) {
        guard surfaceTree.contains(target), let window else { return }
        _ = Self.newTab(ghostty, from: window, withBaseConfig: baseConfig)
    }

    // MARK: - Window commands

    func moveTab(from target: Ghostty.SurfaceView, action: Ghostty.Action.MoveTab) {
        guard target == self.focusedSurface else { return }
        guard let window = self.window else { return }

        guard action.amount != 0 else { return }

        // Determine our current selected index
        guard let windowController = window.windowController else { return }
        guard let tabGroup = windowController.window?.tabGroup else { return }
        guard let selectedWindow = tabGroup.selectedWindow else { return }
        let tabbedWindows = tabGroup.windows
        guard tabbedWindows.count > 0 else { return }
        guard let selectedIndex = tabbedWindows.firstIndex(where: { $0 == selectedWindow }) else { return }

        // Determine the final index we want to insert our tab
        let finalIndex: Int
        if action.amount < 0 {
            finalIndex = selectedIndex - min(selectedIndex, -action.amount)
        } else {
            let remaining: Int = tabbedWindows.count - 1 - selectedIndex
            finalIndex = selectedIndex + min(remaining, action.amount)
        }

        // If our index is the same we do nothing
        guard finalIndex != selectedIndex else { return }

        // Let AppKit reorder the existing group in one operation. Explicitly
        // removing the selected window first tears down a two-tab group's bar.
        tabGroup.insertWindow(selectedWindow, at: finalIndex)
        tabGroup.selectedWindow = selectedWindow
        selectedWindow.makeKey()
    }

    func gotoTab(from target: Ghostty.SurfaceView, tab: Ghostty.TabDestination) {
        guard target == self.focusedSurface else { return }
        guard let window = self.window else { return }

        guard let windowController = window.windowController else { return }
        guard let tabGroup = windowController.window?.tabGroup else { return }
        let tabbedWindows = tabGroup.windows

        // This will be the index we want to actual go to
        let finalIndex: Int

        switch tab {
        case .index(let index):
            guard index >= 1 else { return }
            finalIndex = min(index - 1, tabbedWindows.count - 1)
        case .last:
            finalIndex = tabbedWindows.count - 1
        case .previous, .next:
            guard let selectedWindow = tabGroup.selectedWindow,
                  let selectedIndex = tabbedWindows.firstIndex(of: selectedWindow),
                  !tabbedWindows.isEmpty else { return }
            let offset = tab == .previous ? -1 : 1
            finalIndex = (selectedIndex + offset + tabbedWindows.count) % tabbedWindows.count
        }

        guard finalIndex >= 0 else { return }
        let targetWindow = tabbedWindows[finalIndex]
        targetWindow.makeKeyAndOrderFront(nil)
    }

    struct DerivedConfig {
        let backgroundColor: Color
        let macosWindowButtons: Ghostty.MacOSWindowButtons
        let macosTitlebarStyle: Ghostty.Config.MacOSTitlebarStyle
        let windowPositionX: Int16?
        let windowPositionY: Int16?

        init() {
            self.backgroundColor = Color(NSColor.windowBackgroundColor)
            self.macosWindowButtons = .visible
            self.macosTitlebarStyle = .default
            self.windowPositionX = nil
            self.windowPositionY = nil
        }

        init(_ config: Ghostty.ConfigSnapshot) {
            self.backgroundColor = config.backgroundColor
            self.macosWindowButtons = config.macosWindowButtons
            self.macosTitlebarStyle = config.macosTitlebarStyle
            self.windowPositionX = config.window.positionX
            self.windowPositionY = config.window.positionY
        }
    }
}

// MARK: NSMenuItemValidation

extension TerminalController {
    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(newTab(_:)), #selector(newWindowForTab(_:)):
            let available = TerminalWindow.canAddTab(to: window)
            item.toolTip = available ? nil : "Maximum 5 tabs per window"
            return available

        case #selector(closeTabsOnTheRight):
            guard let window, let tabGroup = window.tabGroup else { return false }
            guard let currentIndex = tabGroup.windows.firstIndex(of: window) else { return false }
            return tabGroup.windows.indices.contains { $0 > currentIndex }

        case #selector(returnToDefaultSize):
            return false

        default:
            return super.validateMenuItem(item)
        }
    }
}
