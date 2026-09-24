import AppKit
import Testing
@testable import Ghostty

@MainActor
struct TitlebarTextFieldObserversTests {
    @Test func reuseReplacementAndRemoval() {
        let observers = TitlebarTextFieldObservers()
        let first = NSTextField()
        let second = NSTextField()
        var updates = 0
        for _ in 0..<100 {
            observers.update([first]) { _ in updates += 1 }
        }
        #expect(observers.registrations == 1)
        NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: first)
        #expect(updates == 1)
        observers.update([second]) { _ in updates += 1 }
        #expect(observers.count == 1)
        #expect(observers.registrations == 2)
        NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: first)
        #expect(updates == 1)
        NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: second)
        #expect(updates == 2)
        observers.update([]) { _ in updates += 1 }
        NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: second)
        #expect(updates == 2)
    }

    @Test func detachedFieldIsNotRetained() {
        let observers = TitlebarTextFieldObservers()
        weak var released: NSTextField?
        autoreleasepool {
            let field = NSTextField()
            released = field
            observers.update([field]) { _ in }
        }
        #expect(released == nil)
        observers.update([]) { _ in }
        #expect(observers.count == 0)
    }
}
