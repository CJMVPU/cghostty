//
//  GhosttyCustomConfigCase.swift
//  Ghostty
//
//  Created by luca on 16.10.2025.
//

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
}
