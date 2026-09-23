import AppKit
import SwiftUI
import CoreText
import UserNotifications

extension Ghostty {
    /// The NSView implementation for a terminal surface.
    class SurfaceView: NSView, Identifiable, Sendable {
        let id: UUID
        let state: SurfaceState

        // The current pwd of the surface as defined by the pty. This can be
        // changed with escape codes.
        var pwd: String? {
            get { state.pwd }
            set { state.pwd = newValue }
        }

        // The cell size of this surface. This is set by the core when the
        // surface is first created and any time the cell size changes (i.e.
        // when the font size changes). This is used to allow windows to be
        // resized in discrete steps of a single cell.
        var cellSize: CGSize {
            get { state.cellSize }
            set { state.cellSize = newValue }
        }

        // The health state of the surface. This currently only reflects the
        // renderer health. In the future we may want to make this an enum.
        var healthy: Bool {
            get { state.healthy }
            set { state.healthy = newValue }
        }

        // Any error while initializing the surface.
        var error: Error? {
            get { state.error }
            set { state.error = newValue }
        }

        // The hovered URL string
        var hoverUrl: String? {
            get { state.hoverUrl }
            set { state.hoverUrl = newValue }
        }

        // The currently active key tables. Empty if no tables are active.
        var keyTables: [String] {
            get { state.keyTables }
            set { state.keyTables = newValue }
        }

        // The time this surface last became focused. This is a ContinuousClock.Instant
        // on supported platforms.
        var focusInstant: ContinuousClock.Instant? {
            get { state.focusInstant }
            set { state.focusInstant = newValue }
        }

        // Returns sizing information for the surface. This is the raw C
        // structure because I'm lazy.
        var surfaceSize: Ghostty.Surface.Size? {
            get { state.surfaceSize }
            set { state.surfaceSize = newValue }
        }

        /// True when the surface is in readonly mode.
        private(set) var readonly: Bool {
            get { state.readonly }
            set { state.readonly = newValue }
        }

        private var highlightTask: Task<Void, Never>?

        /// True when the surface should show a highlight effect (e.g., when presented via goto_split).
        private(set) var highlighted: Bool {
            get { state.highlighted }
            set { state.highlighted = newValue }
        }

        /// A message sent from `ghostty_surface_t` when a child process exited
        private(set) var childExitedMessage: ChildExitedMessage? {
            get { state.childExitedMessage }
            set { state.childExitedMessage = newValue }
        }

        // The current title of the surface as defined by the pty. This can be
        // changed with escape codes.
        private(set) var title: String {
            get { state.title }
            set {
                state.title = newValue

                if !title.isEmpty {
                    titleFallbackTimer?.invalidate()
                    titleFallbackTimer = nil
                }
            }
        }

        // The progress report (if any)
        var progressReport: Action.ProgressReport? {
            get { state.progressReport }
            set {
                state.progressReport = newValue
                // Cancel any existing timer
                progressReportTimer?.invalidate()
                progressReportTimer = nil

                // If we have a new progress report, start a timer to remove it after 15 seconds
                if progressReport != nil {
                    progressReportTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: false) { [weak self] _ in
                        MainActor.assumeIsolated {
                            self?.progressReport = nil
                            self?.progressReportTimer = nil
                        }
                    }
                }
            }
        }

        // The currently active key sequence. The sequence is not active if this is empty.
        var keySequence: [KeyboardShortcut] {
            get { state.keySequence }
            set { state.keySequence = newValue }
        }

        var searchState: SearchState? {
            get { state.searchState }
            set {
                let previous = state.searchState
                previous?.stopSearching()
                state.searchState = newValue
                if let search = newValue {
                    search.startSearching { [weak self] needle in
                        self?.surfaceModel?.search(needle)
                    }
                } else if previous != nil {
                    surfaceModel?.endSearch()
                }
            }
        }

        // Cancellable for the debounced accessibility selection-change post.
        private var accessibilitySelectionTask: Task<Void, Never>?
        weak var scrollContainer: SurfaceScrollView?
        weak var inspectorView: InspectorView?

        // Whether the pointer should be visible or not
        private(set) var pointerStyle: CursorStyle {
            get { state.pointerStyle }
            set { state.pointerStyle = newValue }
        }

        // Whether the mouse is currently over this surface
        private(set) var mouseOverSurface: Bool {
            get { state.mouseOverSurface }
            set { state.mouseOverSurface = newValue }
        }

        // The last known mouse location in the surface's local coordinate space,
        // used by overlays such as the split drag handle reveal region.
        private(set) var mouseLocationInSurface: CGPoint? {
            get { state.mouseLocationInSurface }
            set { state.mouseLocationInSurface = newValue }
        }

        // Whether the cursor is currently visible (not hidden by typing, etc.)
        private(set) var cursorVisible: Bool {
            get { state.cursorVisible }
            set { state.cursorVisible = newValue }
        }

        /// Whether the belonging window is visible
        ///
        /// We track this to restore surface occlusion state
        /// after this surface is dragged to another window
        var isWindowVisible = false

        /// The configuration derived from the Ghostty config so we don't need to rely on references.
        private(set) var derivedConfig: DerivedConfig {
            get { state.derivedConfig }
            set { state.derivedConfig = newValue }
        }

        /// The background color within the color palette of the surface. This is only set if it is
        /// dynamically updated. Otherwise, the background color is the default background color.
        private(set) var backgroundColor: Color? {
            get { state.backgroundColor }
            set { state.backgroundColor = newValue }
        }

        /// True when the bell is active. This is set inactive on focus or event.
        private(set) var bell: Bool {
            get { state.bell }
            set { state.bell = newValue }
        }

        /// A clipboard confirmation waiting to be handled by its controller.
        var pendingClipboardConfirmation: ClipboardConfirmationRequest? {
            didSet { pendingClipboardConfirmationDidChange(from: oldValue) }
        }

        // An initial size to request for a window. This will only affect
        // then the view is moved to a new window.
        var initialSize: NSSize?

        // A content size received through sizeDidChange that may in some cases
        // be different from the frame size.
        private var contentSizeBacking: NSSize?
        private var contentSize: NSSize {
            get { return contentSizeBacking ?? frame.size }
            set { contentSizeBacking = newValue }
        }

        // Set whether the surface is currently on a password input or not. This is
        // detected with the set_password_input_cb on the Ghostty state.
        var passwordInput: Bool = false {
            didSet {
                // We need to update our state within the SecureInput manager.
                let input = SecureInput.shared
                let id = ObjectIdentifier(self)
                if passwordInput {
                    input.setScoped(id, focused: focused)
                } else {
                    input.removeScoped(id)
                }
            }
        }

        // Returns true if quit confirmation is required for this surface to
        // exit safely.
        var needsConfirmQuit: Bool {
            surfaceModel?.needsQuitConfirmation ?? false
        }

        // Returns true if the process in this surface has exited.
        var processExited: Bool {
            surfaceModel?.processExited ?? true
        }

        // Returns the inspector instance for this surface, or nil if the
        // surface has been closed or no inspector is active.
        var inspector: Ghostty.Inspector? {
            guard let surface = self.surfaceModel else { return nil }
            return surface.inspector
        }

        // True if the inspector should be visible
        var inspectorVisible: Bool {
            get { state.inspectorVisible }
            set {
                let oldValue = state.inspectorVisible
                state.inspectorVisible = newValue

                if oldValue && !inspectorVisible {
                    guard let surface = self.surfaceModel else { return }
                    surface.freeInspector()
                }
            }
        }

        /// Stable session ownership; detaching AppKit presentation is not teardown.
        let lifecycle = SurfaceLifecycle()
        var surfaceModel: Ghostty.Surface? { lifecycle.surface }

        /// Stable even if core surface creation fails; owns no app or views.
        let windowRegistry: WindowRegistry

        /// Current scrollbar state, cached here for persistence across rebuilds
        /// of the SwiftUI view hierarchy, for example when changing splits
        var scrollbar: Ghostty.Action.Scrollbar?

        // Notification identifiers associated with this surface
        var notificationIdentifiers: Set<String> = []

        /// Records the timestamp of the last event to performKeyEquivalent that we need to save.
        /// We currently save all commands with command or control set.
        ///
        /// For command+key inputs, the AppKit input stack calls performKeyEquivalent to give us a chance
        /// to handle them first. If we return "false" then it goes through the standard AppKit responder chain.
        /// For an NSTextInputClient, that may redirect some commands _before_ our keyDown gets called.
        /// Concretely: Command+Period will do: performKeyEquivalent, doCommand ("cancel:"). In doCommand,
        /// we need to know that we actually want to handle that in keyDown, so we send it back through the
        /// event dispatch system and use this timestamp as an identity to know to actually send it to keyDown.
        ///
        /// Why not send it to keyDown always? Because if the user rebinds a command to something we
        /// actually handle then we do want the standard response chain to handle the key input. Unfortunately,
        /// we can't know what a command is bound to at a system level until we let it flow through the system.
        /// That's the crux of the problem.
        ///
        /// So, we have to send it back through if we didn't handle it.
        ///
        /// The next part of the problem is comparing NSEvent identity seems pretty nasty. I couldn't
        /// find a good way to do it. I originally stored a weak ref and did identity comparison but that
        /// doesn't work and for reasons I couldn't figure out the value gets mangled (fields don't match
        /// before/after the assignment). I suspect it has something to do with the fact an NSEvent is wrapping
        /// a lower level event pointer and its just not surviving the Swift runtime somehow. I don't know.
        ///
        /// The best thing I could find was to store the event timestamp which has decent granularity
        /// and compare that. To further complicate things, some events are synthetic and have a zero
        /// timestamp so we have to protect against that. Fun!
        var lastPerformKeyEvent: TimeInterval?

        var markedText: NSMutableAttributedString
        private(set) var focused: Bool = true
        private var prevPressureStage: Int = 0

        // This is set to non-null during keyDown to accumulate insertText contents
        var keyTextAccumulator: [String]?
        /// Temporary lead surrogate that's waiting for the trail
        var leadSurrogate: LeadSurrogate?

        // True when we've consumed a left mouse-down only to move focus and
        // should suppress the matching mouse-up from being reported.
        private var suppressNextLeftMouseUp: Bool = false

        // A small delay that is introduced before a title change to avoid flickers
        private var titleChangeTimer: Timer?

        // A timer to fallback to ghost emoji if no title is set within the grace period
        private var titleFallbackTimer: Timer?

        // Timer to remove progress report after 15 seconds
        private var progressReportTimer: Timer?

        // This is the title from the terminal. This is nil if we're currently using
        // the terminal title as the main title property. If the title is set manually
        // by the user, this is set to the prior value (which may be empty, but non-nil).
        private(set) var titleFromTerminal: String?

        // The cached contents of the screen.
        private(set) var cachedScreenContents: CachedValue<String>
        private(set) var cachedVisibleContents: CachedValue<String>

        // We need to support being a first responder so that we can get input events
        override var acceptsFirstResponder: Bool { return true }

        init(_ owner: Ghostty.App, baseConfig: SurfaceConfiguration? = nil, uuid: UUID? = nil) {
            self.windowRegistry = owner.windowRegistry
            self.id = uuid ?? UUID()
            self.markedText = NSMutableAttributedString()

            self.state = SurfaceState(derivedConfig: DerivedConfig(owner.config.snapshot))

            // We need to initialize this so it does something but we want to set
            // it back up later so we can reference `self`. This is a hack we should
            // fix at some point.
            self.cachedScreenContents = .init(duration: .milliseconds(500)) { "" }
            self.cachedVisibleContents = self.cachedScreenContents

            // Initialize with some default frame size. The important thing is that this
            // is non-zero so that our layer bounds are non-zero so that our renderer
            // can do SOMETHING.
            super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

            // Our cache of screen data
            cachedScreenContents = .init(duration: .milliseconds(500)) { [weak self] in
                guard let self else { return "" }
                guard let surface = self.surfaceModel else { return "" }
                return surface.readContents(viewport: false)
            }
            cachedVisibleContents = .init(duration: .milliseconds(500)) { [weak self] in
                guard let self else { return "" }
                guard let surface = self.surfaceModel else { return "" }
                return surface.readContents(viewport: true)
            }

            // Set a timer to show the ghost emoji after 500ms if no title is set
            titleFallbackTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let self, self.title.isEmpty {
                        self.title = "👻"
                    }
                }
            }

            // Before we initialize the surface we want to register our notifications
            // so there is no window where we can't receive them.
            let center = NotificationCenter.default
            center.addObserver(
                self,
                selector: #selector(windowDidChangeScreen),
                name: NSWindow.didChangeScreenNotification,
                object: nil)

            // Register callbacks before creation; presentation attachment is independent.
            lifecycle.start(owner: owner, view: self, configuration: baseConfig ?? SurfaceConfiguration())
            guard lifecycle.phase == .ready else {
                self.error = Ghostty.Error.apiFailed
                return
            }

            // Setup our tracking area so we get mouse moved events
            updateTrackingAreas()

            // The UTTypes that can be dragged onto this view.
            registerForDraggedTypes(Array(Self.dropTypes))
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported for this view")
        }

        isolated deinit {
            state.searchState?.stopSearching()
            // Resolve clipboard callback state while surfaceModel is still
            // alive. The request's weak SurfaceView reference is already nil
            // during deinit, so didSet passes this instance explicitly.
            pendingClipboardConfirmation = nil

            // Remove all of our notificationcenter subscriptions
            let center = NotificationCenter.default
            center.removeObserver(self)

            highlightTask?.cancel()
            accessibilitySelectionTask?.cancel()
            titleChangeTimer?.invalidate()
            titleFallbackTimer?.invalidate()
            progressReportTimer?.invalidate()
            lifecycle.release()

            // Whenever the surface is removed, we need to note that our restorable
            // state is invalid to prevent the surface from being restored.
            invalidateRestorableState()

            trackingAreas.forEach { removeTrackingArea($0) }

            // Remove ourselves from secure input if we have to
            SecureInput.shared.removeScoped(ObjectIdentifier(self))

            // Remove any notifications associated with this surface
            let identifiers = Array(self.notificationIdentifiers)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)

        }

        func setReadonly(_ value: Bool) {
            readonly = value
        }

        /// Triggers a brief highlight animation on this surface.
        func highlight() {
            highlightTask?.cancel()
            highlighted = true
            highlightTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                self?.highlighted = false
                self?.highlightTask = nil
            }
        }

        func setChildExitedMessage(_ message: ChildExitedMessage) {
            self.childExitedMessage = message
        }

        func endSearch() {
            Ghostty.moveFocus(to: self)
            searchState = nil
        }

        func focusDidChange(_ focused: Bool) {
            guard let surface = self.surfaceModel else { return }
            guard self.focused != focused else { return }
            self.focused = focused

            // If we lost our focus then remove the mouse event suppression so
            // our mouse release event leaving the surface can properly be
            // sent to stop things like mouse selection.
            if !focused {
                suppressNextLeftMouseUp = false
            }

            // Notify libghostty
            surface.setFocus(focused)

            // Update our secure input state if we are a password input
            if passwordInput {
                SecureInput.shared.setScoped(ObjectIdentifier(self), focused: focused)
            }

            if focused {
                focusInstant = ContinuousClock.now

                // We unset our bell state if we gained focus
                bell = false

                // Remove any notifications for this surface once we gain focus.
                if !notificationIdentifiers.isEmpty {
                    UNUserNotificationCenter.current()
                        .removeDeliveredNotifications(
                            withIdentifiers: Array(notificationIdentifiers))
                    self.notificationIdentifiers = []
                }
            }
        }

        func sizeDidChange(_ size: CGSize) {
            // Ghostty wants to know the actual framebuffer size... It is very important
            // here that we use "size" and NOT the view frame. If we're in the middle of
            // an animation (i.e. a fullscreen animation), the frame will not yet be updated.
            // The size represents our final size we're going for.
            let scaledSize = self.convertToBacking(size)
            setSurfaceSize(width: UInt32(scaledSize.width), height: UInt32(scaledSize.height))
            // Store this size so we can reuse it when backing properties change
            contentSize = size
        }

        private func setSurfaceSize(width: UInt32, height: UInt32) {
            guard let surface = self.surfaceModel else { return }

            // Update our core surface
            surface.setSize(width: width, height: height)

            // Update our cached size metrics
            let size = surface.size
            DispatchQueue.main.async {
                // Publish geometry on the next main-loop turn, outside the
                // SwiftUI layout update that requested the native resize.
                self.surfaceSize = size
            }
        }

        func setCursorShape(_ style: CursorStyle) {
            pointerStyle = style
        }

        func setCursorVisibility(_ visible: Bool) {
            cursorVisible = visible
            // Technically this action could be called anytime we want to
            // change the mouse visibility but at the time of writing this
            // mouse-hide-while-typing is the only use case so this is the
            // preferred method.
            NSCursor.setHiddenUntilMouseMoves(!visible)
        }

        /// Set the title by prompting the user.
        func promptTitle() {
            // Create an alert dialog
            let alert = NSAlert()
            alert.messageText = "Change Terminal Title"
            alert.informativeText = "Leave blank to restore the default."
            alert.alertStyle = .informational

            // Add a text field to the alert
            let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
            textField.stringValue = title
            alert.accessoryView = textField

            // Add buttons
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")

            // Make the text field the first responder so it gets focus
            alert.window.initialFirstResponder = textField

            let completionHandler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                guard let self else { return }

                // Check if the user clicked "OK"
                guard response == .alertFirstButtonReturn  else { return }

                // Get the input text
                let newTitle = textField.stringValue
                if newTitle.isEmpty {
                    // Empty means that user wants the title to be set automatically
                    // We also need to reload the config for the "title" property to be
                    // used again by this tab.
                    let prevTitle = titleFromTerminal ?? "👻"
                    titleFromTerminal = nil
                    setTitle(prevTitle)
                } else {
                    // Set the title and prevent it from being changed automatically
                    titleFromTerminal = title
                    title = newTitle
                }
            }

            // We prefer to run our alert in a sheet modal if we have a window.
            if let window {
                alert.beginSheetModal(for: window, completionHandler: completionHandler)
            } else {
                // On macOS 26 RC, this codepath results in the "OK" button not being
                // visible. The above codepath should be taken most times but I'm just
                // noting this as something I noticed consistently.
                completionHandler(alert.runModal())
            }
        }

        func restoreTitle(_ savedTitle: String?, isUserSet: Bool) {
            guard let savedTitle else { return }
            title = savedTitle
            if isUserSet { titleFromTerminal = savedTitle }
        }

        func setTitle(_ title: String) {
            // This fixes an issue where very quick changes to the title could
            // cause an unpleasant flickering. We set a timer so that we can
            // coalesce rapid changes. The timer is short enough that it still
            // feels "instant".
            titleChangeTimer?.invalidate()
            titleChangeTimer = Timer.scheduledTimer(
                withTimeInterval: 0.075,
                repeats: false
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    // Set the title if it wasn't manually set.
                    guard self?.titleFromTerminal == nil else {
                        self?.titleFromTerminal = title
                        return
                    }
                    self?.title = title
                }
            }
        }

        // MARK: Local Events

        private func localEventHandler(_ event: NSEvent) -> NSEvent? {
            return switch event.type {
            case .keyUp:
                localEventKeyUp(event)

            case .leftMouseDown:
                localEventLeftMouseDown(event)

            default:
                event
            }
        }

        private func localEventLeftMouseDown(_ event: NSEvent) -> NSEvent? {
            let isCommandPaletteVisible = (event.window?.windowController as? BaseTerminalController)?
                .commandPaletteIsShowing == true
            guard !isCommandPaletteVisible else {
                // We don't want to process events that
                // are supposed to be handled by CommandPaletteView
                return event
            }

            // We only want to process events that are on this window.
            guard let window,
                  event.window != nil,
                  window == event.window else { return event }

            // The clicked location in this window should be this view.
            guard
                let location = window.contentView?.convert(event.locationInWindow, from: nil)
            else {
                return event
            }
            // We should use window to perform hitTest here,
            // because there could be some other overlays on top, like search bar
            guard window.contentView?.hitTest(location) == self else { return event }

            // We always assume that we're resetting our mouse suppression
            // unless we see the specific scenario below to set it.
            suppressNextLeftMouseUp = false

            // If we're already the first responder then no focus transfer is
            // happening, so the click should continue as normal.
            guard window.firstResponder !== self else {
                return event
            }

            // If our window/app is already focused, then this click is only
            // being used to transfer split focus. Consume it so it does not
            // get forwarded to the terminal as a mouse click.
            if NSApp.isActive && window.isKeyWindow {
                window.makeFirstResponder(self)
                suppressNextLeftMouseUp = true
                return nil
            }

            // Make ourselves the first responder
            window.makeFirstResponder(self)

            // We have to keep processing the event so that AppKit can properly
            // focus the window and dispatch events. If you return nil here then
            // nobody gets a windowDidBecomeKey event and so on.
            return event
        }

        private func localEventKeyUp(_ event: NSEvent) -> NSEvent? {
            // We only care about events with "command" because all others will
            // trigger the normal responder chain.
            if !event.modifierFlags.contains(.command) { return event }

            // Command keyUp events are never sent to the normal responder chain
            // so we send them here.
            guard focused else { return event }
            self.keyUp(with: event)
            return nil
        }

        // MARK: - Core State Updates

        // Preserve deferred presentation updates to avoid reentering view updates
        // from synchronous core callbacks.
        func updateRendererHealth(_ health: Bool) {
            DispatchQueue.main.async { [weak self] in
                self?.healthy = health
            }
        }

        func continueKeySequence(_ key: KeyboardShortcut) {
            DispatchQueue.main.async { [weak self] in
                self?.keySequence.append(key)
            }
        }

        func endKeySequence() {
            DispatchQueue.main.async { [weak self] in
                self?.keySequence = []
            }
        }

        func updateKeyTable(_ action: Ghostty.Action.KeyTable) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch action {
                case .activate(let name):
                    self.keyTables.append(name)
                case .deactivate:
                    _ = self.keyTables.popLast()
                case .deactivateAll:
                    self.keyTables.removeAll()
                }
            }
        }

        // MARK: - Notifications

        func acceptConfiguration(_ config: Ghostty.Config) {
            // Update our derived config
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.derivedConfig = DerivedConfig(config.snapshot)

                // If the cached OSC 11 background color disagrees with the new
                // config-derived background, drop it so window chrome follows
                // the new config (e.g., on light/dark theme auto-switch). The
                // cached value is restored next time the terminal emits a
                // color_change.
                if let cached = self.backgroundColor,
                   cached != self.derivedConfig.backgroundColor {
                    self.backgroundColor = nil
                }
            }
        }

        func acceptColorChange(_ change: Ghostty.Action.ColorChange) {
            switch change.kind {
            case .background:
                DispatchQueue.main.async { [weak self] in
                    self?.backgroundColor = change.color
                }

            default:
                // We don't do anything for the other colors yet.
                break
            }
        }

        func ringBell() {
            bell = true
            (windowRegistry.owner(of: self)?.ghostty.delegate as? AppDelegate)?.ringBell()
        }

        func selectionDidChange() {
            highlightTask?.cancel()
            accessibilitySelectionTask?.cancel()
            accessibilitySelectionTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard !Task.isCancelled, let self else { return }
                NSAccessibility.post(element: self, notification: .selectedTextChanged)
            }
        }

        func updateScrollbar(_ value: Ghostty.Action.Scrollbar) {
            state.scrollbar = value
            scrollContainer?.handleScrollbarUpdate(value)
        }

        func controlInspector(_ visibility: Ghostty.Inspector.Visibility) {
            switch visibility {
            case .toggle: inspectorVisible.toggle()
            case .show: inspectorVisible = true
            case .hide: inspectorVisible = false
            }
        }

        @objc private func windowDidChangeScreen(notification: SwiftUI.Notification) {
            guard let window = self.window else { return }
            guard let object = notification.object as? NSWindow, window == object else { return }
            guard let screen = window.screen else { return }
            guard let surface = self.surfaceModel else { return }

            // When the window changes screens, we need to update libghostty with the screen
            // ID. If vsync is enabled, this will be used with the CVDisplayLink to ensure
            // the proper refresh rate is going.
            surface.setDisplayID(screen.displayID ?? 0)

            // We also just trigger a backing property change. Just in case the screen has
            // a different scaling factor, this ensures that we update our content scale.
            // Issue: https://github.com/ghostty-org/ghostty/issues/2731
            DispatchQueue.main.async { [weak self] in
                self?.viewDidChangeBackingProperties()
            }
        }

        // MARK: - NSView

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if window !== newWindow {
                lifecycle.detach()
                focusDidChange(false)
                isWindowVisible = false
                surfaceModel?.setVisible(false)
            }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            lifecycle.attach(to: window) { [weak self] event in
                guard let self else { return event }
                return self.localEventHandler(event)
            }
            state.windowFocused = window?.isKeyWindow ?? false
            guard let window else { return }
            isWindowVisible = window.occlusionState.contains(.visible)
            surfaceModel?.setVisible(isWindowVisible)
            windowDidChangeScreen(notification: .init(name: NSWindow.didChangeScreenNotification, object: window))
            windowRegistry.owner(of: self)?.surfaceDidAttach(self)
        }

        override func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder()
            if result { focusDidChange(true) }
            return result
        }

        override func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder()

            // We sometimes call this manually (see SplitView) as a way to force us to
            // yield our focus state.
            if result { focusDidChange(false) }

            return result
        }

        override func updateTrackingAreas() {
            // To update our tracking area we just recreate it all.
            trackingAreas.forEach { removeTrackingArea($0) }

            // This tracking area is across the entire frame to notify us of mouse movements.
            addTrackingArea(NSTrackingArea(
                rect: frame,
                options: [
                    .mouseEnteredAndExited,
                    .mouseMoved,

                    // Only send mouse events that happen in our visible (not obscured) rect
                    .inVisibleRect,

                    // We want active always because we want to still send mouse reports
                    // even if we're not focused or key.
                    .activeAlways,
                ],
                owner: self,
                userInfo: nil))
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()

            // The Core Animation compositing engine uses the layer's contentsScale property
            // to determine whether to scale its contents during compositing. When the window
            // moves between a high DPI display and a low DPI display, or the user modifies
            // the DPI scaling for a display in the system settings, this can result in the
            // layer being scaled inappropriately. Since we handle the adjustment of scale
            // and resolution ourselves below, we update the layer's contentsScale property
            // to match the window's backingScaleFactor, so as to ensure it is not scaled by
            // the compositor.
            //
            // Ref: High Resolution Guidelines for OS X
            // https://developer.apple.com/library/archive/documentation/GraphicsAnimation/Conceptual/HighResolutionOSX/CapturingScreenContents/CapturingScreenContents.html#//apple_ref/doc/uid/TP40012302-CH10-SW27
            if let window = window {
                CATransaction.begin()
                // Disable the implicit transition animation that Core Animation applies to
                // property changes. Otherwise it will apply a scale animation to the layer
                // contents which looks pretty janky.
                CATransaction.setDisableActions(true)
                layer?.contentsScale = window.backingScaleFactor
                CATransaction.commit()
            }

            guard let surface = self.surfaceModel else { return }

            // Detect our X/Y scale factor so we can update our surface
            let fbFrame = self.convertToBacking(self.frame)
            let xScale = fbFrame.size.width / self.frame.size.width
            let yScale = fbFrame.size.height / self.frame.size.height
            surface.setContentScale(x: xScale, y: yScale)

            // When our scale factor changes, so does our fb size so we send that too
            let scaledSize = self.convertToBacking(contentSize)
            setSurfaceSize(width: UInt32(scaledSize.width), height: UInt32(scaledSize.height))
        }

        override func mouseDown(with event: NSEvent) {
            guard let surface = self.surfaceModel else { return }
            let mods = Ghostty.Input.Mods(nsFlags: event.modifierFlags)
            surface.sendMouseButton(.init(action: .press, button: .left, mods: mods))
        }

        override func mouseUp(with event: NSEvent) {
            // If this mouse-up corresponds to a focus-only click transfer,
            // suppress it so we don't emit a release without a press.
            if suppressNextLeftMouseUp {
                suppressNextLeftMouseUp = false
                return
            }

            // Always reset our pressure when the mouse goes up
            prevPressureStage = 0

            // If we have an active surface, report the event
            guard let surface = self.surfaceModel else { return }
            let mods = Ghostty.Input.Mods(nsFlags: event.modifierFlags)
            surface.sendMouseButton(.init(action: .release, button: .left, mods: mods))

            // Release pressure
            surface.sendPressure(stage: 0, pressure: 0)
        }

        override func otherMouseDown(with event: NSEvent) {
            guard let surface = self.surfaceModel else { return }
            let mods = Ghostty.Input.Mods(nsFlags: event.modifierFlags)
            let button = Ghostty.Input.MouseButton(fromNSEventButtonNumber: event.buttonNumber)
            surface.sendMouseButton(.init(action: .press, button: button, mods: mods))
        }

        override func otherMouseUp(with event: NSEvent) {
            guard let surface = self.surfaceModel else { return }
            let mods = Ghostty.Input.Mods(nsFlags: event.modifierFlags)
            let button = Ghostty.Input.MouseButton(fromNSEventButtonNumber: event.buttonNumber)
            surface.sendMouseButton(.init(action: .release, button: button, mods: mods))
        }

        override func rightMouseDown(with event: NSEvent) {
            guard let surface = self.surfaceModel else { return super.rightMouseDown(with: event) }

            let mods = Ghostty.Input.Mods(nsFlags: event.modifierFlags)
            if surface.sendMouseButton(.init(action: .press, button: .right, mods: mods)) {
                // Consumed
                return
            }

            // Mouse event not consumed
            super.rightMouseDown(with: event)
        }

        override func rightMouseUp(with event: NSEvent) {
            guard let surface = self.surfaceModel else { return super.rightMouseUp(with: event) }

            let mods = Ghostty.Input.Mods(nsFlags: event.modifierFlags)
            if surface.sendMouseButton(.init(action: .release, button: .right, mods: mods)) {
                // Handled
                return
            }

            // Mouse event not consumed
            super.rightMouseUp(with: event)
        }

        override func mouseEntered(with event: NSEvent) {
            mouseOverSurface = true
            super.mouseEntered(with: event)

            let pos = self.convert(event.locationInWindow, from: nil)
            mouseLocationInSurface = pos

            guard let surfaceModel else { return }

            // On mouse enter we need to reset our cursor position. This is
            // super important because we set it to -1/-1 on mouseExit and
            // lots of mouse logic (i.e. whether to send mouse reports) depend
            // on the position being in the viewport if it is.
            let mouseEvent = Ghostty.Input.MousePosEvent(
                x: pos.x,
                y: frame.height - pos.y,
                mods: .init(nsFlags: event.modifierFlags)
            )
            surfaceModel.sendMousePos(mouseEvent)
        }

        override func mouseExited(with event: NSEvent) {
            mouseOverSurface = false
            mouseLocationInSurface = nil
            guard let surfaceModel else { return }

            // If the mouse is being dragged then we don't have to emit
            // this because we get mouse drag events even if we've already
            // exited the viewport (i.e. mouseDragged)
            if NSEvent.pressedMouseButtons != 0 {
                return
            }

            // Negative values indicate cursor has left the viewport
            let mouseEvent = Ghostty.Input.MousePosEvent(
                x: -1,
                y: -1,
                mods: .init(nsFlags: event.modifierFlags)
            )
            surfaceModel.sendMousePos(mouseEvent)
        }

        override func mouseMoved(with event: NSEvent) {
            let pos = self.convert(event.locationInWindow, from: nil)
            mouseLocationInSurface = pos

            guard let surfaceModel else { return }

            // Convert window position to view position. Note (0, 0) is bottom left.
            let mouseEvent = Ghostty.Input.MousePosEvent(
                x: pos.x,
                y: frame.height - pos.y,
                mods: .init(nsFlags: event.modifierFlags)
            )
            surfaceModel.sendMousePos(mouseEvent)

            // Handle focus-follows-mouse
            if let window,
               let controller = window.windowController as? BaseTerminalController,
               !controller.commandPaletteIsShowing,
               window.isKeyWindow &&
                    !self.focused &&
                    controller.focusFollowsMouse {
                Ghostty.moveFocus(to: self)
            }
        }

        override func mouseDragged(with event: NSEvent) {
            self.mouseMoved(with: event)
        }

        override func rightMouseDragged(with event: NSEvent) {
            self.mouseMoved(with: event)
        }

        override func otherMouseDragged(with event: NSEvent) {
            self.mouseMoved(with: event)
        }

        override func scrollWheel(with event: NSEvent) {
            guard let surfaceModel else { return }

            var x = event.scrollingDeltaX
            var y = event.scrollingDeltaY
            let precision = event.hasPreciseScrollingDeltas

            if precision {
                // We do a 2x speed multiplier. This is subjective, it "feels" better to me.
                x *= 2
                y *= 2

                // TODO(mitchellh): do we have to scale the x/y here by window scale factor?
            }

            let scrollEvent = Ghostty.Input.MouseScrollEvent(
                x: x,
                y: y,
                mods: .init(precision: precision, momentum: .init(event.momentumPhase))
            )
            surfaceModel.sendMouseScroll(scrollEvent)
        }

        override func pressureChange(with event: NSEvent) {
            guard let surface = self.surfaceModel else { return }

            // Notify Ghostty first. We do this because this will let Ghostty handle
            // state setup that we'll need for later pressure handling (such as
            // QuickLook)
            surface.sendPressure(stage: UInt32(event.stage), pressure: Double(event.pressure))

            // Pressure stage 2 is force click. We only want to execute this on the
            // initial transition to stage 2, and not for any repeated events.
            guard self.prevPressureStage < 2 else { return }
            prevPressureStage = event.stage
            guard event.stage == 2 else { return }

            // If the user has force click enabled then we do a quick look. There
            // is no public API for this as far as I can tell.
            guard UserDefaults.ghostty.bool(forKey: "com.apple.trackpad.forceClick") else { return }
            quickLook(with: event)
        }

        override func quickLook(with event: NSEvent) {
            guard let surface = self.surfaceModel else { return super.quickLook(with: event) }

            // Grab the text under the cursor
            guard let text = surface.quickLookWord else { return super.quickLook(with: event) }
            guard !text.text.isEmpty  else { return super.quickLook(with: event) }

            // If we can get a font then we use the font. This should always work
            // since we always have a primary font. The only scenario this doesn't
            // work is if someone is using a non-CoreText build which would be
            // unofficial.
            var attributes: [ NSAttributedString.Key: Any ] = [:]
            if let font = surface.font {
            attributes[.font] = font
        }

            // Ghostty coordinate system is top-left, convert to bottom-left for AppKit
            let pt = NSPoint(x: text.topLeft.x, y: frame.size.height - text.topLeft.y)
            let str = NSAttributedString.init(string: text.text, attributes: attributes)
            self.showDefinition(for: str, at: pt)
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            // We only support right-click menus
            switch event.type {
            case .rightMouseDown:
                // Good
                break

            case .leftMouseDown:
                if !event.modifierFlags.contains(.control) {
                    return nil
                }

                // In this case, AppKit calls menu BEFORE calling any mouse events.
                // If mouse capturing is enabled then we never show the context menu
                // so that we can handle ctrl+left-click in the terminal app.
                guard let surfaceModel else { return nil }
                if surfaceModel.mouseCaptured {
                    return nil
                }

                // If we return a non-nil menu then mouse events will never be
                // processed by the core, so we need to manually send a right
                // mouse down event.
                //
                // Note this never sounds a right mouse up event but that's the
                // same as normal right-click with capturing disabled from AppKit.
                surfaceModel.sendMouseButton(.init(
                    action: .press,
                    button: .right,
                    mods: .init(nsFlags: event.modifierFlags)))

            default:
                return nil
            }

            let menu = NSMenu()

            // We just use a floating var so we can easily setup metadata on each item
            // in a row without storing it all.
            var item: NSMenuItem

            // If we have a selection, add copy
            if let text = self.accessibilitySelectedText(), text.count > 0 {
                menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
            }
            menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")

            menu.addItem(.separator())
            item = menu.addItem(withTitle: "Split Right", action: #selector(splitRight(_:)), keyEquivalent: "")
            item.setImageIfDesired(systemSymbolName: "rectangle.righthalf.inset.filled")
            item = menu.addItem(withTitle: "Split Left", action: #selector(splitLeft(_:)), keyEquivalent: "")
            item.setImageIfDesired(systemSymbolName: "rectangle.leadinghalf.inset.filled")
            item = menu.addItem(withTitle: "Split Down", action: #selector(splitDown(_:)), keyEquivalent: "")
            item.setImageIfDesired(systemSymbolName: "rectangle.bottomhalf.inset.filled")
            item = menu.addItem(withTitle: "Split Up", action: #selector(splitUp(_:)), keyEquivalent: "")
            item.setImageIfDesired(systemSymbolName: "rectangle.tophalf.inset.filled")

            menu.addItem(.separator())
            item = menu.addItem(withTitle: "Reset Terminal", action: #selector(resetTerminal(_:)), keyEquivalent: "")
            item.setImageIfDesired(systemSymbolName: "arrow.trianglehead.2.clockwise")
            item = menu.addItem(withTitle: "Toggle Terminal Inspector", action: #selector(toggleTerminalInspector(_:)), keyEquivalent: "")
            item.setImageIfDesired(systemSymbolName: "scope")
            item = menu.addItem(withTitle: "Terminal Read-only", action: #selector(toggleReadonly(_:)), keyEquivalent: "")
            item.setImageIfDesired(systemSymbolName: "eye.fill")
            item.state = readonly ? .on : .off
            menu.addItem(.separator())
            item = menu.addItem(withTitle: "Change Tab Title...", action: #selector(BaseTerminalController.changeTabTitle(_:)), keyEquivalent: "")
            item.setImageIfDesired(systemSymbolName: "pencil.line")
            item = menu.addItem(withTitle: "Change Terminal Title...", action: #selector(changeTitle(_:)), keyEquivalent: "")

            return menu
        }

        // MARK: Menu Handlers

        private func performMenuCommand(_ command: Ghostty.Surface.Command) {
            guard let surface = surfaceModel else { return }
            if !surface.perform(command) {
                AppDelegate.logger.warning("action failed action=\(String(describing: command), privacy: .public)")
            }
        }

        @IBAction func copy(_ sender: Any?) {
            performMenuCommand(.copy)
        }

        @IBAction func paste(_ sender: Any?) {
            performMenuCommand(.paste)
        }

        @IBAction func pasteAsPlainText(_ sender: Any?) {
            performMenuCommand(.paste)
        }

        @IBAction func pasteSelection(_ sender: Any?) {
            performMenuCommand(.pasteSelection)
        }

        @IBAction override func selectAll(_ sender: Any?) {
            performMenuCommand(.selectAll)
        }

        @IBAction func find(_ sender: Any?) {
            performMenuCommand(.startSearch)
        }

        @IBAction func selectionForFind(_ sender: Any?) {
            performMenuCommand(.searchSelection)
        }

        @IBAction func scrollToSelection(_ sender: Any?) {
            performMenuCommand(.scrollToSelection)
        }

        @IBAction func findNext(_ sender: Any?) {
            _ = self.navigateSearchToNext()
        }

        @IBAction func findPrevious(_ sender: Any?) {
            _ = navigateSearchToPrevious()
        }

        @IBAction func findHide(_ sender: Any?) {
            surfaceModel?.endSearch()
        }

        @IBAction func toggleReadonly(_ sender: Any?) {
            performMenuCommand(.toggleReadonly)
        }

        @IBAction func splitRight(_ sender: Any) {
            guard let surface = self.surfaceModel else { return }
            surface.split(.right)
        }

        @IBAction func splitLeft(_ sender: Any) {
            guard let surface = self.surfaceModel else { return }
            surface.split(.left)
        }

        @IBAction func splitDown(_ sender: Any) {
            guard let surface = self.surfaceModel else { return }
            surface.split(.down)
        }

        @IBAction func splitUp(_ sender: Any) {
            guard let surface = self.surfaceModel else { return }
            surface.split(.up)
        }

        @objc func resetTerminal(_ sender: Any) {
            performMenuCommand(.reset)
        }

        @objc func toggleTerminalInspector(_ sender: Any) {
            performMenuCommand(.toggleInspector)
        }

        @IBAction func changeTitle(_ sender: Any) {
            promptTitle()
        }

        struct DerivedConfig {
            let backgroundColor: Color
            let backgroundOpacity: Double
            let backgroundBlur: Ghostty.Config.BackgroundBlur
            let macosWindowShadow: Bool
            let windowTitleFontFamily: String?
            let windowAppearance: NSAppearance?
            let scrollbar: Ghostty.Config.Scrollbar

            init() {
                self.backgroundColor = Color(NSColor.windowBackgroundColor)
                self.backgroundOpacity = 1
                self.backgroundBlur = .disabled
                self.macosWindowShadow = true
                self.windowTitleFontFamily = nil
                self.windowAppearance = nil
                self.scrollbar = .system
            }

            init(_ config: Ghostty.ConfigSnapshot) {
                self.backgroundColor = config.backgroundColor
                self.backgroundOpacity = config.backgroundOpacity
                self.backgroundBlur = config.backgroundBlur
                self.macosWindowShadow = config.macosWindowShadow
                self.windowTitleFontFamily = config.window.titleFontFamily
                self.windowAppearance = .init(ghosttyConfig: config)
                self.scrollbar = config.scrollbar
            }
        }

    }
}

// MARK: Clipboard Confirmation

extension Ghostty.SurfaceView {
    /// Cancel the request that a new published value replaces or clears.
    private func pendingClipboardConfirmationDidChange(
        from previous: Ghostty.ClipboardConfirmationRequest?
    ) {
        guard previous !== pendingClipboardConfirmation else { return }
        previous?.cancel(from: self)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.windowRegistry.owner(of: self)?.clipboardConfirmationDidChange(for: self)
        }
    }
}

// MARK: Services

// https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/Articles/using.html
extension Ghostty.SurfaceView: NSServicesMenuRequestor {
    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        // This function confused me a bit so I'm going to add my own commentary on
        // how this works. macOS sends this callback with the given send/return types and
        // we must return the responder capable of handling the COMBINATION of those send
        // and return types (or super up if we can't handle it).
        //
        // The "COMBINATION" bit is key: we might get sent a string (we can handle that)
        // but get requested an image (we can't handle that at the time of writing this),
        // so we must bubble up.

        // Types we can receive
        let receivable: [NSPasteboard.PasteboardType] = [.string, .init("public.utf8-plain-text")]

        // Types that we can send. Currently the same as receivable but I'm separating
        // this out so we can modify this in the future.
        let sendable: [NSPasteboard.PasteboardType] = receivable

        // The sendable types that require a selection (currently all)
        let sendableRequiresSelection = sendable

        // If we expect no data to be sent/received we can obviously handle it (that's
        // the nil check), otherwise it must conform to the types we support on both sides.
        if (returnType == nil || receivable.contains(returnType!)) &&
            (sendType == nil || sendable.contains(sendType!)) {
            // If we're expected to send back a type that requires selection, then
            // verify that we have a selection. We do this within this block because
            // validateRequestor is called a LOT and we want to prevent unnecessary
            // performance hits because `ghostty_surface_has_selection` isn't free.
            if let sendType, sendableRequiresSelection.contains(sendType) {
                if surfaceModel?.hasSelection != true {
                    return super.validRequestor(forSendType: sendType, returnType: returnType)
                }
            }

            return self
        }

        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func writeSelection(
        to pboard: NSPasteboard,
        types: [NSPasteboard.PasteboardType]
    ) -> Bool {
        guard let surface = self.surfaceModel else { return false }

        // Read the selection
        guard let text = surface.selection else { return false }

        pboard.declareTypes([.string], owner: nil)
        pboard.setString(text.text, forType: .string)
        return true
    }

    func readSelection(from pboard: NSPasteboard) -> Bool {
        guard let str = pboard.getOpinionatedStringContents() else { return false }

        surfaceModel?.sendText(str)

        return true
    }
}

// MARK: NSMenuItemValidation

extension Ghostty.SurfaceView: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(pasteSelection):
            let pb = NSPasteboard.ghosttySelection
            guard let str = pb.getOpinionatedStringContents() else { return false }
            return !str.isEmpty

        case #selector(findHide):
            return searchState != nil

        case #selector(toggleReadonly):
            item.state = readonly ? .on : .off
            return true

        case #selector(copy(_:)):
            // We only enable copy menu item when there're actual selected text
            if let text = self.accessibilitySelectedText(), text.count > 0 {
                return true
            } else {
                return false
            }

        default:
            return true
        }
    }
}

// MARK: NSDraggingDestination

extension Ghostty.SurfaceView {
    static let dropTypes: Set<NSPasteboard.PasteboardType> = [
        .string,
        .fileURL,
    ]

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let types = sender.draggingPasteboard.types else { return [] }

        // If the dragging object contains none of our types then we return none.
        // This shouldn't happen because AppKit should guarantee that we only
        // receive types we registered for but its good to check.
        if Set(types).isDisjoint(with: Self.dropTypes) {
            return []
        }

        // We use copy to get the proper icon
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard

        let content = pb.getOpinionatedStringContents()

        if let content {
            DispatchQueue.main.async {
                self.surfaceModel?.sendText(content)
            }
            return true
        }

        return false
    }
}
