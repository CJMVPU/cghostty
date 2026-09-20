import AppKit
import XCTest

final class GhosttyConfigSnapshotUITests: GhosttyCustomConfigCase {
    private func configuration(title: String, extras: String = "") -> String {
        """
        command = /bin/zsh -f
        shell-integration = none
        confirm-close-surface = false
        macos-titlebar-style = native
        title = \(title)
        \(extras)
        """
    }

    @MainActor func testReloadUpdatesExistingWindowAndNewWindowBindings() throws {
        try updateConfig(configuration(title: "Snapshot Before"))
        let app = try ghosttyApplication(defaultsSuite: UUID().uuidString)
        app.launch()
        app.activate()
        defer { app.terminate() }
        let first = app.windows.firstMatch
        XCTAssertTrue(first.wait(for: \.title, toEqual: "Snapshot Before", timeout: 10))

        try updateConfig(configuration(title: "Snapshot After", extras: "keybind = super+shift+h=new_window"))
        app.menuBars.menuBarItems["cghostty"].click()
        app.menuItems["Reload Configuration"].click()
        XCTAssertTrue(first.wait(for: \.title, toEqual: "Snapshot After", timeout: 10))
        first.typeKey("h", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.wait(for: \.windows.count, toEqual: 2, timeout: 10))
        for window in app.windows.allElementsBoundByIndex {
            XCTAssertTrue(window.wait(for: \.title, toEqual: "Snapshot After", timeout: 5))
        }
    }

    @MainActor func testReloadChangesNativeWindowAppearance() throws {
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
        app.menuBars.menuBarItems["cghostty"].click()
        app.menuItems["Reload Configuration"].click()
        let becomesLight = NSPredicate { _, _ in
            MainActor.assumeIsolated { appearanceIsLight() == true }
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: becomesLight, object: nil)], timeout: 10), .completed)
    }
}
