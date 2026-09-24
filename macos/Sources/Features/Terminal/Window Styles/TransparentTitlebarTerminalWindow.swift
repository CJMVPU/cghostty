import AppKit

/// A terminal window style that provides a transparent titlebar effect. With this effect, the titlebar
/// matches the background color of the window.
class TransparentTitlebarTerminalWindow: TerminalWindow {
    /// Stores the last surface configuration to reapply appearance when needed.
    /// This is necessary because various macOS operations (tab switching, tab bar
    /// visibility changes) can reset the titlebar appearance.
    private var lastSurfaceConfig: Ghostty.SurfaceView.DerivedConfig?

    /// KVO observation for tab group window changes.
    private weak var observedTabGroup: NSWindowTabGroup?
    private var tabGroupWindowsObservation: NSKeyValueObservation?
    private var tabBarVisibleObservation: NSKeyValueObservation?
    private var appearanceScheduled = false
    private var observationScheduled = false
    private weak var observedTitlebar: NSView?
    private var titlebarFrameObserver: NSObjectProtocol?

    isolated deinit {
        if let titlebarFrameObserver { NotificationCenter.default.removeObserver(titlebarFrameObserver) }
        tabGroupWindowsObservation?.invalidate()
        tabBarVisibleObservation?.invalidate()
    }

    // MARK: NSWindow

    override func configure(for app: Ghostty.App) {
        super.configure(for: app)

        // Setup all the KVO we will use, see the docs for the respective functions
        // to learn why we need KVO.
        setupKVO()
    }

    override func becomeMain() {
        super.becomeMain()

        scheduleAppearance()
    }

    override func addTitlebarAccessoryViewController(_ childViewController: NSTitlebarAccessoryViewController) {
        super.addTitlebarAccessoryViewController(childViewController)
        scheduleAppearance()
    }

    override func removeTitlebarAccessoryViewController(at index: Int) {
        super.removeTitlebarAccessoryViewController(at: index)
        scheduleAppearance()
    }

    private func scheduleAppearance() {
        guard !appearanceScheduled else { return }
        appearanceScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.appearanceScheduled = false
            guard let config = self.lastSurfaceConfig else { return }
            self.syncAppearance(config)
        }
    }

    // MARK: Appearance

    override func syncAppearance(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        super.syncAppearance(surfaceConfig)
        // override appearance based on the terminal's background color
        if let preferredBackgroundColor {
            appearance = (preferredBackgroundColor.isLightColor ? NSAppearance(named: .aqua) : NSAppearance(named: .darkAqua))
        }

        // Save our config in case we need to reapply
        lastSurfaceConfig = surfaceConfig

        // Every time we change appearance, set KVO up again in case any of our
        // references changed (e.g. tabGroup is new).
        setupKVO()

        // When we have transparency, we need to set the titlebar background to match the
        // window background but with opacity. The window background is set using the
        // "preferred background color" property.
        //
        // Even if we aren't transparent, we still set this because this becomes the
        // color of the titlebar in native fullscreen view.
        if let titlebarView = titlebarContainer?.firstDescendant(withClassName: "NSTitlebarView") {
            titlebarView.wantsLayer = true

            // For glass background styles, use a transparent titlebar to let the glass effect show through
            // Only apply this for transparent and tabs titlebar styles
            let isGlassStyle = derivedConfig.backgroundBlur.isGlassStyle
            let isTransparentTitlebar = derivedConfig.macosTitlebarStyle == .transparent ||
            derivedConfig.macosTitlebarStyle == .tabs

            titlebarView.layer?.backgroundColor = (isGlassStyle && isTransparentTitlebar)
                ? NSColor.clear.cgColor
                : preferredBackgroundColor?.cgColor
        }

        observeTitlebarGeometry()

        // In all cases, we have to hide the background view since this has multiple subviews
        // that force a background color.
        titlebarBackgroundView?.isHidden = true
    }

    private func observeTitlebarGeometry() {
        let view = titlebarContainer
        guard observedTitlebar !== view else { return }
        if let titlebarFrameObserver { NotificationCenter.default.removeObserver(titlebarFrameObserver) }
        titlebarFrameObserver = nil
        observedTitlebar = view
        guard let view else { return }
        view.postsFrameChangedNotifications = true
        titlebarFrameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: view, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleAppearance() }
        }
    }

    // MARK: View Finders

    private var titlebarBackgroundView: NSView? {
        titlebarContainer?.firstDescendant(withClassName: "NSTitlebarBackgroundView")
    }

    // MARK: Tab Group Observation

    private func setupKVO() {
        // This can run from one of the observation callbacks below. Replacing
        // an observation before its callback returns leaves the window retained
        // by AppKit, so always rebind on the next main-queue turn.
        guard !observationScheduled else { return }
        observationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.observationScheduled = false

            // Recheck because the tab group and observation state may have changed
            // while this work was waiting on the main queue.
            let currentTabGroup = self.tabGroup
            let observationsValid = currentTabGroup == nil || (
                self.tabGroupWindowsObservation != nil &&
                self.tabBarVisibleObservation != nil
            )

            // Keep the existing observations when they already match.
            guard self.observedTabGroup !== currentTabGroup || !observationsValid else { return }

            self.observedTabGroup = currentTabGroup
            self.setupTabGroupObservation()
            self.setupTabBarVisibleObservation()
        }
    }

    /// Monitors the tabGroup windows value for any changes and resyncs the appearance on change.
    /// This is necessary because when the windows change, the tab bar and titlebar are recreated
    /// which breaks our changes.
    private func setupTabGroupObservation() {
        // Remove existing observation if any
        tabGroupWindowsObservation?.invalidate()
        tabGroupWindowsObservation = nil

        // Check if tabGroup is available
        guard let tabGroup else { return }

        // Set up KVO observation for the windows array. Whenever it changes
        // we resync the appearance because it can cause macOS to redraw the
        // tab bar.
        tabGroupWindowsObservation = tabGroup.observe(
            \.windows,
             options: [.new]
        ) { [weak self] _, _ in
            // NOTE: At one point, I guarded this on only if we went from 0 to N
            // or N to 0 under the assumption that the tab bar would only get
            // replaced on those cases. This turned out to be false (Tahoe).
            // It's cheap enough to always redraw this so we should just do it
            // unconditionally.

            // AppKit tab-group mutations deliver KVO on the main thread.
            MainActor.assumeIsolated {
                self?.scheduleAppearance()
            }
        }
    }

    /// Monitors the tab bar for visibility. This lets the "Show/Hide Tab Bar" manual menu item
    /// to not break our appearance.
    private func setupTabBarVisibleObservation() {
        // Remove existing observation if any
        tabBarVisibleObservation?.invalidate()
        tabBarVisibleObservation = nil

        // Set up KVO observation for isTabBarVisible
        tabBarVisibleObservation = tabGroup?.observe(
            \.isTabBarVisible,
             options: [.new]
        ) { [weak self] _, _ in
            // AppKit tab-group mutations deliver KVO on the main thread.
            MainActor.assumeIsolated {
                self?.scheduleAppearance()
            }
        }
    }
}
