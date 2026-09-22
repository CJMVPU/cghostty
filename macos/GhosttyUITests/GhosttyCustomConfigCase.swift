//
//  GhosttyCustomConfigCase.swift
//  Ghostty
//
//  Created by luca on 16.10.2025.
//

import AppKit
import XCTest

class GhosttyCustomConfigCase: XCTestCase {
    static let defaultsSuiteName: String = "GHOSTTY_UI_TESTS"

    private let configFile: URL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("ghostty")

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: configFile)
    }

    func updateConfig(_ newConfig: String) throws {
        let config = "working-directory = \(FileManager.default.temporaryDirectory.path)\n" + newConfig
        try config.write(to: configFile, atomically: true, encoding: .utf8)
    }

    @MainActor
    func ghosttyApplication(defaultsSuite: String = GhosttyCustomConfigCase.defaultsSuiteName) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-ApplePersistenceIgnoreState", "YES"])
        app.launchEnvironment["CGHOSTTY_CONFIG_PATH"] = configFile.path
        app.launchEnvironment["GHOSTTY_USER_DEFAULTS_SUITE"] = defaultsSuite
        return app
    }

    /// Preserve every representation, including non-text user clipboard contents.
    @MainActor func preservingClipboard(_ body: () -> Void) {
        let pasteboard = NSPasteboard.general
        let savedItems = (pasteboard.pasteboardItems ?? []).map { item in
            let saved = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { saved.setData(data, forType: type) }
            }
            return saved
        }
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(savedItems)
        }
        body()
    }

    /// Keep text literal regardless of the active input method.
    @MainActor func paste(_ text: String, into target: XCUIElement, submit: Bool = true) {
        preservingClipboard {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text.trimmingCharacters(in: .newlines), forType: .string)
            target.typeKey("v", modifierFlags: .command)
            if target.elementType == .textField {
                let consumed = NSPredicate(format: "value == %@", text.trimmingCharacters(in: .newlines))
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: consumed, object: target)], timeout: 5), .completed)
            }
            if submit { target.typeKey("\n", modifierFlags: []) }
        }
    }

}
