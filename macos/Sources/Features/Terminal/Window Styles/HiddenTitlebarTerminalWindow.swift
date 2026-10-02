import AppKit

class HiddenTitlebarTerminalWindow: TerminalWindow {
    override var usesToolbarForAccessories: Bool { true }
    var chrome: TerminalChromeView? { contentView as? TerminalChromeView }

    override func decoratedContentSize(_ size: NSSize) -> NSSize {
        let rim = TerminalChromeMetrics.border(scale: backingScaleFactor)
        return NSSize(width: size.width + rim * 2, height: size.height + rim * 2 + TerminalChromeMetrics.buttonSize.height)
    }

    func refreshChrome() {
        reapplyHiddenStyle()
        chrome?.refreshTabs()
    }

    override func syncAppearance(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        super.syncAppearance(surfaceConfig)
        isOpaque = false
        backgroundColor = .clear
        refreshChrome()
    }

    override func addTitlebarAccessoryViewController(_ childViewController: NSTitlebarAccessoryViewController) {
        super.addTitlebarAccessoryViewController(childViewController)
        reapplyHiddenStyle()
    }

    override func configure(for app: Ghostty.App) {
        super.configure(for: app)

        // Setup our initial style
        reapplyHiddenStyle()
    }

    private static let hiddenStyleMask: NSWindow.StyleMask = [
        // We need `titled` in the mask to get the normal window frame
        .titled,

        // Full size content view so we can extend
        // content in to the hidden titlebar's area
        .fullSizeContentView,

        .closable,
        .miniaturizable,
    ]

    /// Apply the hidden titlebar style.
    private func reapplyHiddenStyle() {
        if styleMask != Self.hiddenStyleMask { styleMask = Self.hiddenStyleMask }
        isOpaque = false
        backgroundColor = .clear
        isMovableByWindowBackground = false

        // Hide the title
        titleVisibility = .hidden
        titlebarAppearsTransparent = true

        // Hide the traffic lights (window control buttons)
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        // Keep AppKit tab ownership; only its visual titlebar is hidden.
        tabbingMode = .automatic

        // Nuke it from orbit -- hide the titlebar container entirely, just in case. There are
        // some operations that appear to bring back the titlebar visibility so this ensures
        // it is gone forever.
        if let themeFrame = contentView?.superview,
           let titleBarContainer = themeFrame.firstDescendant(withClassName: "NSTitlebarContainerView") {
            titleBarContainer.isHidden = true
        }

        // It seems AppKit moves `NSScrollPocket` to the title bar on macOS 27.
        // We should hide it to prevent it covering terminal contents.
        //
        // Linked issue: https://github.com/ghostty-org/ghostty/issues/13390
        // Reference: https://developer.apple.com/forums/thread/798392?answerId=856013022#856013022
        // Note: hiding `NSTitlebarBackgroundView` won't work here, because it later uses the pocket view from the `SurfaceScrollView`.
        if let themeFrame = contentView?.superview,
           let scrollPocket = themeFrame.firstDescendant(withClassName: "NSScrollPocket") {
            scrollPocket.isHidden = true
        }
    }

    // MARK: NSWindow

    override var title: String {
        didSet {
            // Updating the title text as above automatically reveals the
            // native title view in macOS 15.0 and above. Since we're using
            // a custom view instead, we need to re-hide it.
            refreshChrome()
        }
    }

    // We override this so that with the hidden titlebar style the titlebar
    // area is not draggable.
    override var contentLayoutRect: CGRect {
        var rect = super.contentLayoutRect
        rect.origin.y = 0
        rect.size.height = self.frame.height
        return rect
    }

}
