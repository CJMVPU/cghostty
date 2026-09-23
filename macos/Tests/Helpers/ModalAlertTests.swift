import AppKit
import Testing

/// Exercise the windowless rename-alert layout in the real macOS modal loop.
@MainActor struct ModalAlertTests {
    @Test func windowlessAlertLaysOutAndAcceptsItsDefaultButton() {
        let alert = NSAlert()
        alert.messageText = "Rename Terminal"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = NSTextField(string: "Terminal")
        let deadline = Date().addingTimeInterval(5)
        let timer = Timer(timeInterval: 0.02, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard alert.window.isVisible else {
                    if Date() >= deadline { NSApp.abortModal() }
                    return
                }
                let button = alert.buttons[0]
                #expect(!button.isHiddenOrHasHiddenAncestor)
                #expect(button.isEnabled)
                #expect(button.bounds.width > 0 && button.bounds.height > 0)
                let rect = button.convert(button.bounds, to: alert.window.contentView)
                #expect(alert.window.contentView?.bounds.intersects(rect) == true)
                button.performClick(nil)
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate() }
        #expect(alert.runModal() == .alertFirstButtonReturn)
    }
}
