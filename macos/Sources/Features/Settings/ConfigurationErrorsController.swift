import Foundation
import Cocoa
import SwiftUI

class ConfigurationErrorsController: NSWindowController, NSWindowDelegate {
    private weak var app: Ghostty.App?

    init(app: Ghostty.App) {
        self.app = app
        super.init(window: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private var windowCreated = false
    override var isWindowLoaded: Bool { windowCreated }

    // NSWindowController only auto-loads a window when it has a nib name.
    // Keep programmatic windows lazy and run the same lifecycle callbacks.
    override var window: NSWindow? {
        get {
            if !isWindowLoaded {
                windowWillLoad()
                loadWindow()
                windowDidLoad()
            }
            return super.window
        }
        set {
            windowCreated = newValue != nil
            super.window = newValue
        }
    }

    override func loadWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 270),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Configuration Errors"
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
    }

    private let model = ConfigurationErrorsState()

    func updateErrors(_ errors: [String]) {
        model.errors = errors
        // Do not load an unused error window on a successful configuration reload.
        if errors.isEmpty, isWindowLoaded { window?.performClose(nil) }
    }

    // MARK: - NSWindowController

    override func windowWillLoad() {
        shouldCascadeWindows = false
    }

    override func windowDidLoad() {
        guard let window = window else { return }
        window.center()
        window.level = .popUpMenu
        window.contentView = NSHostingView(rootView: ConfigurationErrorsView(
            model: model,
            dismiss: { [weak self] in self?.updateErrors([]) },
            edit: { [weak app] in app?.openConfig() }
        ))
        window.titlebarAppearsTransparent = true
    }
}
