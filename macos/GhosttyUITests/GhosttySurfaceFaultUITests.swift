import XCTest

final class GhosttySurfaceFaultUITests: GhosttyCustomConfigCase {
    private func configuration(input: String = "", title: String) -> String {
        """
        command = /bin/zsh -f
        shell-integration = none
        macos-titlebar-style = native
        title = \(title)
        \(input)
        """
    }

    @MainActor func testMissingInputShowsAnActionableFailureAndCloses() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try updateConfig(configuration(input: "input = path:\(missing.path)", title: "Failed Terminal"))
        let app = try ghosttyApplication(defaultsSuite: UUID().uuidString)
        app.launch()
        app.activate()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Terminal IO failed"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Error: InputNotFound"].firstMatch.exists)
        let close = app.buttons["Close Terminal"].firstMatch
        XCTAssertTrue(close.isEnabled)
        close.click()
        XCTAssertTrue(app.wait(for: \.windows.count, toEqual: 0, timeout: 10))
    }

    @MainActor func testCorrectedConfigCreatesHealthyWindowWithoutHidingOriginalFault() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try updateConfig(configuration(input: "input = path:\(missing.path)", title: "Failed Terminal"))
        let app = try ghosttyApplication(defaultsSuite: UUID().uuidString)
        app.launch()
        app.activate()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Error: InputNotFound"].firstMatch.waitForExistence(timeout: 10))
        try updateConfig(configuration(title: "Recovered Terminal"))
        app.menuItems["Reload Configuration"].click()
        XCTAssertTrue(app.windows.firstMatch.wait(for: \.title, toEqual: "Recovered Terminal", timeout: 10))
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: \.windows.count, toEqual: 2, timeout: 10))
        let healthy = app.windows.firstMatch
        XCTAssertTrue(healthy.groups["Terminal pane"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(healthy.staticTexts["Terminal IO failed"].exists)
        let failed = app.windows.containing(.staticText, identifier: "Error: InputNotFound").firstMatch
        XCTAssertTrue(failed.exists)
        // The new window covers the old pane. Raise the failed window using its
        // exposed titlebar before interacting with its recovery controls.
        failed.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 100, dy: 10)).click()
        XCTAssertTrue(failed.buttons["Close Terminal"].wait(for: \.isHittable, toEqual: true, timeout: 5))
        failed.buttons["Close Terminal"].click()
        XCTAssertTrue(app.wait(for: \.windows.count, toEqual: 1, timeout: 10))
        XCTAssertFalse(app.staticTexts["Terminal IO failed"].exists)
    }
}
