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

    @MainActor func testCorrectedConfigWaitsForRestartBeforeCreatingHealthyTerminal() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try updateConfig(configuration(input: "input = path:\(missing.path)", title: "Failed Terminal"))
        let app = try ghosttyApplication(defaultsSuite: UUID().uuidString)
        app.launch()
        app.activate()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Error: InputNotFound"].firstMatch.waitForExistence(timeout: 10))
        try updateConfig(configuration(title: "Recovered Terminal"))
        XCTAssertTrue(app.staticTexts["Error: InputNotFound"].firstMatch.exists)
        app.terminate()
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.wait(for: \.title, toEqual: "Recovered Terminal", timeout: 10))
        XCTAssertTrue(app.groups["Terminal pane"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Terminal IO failed"].exists)
    }
}
