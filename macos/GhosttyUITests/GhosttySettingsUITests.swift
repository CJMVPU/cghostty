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
        let window = app.windows["cghostty · Settings"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: .command)
        XCTAssertEqual(app.windows.matching(identifier: "cghostty · Settings").count, 1)
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
        XCTAssertTrue((window.staticTexts["settings.status"].value as? String ?? "").contains("Saved"))
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

    @MainActor func testChoiceButtonsAndFontPresetKeepFallbacksAfterRestart() throws {
        try updateConfig("initial-window = true\nwindow-save-state = never\nconfirm-close-surface = false\nfont-family = Menlo\nfont-family = Monaco\nfont-thicken = false\ncommand = /bin/zsh -f\nshell-integration = none")
        let app = try ghosttyApplication(defaultsSuite: UUID().uuidString)
        app.launch()
        app.activate()
        defer { app.terminate() }
        updateSetting(app, key: "cursor-style", value: "bar")
        app.menuBars.menuBarItems["cghostty"].click()
        app.menuItems["Settings…"].click()
        let window = app.windows["cghostty · Settings"]
        let search = window.textFields["settings.search"]
        search.click()
        search.typeKey("a", modifierFlags: .command)
        paste("font-family", into: search, submit: false)
        let primary = window.comboBoxes["settings.font-family.0"]
        let fallback = window.comboBoxes["settings.font-family.1"]
        XCTAssertTrue(primary.waitForExistence(timeout: 5))
        XCTAssertEqual(primary.value as? String, "Menlo")
        XCTAssertEqual(fallback.value as? String, "Monaco")
        primary.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).click()
        attach(window.screenshot(), name: "settings-font-dropdown")
        let preset = "default:LXGW WenKai Mono:medium:thickened"
        let presetOption = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR value == %@", preset, preset)).firstMatch
        XCTAssertTrue(presetOption.waitForExistence(timeout: 5))
        presetOption.click()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", preset), object: primary)], timeout: 5), .completed)
        XCTAssertEqual(fallback.value as? String, "Monaco")
        let save = window.buttons["settings.save"]
        attach(window.screenshot(), name: "settings-font-selection")
        XCTAssertTrue(save.isEnabled, window.debugDescription)
        save.click()
        app.terminate()
        app.launch()
        app.activate()
        app.menuBars.menuBarItems["cghostty"].click()
        app.menuItems["Settings…"].click()
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        search.click()
        paste("font-family", into: search, submit: false)
        XCTAssertTrue(primary.waitForExistence(timeout: 5))
        XCTAssertEqual(primary.value as? String, preset)
        XCTAssertEqual(fallback.value as? String, "Monaco")
        attach(window.screenshot(), name: "settings-font-preset")
        search.click()
        search.typeKey("a", modifierFlags: .command)
        paste("cursor-style", into: search, submit: false)
        XCTAssertEqual(window.radioGroups["settings.cursor-style"].radioButtons["Bar"].value as? Int, 1)
        attach(window.screenshot(), name: "settings-choice-buttons")
    }
}
