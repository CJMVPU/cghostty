import AppKit
import XCTest

final class GhosttySettingsUITests: GhosttyCustomConfigCase {
    @MainActor private func attach(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testIndependentSettingsValidateSaveAndRestart() throws {
        try updateConfig("initial-window = true\nwindow-save-state = never\nconfirm-close-surface = false\ncommand = /bin/zsh -f\nshell-integration = none")
        let app = try ghosttyApplication(defaultsSuite: UUID().uuidString)
        app.launch()
        app.activate()
        defer { app.terminate() }
        app.menuBars.menuBarItems["cghostty"].click()
        app.menuItems["Settings…"].click()
        let window = app.windows["cghostty · 设置"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: .command)
        XCTAssertEqual(app.windows.matching(identifier: "cghostty · 设置").count, 1)
        let search = window.textFields["settings.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        paste("window-width", into: search, submit: false)
        let width = window.textFields["settings.window-width"]
        XCTAssertTrue(width.waitForExistence(timeout: 5))
        width.click()
        width.typeKey("a", modifierFlags: .command)
        width.typeText("9")
        let save = window.buttons["settings.save"]
        XCTAssertFalse(save.isEnabled)
        XCTAssertTrue(window.staticTexts["settings.errors"].exists)
        attach(window.screenshot(), name: "settings-invalid")
        width.typeKey("a", modifierFlags: .command)
        width.typeText("158")
        XCTAssertTrue(save.isEnabled)
        save.click()
        attach(window.screenshot(), name: "settings-saved")
        XCTAssertTrue(save.wait(for: \.isEnabled, toEqual: false, timeout: 3))
        XCTAssertTrue((window.staticTexts["settings.status"].value as? String ?? "").contains("已保存"))
        app.terminate()
        app.launch()
        app.activate()
        app.menuBars.menuBarItems["cghostty"].click()
        app.menuItems["Settings…"].click()
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        search.click()
        paste("window-width", into: search, submit: false)
        XCTAssertTrue(width.waitForExistence(timeout: 5))
        XCTAssertEqual(width.value as? String, "158")
        width.click()
        width.typeKey("a", modifierFlags: .command)
        width.typeText("157")
        save.click()
        search.click()
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
        attach(window.screenshot(), name: "settings-overview")
    }
}
