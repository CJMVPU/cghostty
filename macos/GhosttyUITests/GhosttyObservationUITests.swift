import AppKit
import XCTest

/// Uses an isolated shell and configuration so checks do not depend on a user's
/// startup scripts or change their terminal preferences.
final class GhosttyObservationUITests: GhosttyCustomConfigCase {
    override func setUp() async throws {
        try await super.setUp()
        try updateConfig("""
        command = /bin/zsh -f
        shell-integration = none
        confirm-close-surface = false
        macos-titlebar-style = tabs
        """)
    }

    @MainActor func testTitleSearchAndPaletteAfterSplitting() throws {
        let app = try ghosttyApplication(defaultsSuite: UUID().uuidString)
        app.launch()
        app.activate()
        defer { app.terminate() }
        let pane = app.groups["Terminal pane"].firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 10))
        pane.click()
        paste("printf '\\033]0;Observation UI\\007'\n", into: app.groups["Terminal pane"].firstMatch, app: app)
        XCTAssertTrue(app.windows.firstMatch.wait(for: \.title, toEqual: "Observation UI", timeout: 5))

        pane.typeKey("d", modifierFlags: .command)
        let panes = app.textViews
        let twoPanes = NSPredicate(format: "count == 2")
        expectation(for: twoPanes, evaluatedWith: panes)
        waitForExpectations(timeout: 5)

        app.groups["Right pane"].typeKey("f", modifierFlags: .command)
        let search = app.textFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        app.menuItems["Select All"].firstMatch.click()
        paste("terminal", into: search, app: app, submit: false)
        XCTAssertEqual(search.value as? String, "terminal")
        app.menuItems["Select All"].firstMatch.click()
        search.typeKey(.delete, modifierFlags: [])
        XCTAssertEqual(search.value as? String, "")
        search.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(search.waitForNonExistence(timeout: 5))

        app.windows.firstMatch.typeKey("p", modifierFlags: [.command, .shift])
        let clear = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] 'Clear Screen'")).firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        app.windows.firstMatch.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(clear.waitForNonExistence(timeout: 5))

        paste("printf '\\033]0;Focus restored\\007'\n", into: app.windows.firstMatch, app: app)
        XCTAssertTrue(app.windows.firstMatch.wait(for: \.title, toEqual: "Focus restored", timeout: 5))
        XCTAssertEqual(panes.count, 2)
    }

    @MainActor func testTabSwitchingKeepsTerminalState() throws {
        let app = try ghosttyApplication(defaultsSuite: UUID().uuidString)
        app.launch()
        app.activate()
        defer { app.terminate() }
        let pane = app.groups["Terminal pane"].firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 10))
        pane.click()
        paste("printf '\\033]0;First session\\007'\n", into: app.groups["Terminal pane"].firstMatch, app: app)
        XCTAssertTrue(app.windows.firstMatch.wait(for: \.title, toEqual: "First session", timeout: 5))
        app.groups["Terminal pane"].firstMatch.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: \.tabs.count, toEqual: 2, timeout: 5))
        paste("printf '\\033]0;Second session\\007'\n", into: app.groups["Terminal pane"].firstMatch, app: app)
        XCTAssertTrue(app.windows.firstMatch.wait(for: \.title, toEqual: "Second session", timeout: 5))
        app.groups["Terminal pane"].firstMatch.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.windows.firstMatch.wait(for: \.title, toEqual: "First session", timeout: 5))
        app.groups["Terminal pane"].firstMatch.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.windows.firstMatch.wait(for: \.title, toEqual: "Second session", timeout: 5))
    }

    /// Keep text literal regardless of the active input method, and restore
    /// every pasteboard representation after the target consumes it.
    @MainActor private func paste(_ text: String, into target: XCUIElement, app: XCUIApplication, submit: Bool = true) {
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
        pasteboard.setString(text.trimmingCharacters(in: .newlines), forType: .string)
        if target.elementType == .textField {
            app.menuItems["Paste"].firstMatch.click()
        } else {
            target.typeKey("v", modifierFlags: .command)
        }
        if submit { target.typeKey("\n", modifierFlags: []) }
    }

}
