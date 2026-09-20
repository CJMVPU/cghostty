import XCTest

final class GhosttyWindowRegistryUITests: GhosttyCustomConfigCase {
    override func setUp() async throws {
        try await super.setUp()
        try updateConfig("""
        command = /bin/zsh -f
        shell-integration = none
        confirm-close-surface = false
        macos-titlebar-style = native
        window-width = 30
        window-height = 10
        title = Window Registry
        """)
    }

    @MainActor func testCascadeSurvivesClosingNewestWindow() throws {
        let app = try ghosttyApplication(defaultsSuite: UUID().uuidString)
        app.launch()
        app.activate()
        defer { app.terminate() }
        XCTAssertTrue(app.groups["Terminal pane"].firstMatch.waitForExistence(timeout: 10))
        let firstFrame = app.windows.firstMatch.frame
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: \.windows.count, toEqual: 2, timeout: 10))
        assertCascade(app, from: firstFrame)
        let secondFrame = app.windows.firstMatch.frame
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: \.windows.count, toEqual: 3, timeout: 10))
        assertCascade(app, from: secondFrame)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: \.windows.count, toEqual: 2, timeout: 10))
        let remainingFrame = app.windows.firstMatch.frame
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: \.windows.count, toEqual: 3, timeout: 10))
        assertCascade(app, from: remainingFrame)
    }

    @MainActor func testNewTabUsesRemainingWindowAfterLastMainCloses() throws {
        let app = try ghosttyApplication(defaultsSuite: UUID().uuidString)
        app.launch()
        app.activate()
        defer { app.terminate() }
        XCTAssertTrue(app.groups["Terminal pane"].firstMatch.waitForExistence(timeout: 10))
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: \.windows.count, toEqual: 2, timeout: 10))
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: \.windows.count, toEqual: 1, timeout: 10))
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: \.tabs.count, toEqual: 2, timeout: 10))
        XCTAssertEqual(app.windows.count, 1)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: \.tabs.count, toEqual: 0, timeout: 10))
        XCTAssertEqual(app.windows.count, 1)
        XCTAssertTrue(app.groups["Terminal pane"].firstMatch.exists)
    }

    @MainActor private func assertCascade(_ app: XCUIApplication, from frame: CGRect) {
        let cascaded = NSPredicate { _, _ in
            MainActor.assumeIsolated {
                let next = app.windows.firstMatch.frame
                return abs(next.minX - frame.minX - 30) <= 5 && abs(next.minY - frame.minY - 30) <= 5
            }
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: cascaded, object: nil)], timeout: 10), .completed)
    }
}
