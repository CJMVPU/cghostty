import Cocoa

class QuickTerminalWindow: NSPanel {
    /// Updated only by the controller when selecting a screen for presentation.
    var configuredFrameSize: NSSize?

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var frame = frameRect
        if let configuredFrameSize { frame.size = configuredFrameSize }
        super.setFrame(frame, display: flag)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool, animate animateFlag: Bool) {
        var frame = frameRect
        if let configuredFrameSize { frame.size = configuredFrameSize }
        super.setFrame(frame, display: flag, animate: animateFlag)
    }

    // Both of these must be true for windows without decorations to be able to
    // still become key/main and receive events.
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }

    override func zoom(_ sender: Any?) {}

    override func toggleFullScreen(_ sender: Any?) {}

    func configure() {
        // Add a custom identifier so third party apps can use the Accessibility
        // API to apply special rules to the quick terminal. 
        self.identifier = .init(rawValue: "com.cjmvpu.cghostty.quickTerminal")

        // Set the correct AXSubrole of kAXFloatingWindowSubrole (allows
        // AeroSpace to treat the Quick Terminal as a floating window)
        self.setAccessibilitySubrole(.floatingWindow)

        // The configured size is applied by the controller for the target screen.
        self.styleMask.remove([.titled, .resizable])
        self.collectionBehavior.insert(.fullScreenDisallowsTiling)

        // We don't want to activate the owning app when quick terminal is triggered.
        self.styleMask.insert(.nonactivatingPanel)
    }

}
