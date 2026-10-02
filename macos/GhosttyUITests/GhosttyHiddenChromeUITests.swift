import XCTest

final class GhosttyHiddenChromeUITests: GhosttyCustomConfigCase {
    @MainActor func testTabsDragWholeWindowAndMinimize() throws {
        try updateConfig("""
        macos-titlebar-style = hidden
        initial-window = true
        window-save-state = never
        window-width = 80
        window-height = 22
        confirm-close-surface = false
        command = /bin/zsh -f
        shell-integration = none
        """)
        let app = try ghosttyApplication(defaultsSuite: UUID().uuidString)
        app.launch()
        app.activate()
        defer { app.terminate() }
        let drag = app.buttons["terminal.chrome.drag"].firstMatch
        XCTAssertTrue(drag.waitForExistence(timeout: 10))
        for number in 2...5 {
            app.typeKey("t", modifierFlags: .command)
            XCTAssertTrue(app.buttons["terminal.chrome.tab.\(number)"].firstMatch.waitForExistence(timeout: 5))
        }
        app.typeKey("t", modifierFlags: .command)
        XCTAssertFalse(app.buttons["terminal.chrome.tab.6"].exists)
        let one = app.buttons["terminal.chrome.tab.1"].firstMatch
        one.click()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Selected"), object: one)], timeout: 5), .completed, one.debugDescription)
        let window = app.windows.firstMatch
        let initial = XCTAttachment(screenshot: window.screenshot())
        initial.name = "hidden-chrome-before-drag"
        initial.lifetime = .keepAlways
        add(initial)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.8)).hover()
        let hoverTarget = app.buttons["terminal.chrome.tab.2"].firstMatch
        let targetFrame = hoverTarget.frame
        let idlePixels = hoverTarget.screenshot().pngRepresentation
        hoverTarget.hover()
        let hoverChanged = NSPredicate { _, _ in hoverTarget.screenshot().pngRepresentation != idlePixels }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: hoverChanged, object: hoverTarget)], timeout: 3), .completed)
        XCTAssertEqual(hoverTarget.frame, targetFrame)
        let hovered = XCTAttachment(screenshot: window.screenshot())
        hovered.name = "metal-chrome-hover"
        hovered.lifetime = .keepAlways
        add(hovered)
        let before = window.frame
        let dragBefore = drag.frame
        let tabBefore = one.frame
        let start = drag.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.click(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: 60, dy: 50)))
        let moved = NSPredicate { _, _ in abs(window.frame.minX - before.minX) > 20 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: moved, object: window)], timeout: 5), .completed)
        let dx = window.frame.minX - before.minX
        let dy = window.frame.minY - before.minY
        XCTAssertEqual(drag.frame.minX - dragBefore.minX, dx, accuracy: 2)
        XCTAssertEqual(drag.frame.minY - dragBefore.minY, dy, accuracy: 2)
        XCTAssertEqual(one.frame.minX - tabBefore.minX, dx, accuracy: 2)
        XCTAssertEqual(window.frame.size, before.size)
        let two = app.buttons["terminal.chrome.tab.2"].firstMatch
        two.click()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Selected"), object: two)], timeout: 5), .completed)
        XCTAssertEqual(window.frame.minX - before.minX, dx, accuracy: 2)
        XCTAssertEqual(window.frame.minY - before.minY, dy, accuracy: 2)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.buttons["terminal.chrome.tab.5"].firstMatch.waitForNonExistence(timeout: 5))
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(app.buttons["terminal.chrome.tab.5"].firstMatch.waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: window.screenshot())
        screenshot.name = "hidden-chrome-five-tabs"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["terminal.chrome.minimize"].firstMatch.click()
        XCTAssertTrue(drag.wait(for: \.isHittable, toEqual: false, timeout: 5))
    }

    @MainActor func testCloseControlPreservesConfirmation() throws {
        try updateConfig("""
        macos-titlebar-style = hidden
        initial-window = true
        window-save-state = never
        window-width = 157
        window-height = 43
        confirm-close-surface = always
        command = /bin/zsh -f
        shell-integration = none
        """)
        let app = try ghosttyApplication(defaultsSuite: UUID().uuidString)
        app.launch()
        app.activate()
        defer { app.terminate() }
        let close = app.buttons["terminal.chrome.close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        close.click()
        let cancel = app.sheets.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.click()
        XCTAssertTrue(app.wait(for: \.sheets.count, toEqual: 0, timeout: 5))
        XCTAssertTrue(close.exists)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "metal-chrome-default-window"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        close.click()
        let confirm = app.sheets.buttons["Close"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        XCTAssertTrue(app.wait(for: \.windows.count, toEqual: 0, timeout: 5))
    }

}
