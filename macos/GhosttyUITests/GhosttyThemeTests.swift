//
//  GhosttyThemeTests.swift
//  Ghostty
//
//  Created by luca on 27.10.2025.
//

import AppKit
import XCTest

final class GhosttyThemeTests: GhosttyCustomConfigCase {
    override static var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    let windowTitle = "GhosttyThemeTests"
    @MainActor
    private func assertTitlebarAppearance(
        _ appearance: XCUIDevice.Appearance,
        for app: XCUIApplication,
        label: String? = nil,
        colorLocation: CGPoint? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), file: file, line: line)
        for i in 0 ..< app.windows.count {
            let texts = app.windows.element(boundBy: i).staticTexts
            let titleView = if let label { texts[label] } else {
                texts.element(matching: NSPredicate(format: "value == %@", windowTitle))
            }
            XCTAssertTrue(titleView.waitForExistence(timeout: 5), "Expected the configured window title", file: file, line: line)
            let appearanceMatches = NSPredicate { _, _ in
                MainActor.assumeIsolated {
                    guard titleView.exists,
                          let color = titleView.screenshot().image.colorAt(
                            x: Int(colorLocation?.x ?? 1), y: Int(colorLocation?.y ?? 1)) else { return false }
                    return appearance == .dark ? color.luminance <= 0.5 : color.luminance >= 0.5
                }
            }
            let ready = XCTNSPredicateExpectation(predicate: appearanceMatches, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed,
                           "Expected \(appearance) titlebar appearance", file: file, line: line)
        }
    }

    /// https://github.com/ghostty-org/ghostty/issues/8282
    @MainActor
    func testIssue8282() async throws {
        try updateConfig("title=\(windowTitle) \n theme=light:3024 Day,dark:3024 Night")
        XCUIDevice.shared.appearance = .dark

        let app = try ghosttyApplication(defaultsSuite: UUID().uuidString)
        app.launch()
        try assertTitlebarAppearance(.dark, for: app)
        // create a split
        app.groups["Terminal pane"].typeKey("d", modifierFlags: .command)
        // User configuration changes apply only on application restart.
        app.terminate()
        app.launch()
        // create a new window
        app.typeKey("n", modifierFlags: [.command])
        try assertTitlebarAppearance(.dark, for: app)
    }

    @MainActor
    func testLightTransparentWindowThemeWithDarkTerminal() async throws {
        try updateConfig("title=\(windowTitle) \n window-theme=light")
        let app = try ghosttyApplication(defaultsSuite: UUID().uuidString)
        app.launch()
        try assertTitlebarAppearance(.dark, for: app)
    }

    @MainActor
    func testLightNativeWindowThemeWithDarkTerminal() async throws {
        try updateConfig("title=\(windowTitle) \n window-theme = light \n macos-titlebar-style = native")
        let app = try ghosttyApplication(defaultsSuite: UUID().uuidString)
        app.launch()
        try assertTitlebarAppearance(.light, for: app)
    }

    @MainActor
    func testRestartingLightTransparentWindowTheme() async throws {
        try updateConfig("title=\(windowTitle) \n ")
        let app = try ghosttyApplication(defaultsSuite: UUID().uuidString)
        app.launch()
        // default dark theme
        try assertTitlebarAppearance(.dark, for: app)
        try updateConfig("title=\(windowTitle) \n theme=light:3024 Day,dark:3024 Night \n window-theme = light")
        // User configuration changes apply only on application restart.
        app.terminate()
        app.launch()
        try assertTitlebarAppearance(.light, for: app)
    }

    @MainActor
    func testSwitchingSystemTheme() async throws {
        try updateConfig("title=\(windowTitle) \n theme=light:3024 Day,dark:3024 Night")
        XCUIDevice.shared.appearance = .dark
        let app = try ghosttyApplication(defaultsSuite: UUID().uuidString)
        app.launch()
        try assertTitlebarAppearance(.dark, for: app)
        XCUIDevice.shared.appearance = .light
        try assertTitlebarAppearance(.light, for: app)
    }

    @MainActor
    func testRestartFromLightWindowThemeToDefaultTheme() async throws {
        try updateConfig("title=\(windowTitle) \n theme=light:3024 Day,dark:3024 Night")
        XCUIDevice.shared.appearance = .light
        let app = try ghosttyApplication(defaultsSuite: UUID().uuidString)
        app.launch()
        try assertTitlebarAppearance(.light, for: app)
        try updateConfig("title=\(windowTitle) \n ")
        // User configuration changes apply only on application restart.
        app.terminate()
        app.launch()
        try assertTitlebarAppearance(.dark, for: app)
    }

    @MainActor
    func testRestartFromDefaultThemeToDarkWindowTheme() async throws {
        try updateConfig("title=\(windowTitle) \n ")
        XCUIDevice.shared.appearance = .light
        let app = try ghosttyApplication(defaultsSuite: UUID().uuidString)
        app.launch()
        try assertTitlebarAppearance(.dark, for: app)
        try updateConfig("title=\(windowTitle) \n theme=light:3024 Day,dark:3024 Night \n window-theme=dark")
        // User configuration changes apply only on application restart.
        app.terminate()
        app.launch()
        try assertTitlebarAppearance(.dark, for: app)
    }

    @MainActor
    func testRestartingFromDarkThemeToSystemLightTheme() async throws {
        try updateConfig("title=\(windowTitle) \n theme=light:3024 Day,dark:3024 Night \n window-theme=dark")
        XCUIDevice.shared.appearance = .light
        let app = try ghosttyApplication(defaultsSuite: UUID().uuidString)
        app.launch()
        try assertTitlebarAppearance(.dark, for: app)
        try updateConfig("title=\(windowTitle) \n theme=light:3024 Day,dark:3024 Night")
        // User configuration changes apply only on application restart.
        app.terminate()
        app.launch()
        try assertTitlebarAppearance(.light, for: app)
    }

    @MainActor
    func testQuickTerminalThemeChange() async throws {
        try updateConfig("title=\(windowTitle) \n theme=light:3024 Day,dark:3024 Night \n confirm-close-surface=false \n quick-terminal-autohide=false")
        XCUIDevice.shared.appearance = .light
        let app = try ghosttyApplication(defaultsSuite: UUID().uuidString)
        app.launch()
        app.activate()
        XCTAssertTrue(app.groups["Terminal pane"].firstMatch.waitForExistence(timeout: 10))
        // close default window
        app.typeKey("w", modifierFlags: [.command])
        // open quick terminal
        app.menuBarItems["View"].firstMatch.click()
        app.menuItems["Quick Terminal"].firstMatch.click()
        let label = "Debug build warning"
        try assertTitlebarAppearance(.light, for: app, label: label, colorLocation: CGPoint(x: 5, y: 5)) // to avoid dark edge
        XCUIDevice.shared.appearance = .dark
        try assertTitlebarAppearance(.dark, for: app, label: label, colorLocation: CGPoint(x: 5, y: 5))
    }
}
