import XCTest

final class GhosttyCreationUndoUITests: GhosttyCustomConfigCase {
    @MainActor func testNewTabUndoCancellationPreservesHistory() throws {
        try updateConfig("""
        macos-titlebar-style = hidden
        initial-window = true
        window-save-state = never
        window-width = 80
        window-height = 22
        confirm-close-surface = always
        undo-timeout = 60s
        command = /bin/zsh -f
        shell-integration = none
        """)
        let app = try ghosttyApplication(defaultsSuite: UUID().uuidString)
        app.launch()
        app.activate()
        defer { app.terminate() }
        let original = app.buttons["terminal.chrome.tab.1"].firstMatch
        let created = app.buttons["terminal.chrome.tab.2"].firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 10))
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(created.waitForExistence(timeout: 5))

        app.typeKey("z", modifierFlags: .command)
        let cancel = app.sheets.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.click()
        XCTAssertTrue(app.wait(for: \.sheets.count, toEqual: 0, timeout: 5))
        XCTAssertTrue(original.exists)
        XCTAssertTrue(created.exists)
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(original.exists)
        XCTAssertTrue(created.exists)
        XCTAssertFalse(app.buttons["terminal.chrome.tab.3"].exists)
        XCTAssertEqual(app.sheets.count, 0)

        app.typeKey("z", modifierFlags: .command)
        let close = app.sheets.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.click()
        XCTAssertTrue(created.waitForNonExistence(timeout: 5))
        XCTAssertTrue(original.exists)
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(created.waitForExistence(timeout: 5))
        XCTAssertTrue(original.exists)

        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.click()
        XCTAssertTrue(app.wait(for: \.sheets.count, toEqual: 0, timeout: 5))
        XCTAssertTrue(original.exists)
        XCTAssertTrue(created.exists)
    }

    @MainActor func testNewWindowUndoCancellationPreservesHistory() throws {
        try updateConfig("""
        macos-titlebar-style = native
        initial-window = true
        window-save-state = never
        window-width = 60
        window-height = 18
        confirm-close-surface = always
        undo-timeout = 60s
        command = /bin/zsh -f
        shell-integration = none
        """)
        let app = try ghosttyApplication(defaultsSuite: UUID().uuidString)
        app.launch()
        app.activate()
        defer { app.terminate() }
        let pane = app.groups["Terminal pane"].firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 10))
        pane.click()
        paste("printf '\\033]0;Creation undo anchor\\007'", into: app)
        let original = app.windows["Creation undo anchor"].firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: \.windows.count, toEqual: 2, timeout: 5))

        app.typeKey("z", modifierFlags: .command)
        let cancel = app.sheets.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.click()
        XCTAssertTrue(app.wait(for: \.sheets.count, toEqual: 0, timeout: 5))
        XCTAssertEqual(app.windows.count, 2)
        XCTAssertTrue(original.exists)
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertEqual(app.windows.count, 2)
        XCTAssertTrue(original.exists)
        XCTAssertEqual(app.sheets.count, 0)

        app.typeKey("z", modifierFlags: .command)
        let close = app.sheets.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.click()
        XCTAssertTrue(app.wait(for: \.windows.count, toEqual: 1, timeout: 5))
        XCTAssertTrue(original.exists)
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.wait(for: \.windows.count, toEqual: 2, timeout: 5))
        XCTAssertTrue(original.exists)

        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.click()
        XCTAssertTrue(app.wait(for: \.sheets.count, toEqual: 0, timeout: 5))
        XCTAssertEqual(app.windows.count, 2)
        XCTAssertTrue(original.exists)
    }
}
