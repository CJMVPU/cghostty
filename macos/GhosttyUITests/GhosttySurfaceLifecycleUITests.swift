import AppKit
import XCTest

final class GhosttySurfaceLifecycleUITests: GhosttyCustomConfigCase {
    override func setUp() async throws {
        try await super.setUp()
        try updateConfig("""
        command = /bin/zsh -f
        shell-integration = none
        confirm-close-surface = false
        macos-titlebar-style = tabs
        undo-timeout = 60s
        """)
    }

    @MainActor func testUndoClosedTabKeepsTheSameShellSession() throws {
        let app = try ghosttyApplication(defaultsSuite: UUID().uuidString)
        app.launch()
        app.activate()
        defer { app.terminate() }
        let pane = app.groups["Terminal pane"].firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 10))
        pane.click()
        paste("printf '\\033]0;Anchor session\\007'", into: app)
        XCTAssertTrue(app.windows.firstMatch.wait(for: \.title, toEqual: "Anchor session", timeout: 5))
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: \.tabs.count, toEqual: 2, timeout: 5))
        paste("CGHOSTTY_SESSION_TOKEN=StillAlive; printf '\\033]0;Session to restore\\007'", into: app)
        XCTAssertTrue(app.windows.firstMatch.wait(for: \.title, toEqual: "Session to restore", timeout: 5))
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.windows.firstMatch.wait(for: \.title, toEqual: "Anchor session", timeout: 5))
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: \.tabs.count, toEqual: 2, timeout: 5))
        XCTAssertTrue(app.windows.firstMatch.wait(for: \.title, toEqual: "Session to restore", timeout: 5))
        paste("printf '\\033]0;Restored %s\\007' \"$CGHOSTTY_SESSION_TOKEN\"", into: app)
        XCTAssertTrue(app.windows.firstMatch.wait(for: \.title, toEqual: "Restored StillAlive", timeout: 5))
    }

    @MainActor func testUndoClosedSplitKeepsTheSameShellSession() throws {
        let app = try ghosttyApplication(defaultsSuite: UUID().uuidString)
        app.launch()
        app.activate()
        defer { app.terminate() }
        let pane = app.groups["Terminal pane"].firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 10))
        pane.click()
        app.typeKey("d", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: \.textViews.count, toEqual: 2, timeout: 5))
        paste("CGHOSTTY_SESSION_TOKEN=SplitAlive; printf '\\033]0;Split to restore\\007'", into: app)
        XCTAssertTrue(app.windows.firstMatch.wait(for: \.title, toEqual: "Split to restore", timeout: 5))
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: \.textViews.count, toEqual: 1, timeout: 5))
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: \.textViews.count, toEqual: 2, timeout: 5))
        paste("printf '\\033]0;Restored %s\\007' \"$CGHOSTTY_SESSION_TOKEN\"", into: app)
        XCTAssertTrue(app.windows.firstMatch.wait(for: \.title, toEqual: "Restored SplitAlive", timeout: 5))
    }

    @MainActor private func paste(_ text: String, into app: XCUIApplication) {
        let pasteboard = NSPasteboard.general
        let savedItems = (pasteboard.pasteboardItems ?? []).map { item in
            let saved = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { saved.setData(data, forType: type) }
            }
            return saved
        }
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(savedItems)
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        app.windows.firstMatch.typeKey("v", modifierFlags: .command)
        app.windows.firstMatch.typeKey("\n", modifierFlags: [])
    }
}
