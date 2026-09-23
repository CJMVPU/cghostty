import AppKit
import XCTest

final class GhosttyQuickTerminalUITests: GhosttyCustomConfigCase {
    @MainActor func testQuitRevealsHiddenQuickTerminalBeforeConfirmation() throws {
        for duration in [0.0, 0.8] {
            try updateConfig("""
            command = /bin/zsh -f
            shell-integration = none
            initial-window = false
            confirm-close-surface = always
            quick-terminal-autohide = false
            quick-terminal-animation-duration = \(duration)
            keybind = ctrl+alt+q=toggle_quick_terminal
            """)
            let app = try ghosttyApplication(defaultsSuite: UUID().uuidString)
            app.launch()
            app.activate()
            defer { app.terminate() }
            app.typeKey("q", modifierFlags: [.control, .option])
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
            paste("printf '\\033]0;Quick confirm ready\\007'", into: app.windows.firstMatch)
            XCTAssertTrue(app.windows["Quick confirm ready"].waitForExistence(timeout: 5))
            app.typeKey("q", modifierFlags: [.control, .option])
            XCTAssertTrue(app.wait(for: \.windows.count, toEqual: 0, timeout: 5))
            app.typeKey("q", modifierFlags: .command)
            let cancel = app.sheets.buttons["Cancel"].firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 5))
            XCTAssertTrue(app.windows["Quick confirm ready"].exists)
            cancel.click()
            XCTAssertTrue(app.wait(for: \.sheets.count, toEqual: 0, timeout: 5))
            XCTAssertTrue(app.windows["Quick confirm ready"].exists)
            app.terminate()
        }
    }

    @MainActor func testPresentationAcrossPositions() throws {
        for position in ["top", "bottom", "left", "right", "center"] {
            try updateConfig("""
            command = /bin/zsh -f
            shell-integration = none
            confirm-close-surface = false
            quick-terminal-position = \(position)
            quick-terminal-autohide = false
            quick-terminal-animation-duration = 0.1
            keybind = ctrl+alt+q=toggle_quick_terminal
            """)
            let app = try ghosttyApplication(defaultsSuite: UUID().uuidString)
            app.launch()
            app.activate()
            defer { app.terminate() }
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
            app.typeKey("q", modifierFlags: [.control, .option])
            XCTAssertTrue(app.wait(for: \.windows.count, toEqual: 2, timeout: 5), position)
            let title = "Quick \(position) ready"
            paste("printf '\\033]0;\(title)\\007'", into: app.windows.firstMatch)
            let quick = app.windows[title]
            XCTAssertTrue(quick.waitForExistence(timeout: 5), position)
            let frame = quick.frame
            XCTAssertGreaterThan(frame.width, 100, position)
            XCTAssertGreaterThan(frame.height, 100, position)
            XCTAssertTrue(frame.minX.isFinite && frame.minY.isFinite, position)
            app.typeKey("q", modifierFlags: [.control, .option])
            XCTAssertTrue(app.wait(for: \.windows.count, toEqual: 1, timeout: 5), position)
            app.typeKey("q", modifierFlags: [.control, .option])
            XCTAssertTrue(quick.waitForExistence(timeout: 5), position)
            paste("printf '\\033]0;Quick resumed\\007'", into: quick)
            let resumed = app.windows["Quick resumed"]
            XCTAssertTrue(resumed.waitForExistence(timeout: 5), position)
            XCTAssertEqual(resumed.frame.width, frame.width, accuracy: 2, position)
            XCTAssertEqual(resumed.frame.height, frame.height, accuracy: 2, position)
            app.terminate()
        }
    }
}
