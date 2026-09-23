import AppKit
import XCTest

final class GhosttyConfigSnapshotUITests: GhosttyCustomConfigCase {
    private func configuration(title: String, extras: String = "") -> String {
        """
        command = /bin/zsh -f
        shell-integration = none
        confirm-close-surface = false
        window-save-state = never
        macos-titlebar-style = native
        title = \(title)
        \(extras)
        """
    }

    @MainActor func testChangesWaitForRestartAndThenUpdateNewWindowBindings() throws {
        try updateConfig(configuration(title: "Snapshot Before"))
        let app = try ghosttyApplication(defaultsSuite: UUID().uuidString)
        app.launch()
        app.activate()
        defer { app.terminate() }
        let first = app.windows.firstMatch
        XCTAssertTrue(first.wait(for: \.title, toEqual: "Snapshot Before", timeout: 10))

        try updateConfig(configuration(title: "Snapshot After", extras: "keybind = super+shift+h=new_window"))
        // Existing and new windows must continue using the startup generation.
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: \.windows.count, toEqual: 2, timeout: 10))
        for window in app.windows.allElementsBoundByIndex {
            XCTAssertEqual(window.title, "Snapshot Before")
        }
        app.terminate()
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.wait(for: \.title, toEqual: "Snapshot After", timeout: 10))
        app.windows.firstMatch.typeKey("h", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.wait(for: \.windows.count, toEqual: 2, timeout: 10))
        for window in app.windows.allElementsBoundByIndex {
            XCTAssertTrue(window.wait(for: \.title, toEqual: "Snapshot After", timeout: 5))
        }
    }

    @MainActor func testRestartAppliesNativeWindowAppearance() throws {
        try updateConfig(configuration(title: "Snapshot Appearance", extras: "window-theme = dark"))
        let app = try ghosttyApplication(defaultsSuite: UUID().uuidString)
        app.launch()
        app.activate()
        defer { app.terminate() }
        let title = app.windows.firstMatch.staticTexts["Snapshot Appearance"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        func appearanceIsLight() -> Bool? {
            title.screenshot().image.colorAt(x: 1, y: 1).map { $0.luminance > 0.5 }
        }
        let initiallyDark = NSPredicate { _, _ in
            MainActor.assumeIsolated { appearanceIsLight() == false }
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: initiallyDark, object: nil)], timeout: 5), .completed)

        try updateConfig(configuration(title: "Snapshot Appearance", extras: "window-theme = light"))
        app.terminate()
        app.launch()
        app.activate()
        let becomesLight = NSPredicate { _, _ in
            MainActor.assumeIsolated { appearanceIsLight() == true }
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: becomesLight, object: nil)], timeout: 10), .completed)
    }

    @MainActor func testInvalidRestartShowsErrorsAndRestoresSuccessfulConfiguration() throws {
        try updateConfig(configuration(title: "Last Successful"))
        let app = try ghosttyApplication(defaultsSuite: UUID().uuidString)
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.windows["Last Successful"].waitForExistence(timeout: 10))
        try updateConfig(configuration(title: "Invalid Partial", extras: "background-opacity = invalid"))
        app.terminate()
        app.launch()
        app.activate()
        let errors = app.windows["Configuration Errors"]
        XCTAssertTrue(errors.waitForExistence(timeout: 10))
        errors.buttons["关闭 / Close"].click()
        XCTAssertTrue(app.windows["Last Successful"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.windows["Invalid Partial"].exists)
    }

    @MainActor func testRestoreDefaultsMenuWaitsForRestart() throws {
        try updateConfig(configuration(title: "Before Reset"))
        let app = try ghosttyApplication(defaultsSuite: UUID().uuidString)
        app.launch()
        app.activate()
        defer { app.terminate() }
        XCTAssertTrue(app.windows["Before Reset"].waitForExistence(timeout: 10))
        app.menuBars.menuBarItems["cghostty"].click()
        app.menuItems["Restore Default Settings…"].click()
        let restore = app.dialogs.buttons["恢复默认 / Restore Defaults"]
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        restore.click()
        let ready = app.staticTexts["重启后使用默认设置 / Defaults Ready for Next Launch"]
        XCTAssertTrue(ready.waitForExistence(timeout: 5))
        app.typeKey("\n", modifierFlags: [])
        XCTAssertTrue(app.windows["Before Reset"].exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.windows["Before Reset"].exists)
        XCTAssertFalse(app.windows["Configuration Errors"].exists)
    }

    @MainActor func testDefaultWindowGridAndBundledFontRendering() throws {
        #if DEBUG
        throw XCTSkip("Exact initial terminal rows are verified in ReleaseLocal; the debug warning banner consumes content height.")
        #else
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        try updateConfig(configuration(title: "Bundled Font Defaults"))
        let app = try ghosttyApplication(defaultsSuite: UUID().uuidString)
        app.launch()
        app.activate()
        defer { app.terminate() }
        let window = app.windows["Bundled Font Defaults"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let terminal = app.groups["Terminal pane"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        paste("stty size > '\(output.path)'; printf '\\nSarasa Term SC Nerd 中文测试 ABC 0123456789\\n\\033[1m粗体 Bold\\033[0m \\033[3m斜体 Italic\\033[0m \\033[1;3m粗斜体\\033[0m\\n'", into: terminal)
        let reportsGrid = NSPredicate { _, _ in
            (try? String(contentsOf: output, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: reportsGrid, object: nil)], timeout: 10), .completed)
        let attachment = XCTAttachment(screenshot: window.screenshot())
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "33 111")
        attachment.name = "Sarasa Term SC Nerd — default 16 pt, 111 × 33"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertFalse(app.windows["Configuration Errors"].exists)
        #endif
    }

}
