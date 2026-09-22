//
//  GhosttyCommandPaletteTests.swift
//  Ghostty
//
//  Created by Lukas on 19.03.2026.
//

import AppKit
import XCTest

final class GhosttyCommandPaletteTests: GhosttyCustomConfigCase {
    override func setUp() async throws {
        try await super.setUp()
        try updateConfig("""
        command = /bin/zsh -f
        shell-integration = none
        confirm-close-surface = false
        window-width = 100
        window-height = 30
        """)
    }

    @MainActor func testDismissingCommandPalette() async throws {
        let app = try ghosttyApplication(defaultsSuite: UUID().uuidString)
        app.activate()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), "New window should appear")

        app.menuItems["Command Palette"].firstMatch.click()

        let clearScreenButton = app.buttons
            .containing(NSPredicate(format: "label CONTAINS[c] 'Clear Screen'"))
            .firstMatch

        XCTAssertTrue(clearScreenButton.waitForExistence(timeout: 5), "Command Palette should appear")

        app.windows.firstMatch.coordinate(withNormalizedOffset: .init(dx: 0.95, dy: 0.9)).click()

        XCTAssertTrue(clearScreenButton.waitForNonExistence(timeout: 5), "Command Palette should disappear after clicking outside")

        app.typeKey("p", modifierFlags: [.command, .shift])

        XCTAssertTrue(clearScreenButton.waitForExistence(timeout: 5), "Command Palette should appear")

        app.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(clearScreenButton.waitForNonExistence(timeout: 5), "Command Palette should disappear after typing escape")

        app.typeKey("p", modifierFlags: [.command, .shift])

        XCTAssertTrue(clearScreenButton.waitForExistence(timeout: 5), "Command Palette should appear")

        app.typeKey(.enter, modifierFlags: [])

        XCTAssertTrue(clearScreenButton.waitForNonExistence(timeout: 5), "Command Palette should disappear after submitting query")

        app.typeKey("p", modifierFlags: [.command, .shift])

        XCTAssertTrue(clearScreenButton.waitForExistence(timeout: 5), "Command Palette should appear")

        let query = app.textFields["Execute a command…"]
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        query.click()
        paste("Clear Screen", into: query, submit: false)
        XCTAssertEqual(query.value as? String, "Clear Screen")
        query.typeKey(.enter, modifierFlags: [])

        XCTAssertTrue(clearScreenButton.waitForNonExistence(timeout: 5), "Command Palette should disappear after selecting a command by keyboard")

        app.typeKey("p", modifierFlags: [.command, .shift])

        XCTAssertTrue(clearScreenButton.waitForExistence(timeout: 5), "Command Palette should appear")
        clearScreenButton.click()

        XCTAssertTrue(clearScreenButton.waitForNonExistence(timeout: 5), "Command Palette should disappear after selecting a command by mouse")
    }

    @MainActor func testSelectCommandWithMouse() async throws {
        let app = try ghosttyApplication(defaultsSuite: UUID().uuidString)
        app.activate()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), "New window should appear")

        app.menuItems["Command Palette"].firstMatch.click()

        app.buttons
            .containing(NSPredicate(format: "label CONTAINS[c] 'Close All Windows'"))
            .firstMatch.click()

        XCTAssertTrue(app.windows.firstMatch.waitForNonExistence(timeout: 2), "All windows should be closed")
    }

    @MainActor func testTextEditingWithRemappedTerminalBindings() throws {
        try updateConfig("""
        command = /bin/zsh -f
        shell-integration = none
        confirm-close-surface = false
        keybind = super+v=ignore
        keybind = super+a=ignore
        keybind = super+c=ignore
        keybind = super+x=ignore
        """)
        let app = try ghosttyApplication(defaultsSuite: UUID().uuidString)
        app.launch()
        app.activate()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        app.typeKey("p", modifierFlags: [.command, .shift])
        let query = app.textFields["Execute a command…"]
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        query.click()
        paste("Clear Screen", into: query, submit: false)
        query.typeKey("a", modifierFlags: .command)
        // Replacing the selection proves native Select All also ignores terminal mappings.
        paste("New Window", into: query, submit: false)
        XCTAssertEqual(query.value as? String, "New Window")
        preservingClipboard {
            query.typeKey("a", modifierFlags: .command)
            query.typeKey("c", modifierFlags: .command)
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), "New Window")
            query.typeKey("x", modifierFlags: .command)
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", ""), object: query)], timeout: 5), .completed)
            query.typeKey("v", modifierFlags: .command)
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", "New Window"), object: query)], timeout: 5), .completed)
        }
        query.typeKey(.escape, modifierFlags: [])
    }
}
