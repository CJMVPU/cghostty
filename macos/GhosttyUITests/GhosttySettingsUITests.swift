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
    @MainActor func testStructuredEditorsSaveAndRestoreValues() throws {
        // macOS may display a transient input-source indicator while switching
        // focus. It is not a modal app alert and does not need a button click.
        let monitor = addUIInterruptionMonitor(withDescription: "Input source indicator") { interruption in
            guard interruption.buttons["InputSource"].exists else { return false }
            return interruption.waitForNonExistence(timeout: 5)
        }
        defer { removeUIInterruptionMonitor(monitor) }
        try updateConfig("initial-window = true\nwindow-save-state = never\nconfirm-close-surface = false\ncommand = /bin/zsh -f\nshell-integration = none\nenv = TOKEN=a=b\nundo-timeout = 5s")
        let app = try ghosttyApplication(defaultsSuite: UUID().uuidString)
        app.launch()
        app.activate()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.menuBars.menuBarItems["cghostty"].click()
        app.menuItems["Settings…"].click()
        let window = app.windows["cghostty · Settings"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let search = window.textFields["settings.search"]
        func find(_ key: String) {
            search.click()
            search.typeKey("a", modifierFlags: .command)
            paste(key, into: search, submit: false)
        }
        find("env")
        let token = window.textFields["settings.env.0.value"]
        XCTAssertTrue(token.waitForExistence(timeout: 5))
        XCTAssertEqual(token.value as? String, "a=b")
        token.click()
        token.typeKey("a", modifierFlags: .command)
        paste("x=y=z", into: token, submit: false)
        attach(window.screenshot(), name: "settings-environment-rows")
        find("undo-timeout")
        let duration = window.textFields["settings.undo-timeout.0.value"]
        XCTAssertTrue(duration.waitForExistence(timeout: 5))
        duration.click()
        duration.typeKey("a", modifierFlags: .command)
        duration.typeText("7")
        find("scrollback-limit-lines")
        let limit = window.radioGroups["settings.scrollback-limit-lines.0.unit"]
        XCTAssertTrue(limit.waitForExistence(timeout: 5))
        limit.radioButtons["Limited"].click()
        let lines = window.textFields["settings.scrollback-limit-lines.0.value"]
        lines.click()
        lines.typeText("2000")
        attach(window.screenshot(), name: "settings-limit-controls")
        find("bell-features")
        let audio = window.checkBoxes["settings.bell-features.audio"]
        XCTAssertTrue(audio.waitForExistence(timeout: 5))
        audio.click()
        attach(window.screenshot(), name: "settings-feature-toggles")
        let save = window.buttons["settings.save"]
        XCTAssertTrue(save.isEnabled)
        save.click()
        app.terminate()
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.menuBars.menuBarItems["cghostty"].click()
        app.menuItems["Settings…"].click()
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        find("env")
        XCTAssertEqual(token.value as? String, "x=y=z")
        find("undo-timeout")
        XCTAssertEqual(duration.value as? String, "7")
        find("scrollback-limit-lines")
        XCTAssertEqual(lines.value as? String, "2000")
        find("font-style")
        XCTAssertTrue(window.comboBoxes["settings.font-style"].waitForExistence(timeout: 5))
        attach(window.screenshot(), name: "settings-font-styles")
        find("theme")
        XCTAssertTrue(window.comboBoxes["settings.theme.0"].waitForExistence(timeout: 5))
        attach(window.screenshot(), name: "settings-theme-preview")
        find("background")
        attach(window.screenshot(), name: "settings-color-controls")
        search.click()
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
        window.buttons["Appearance"].click()
        attach(window.screenshot(), name: "settings-appearance-sections")
    }

    @MainActor func testThemeSelectionAndShortcutRecording() throws {
        try updateConfig("initial-window = true\nwindow-save-state = never\nconfirm-close-surface = false\ncommand = /bin/zsh -f\nshell-integration = none\nkeybind = super+shift+j=ignore")
        let monitor = addUIInterruptionMonitor(withDescription: "Input source indicator") { interruption in
            guard interruption.buttons["InputSource"].exists else { return false }
            return interruption.waitForNonExistence(timeout: 5)
        }
        defer { removeUIInterruptionMonitor(monitor) }
        let app = try ghosttyApplication(defaultsSuite: UUID().uuidString)
        app.launch()
        app.activate()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.menuBars.menuBarItems["cghostty"].click()
        app.menuItems["Settings…"].click()
        let window = app.windows["cghostty · Settings"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let search = window.textFields["settings.search"]
        search.click()
        paste("theme", into: search, submit: false)
        let theme = window.comboBoxes["settings.theme.0"]
        XCTAssertTrue(theme.waitForExistence(timeout: 5))
        theme.click()
        theme.typeKey("a", modifierFlags: .command)
        paste("Builtin Tango", into: theme, submit: false)
        theme.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).click()
        let option = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR value == %@", "Builtin Tango Dark", "Builtin Tango Dark")).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.click()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Builtin Tango Dark"), object: theme)], timeout: 5), .completed)
        search.click()
        XCTAssertTrue(window.buttons["settings.save"].isEnabled)
        attach(window.screenshot(), name: "settings-selected-theme")
        search.typeKey("a", modifierFlags: .command)
        paste("keybind", into: search, submit: false)
        let recorder = window.buttons["Record"].firstMatch
        XCTAssertTrue(recorder.waitForExistence(timeout: 5))
        recorder.click()
        XCTAssertTrue(window.buttons["Press Keys"].waitForExistence(timeout: 3))
        attach(window.screenshot(), name: "settings-recording-active")
        app.typeKey("9", modifierFlags: [.control, .shift])
        let shortcut = window.textFields["settings.keybind.0.key"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "ctrl+shift+9"), object: shortcut)], timeout: 5), .completed)
        attach(window.screenshot(), name: "settings-recorded-shortcut")
        let save = window.buttons["settings.save"]
        XCTAssertTrue(save.isEnabled)
        save.click()
        XCTAssertTrue(save.wait(for: \.isEnabled, toEqual: false, timeout: 3))
    }

}
