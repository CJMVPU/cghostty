import Foundation
import Cocoa
import SwiftUI

class AboutController: NSWindowController, NSWindowDelegate {
    static let shared: AboutController = AboutController()

    init() { super.init(window: nil) }

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
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 172),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
    }

    override func windowDidLoad() {
        guard let window = window else { return }
        window.center()
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: AboutView())
        window.titlebarAppearsTransparent = true
    }

    // MARK: - Functions

    func show() {
        window?.makeKeyAndOrderFront(nil)
    }

    func hide() {
        window?.close()
    }

    // MARK: - First Responder

    @IBAction func close(_ sender: Any) {
        self.window?.performClose(sender)
    }

    @IBAction func closeWindow(_ sender: Any) {
        self.window?.performClose(sender)
    }

    // This is called when "escape" is pressed.
    @objc func cancel(_ sender: Any?) {
        close()
    }

}
