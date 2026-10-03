import Foundation
import Testing
@testable import Ghostty

@MainActor struct SettingsEnvironmentTests {
    @Test func longInheritedValueSurvivesEditingAndRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("legacy.conf")
        let token = "TOKEN=" + String(repeating: "a", count: 300)
        try "env = \(token)".write(to: source, atomically: true, encoding: .utf8)
        let store = SettingsStore(legacySource: source)
        _ = try #require(store.load(cli: false))
        let model = SettingsModel(store: store)
        #expect(model.displayed["env"] == token)
        model.edit(try #require(SettingsField.byKey["env"]), value: token + "\nMODE=after")
        #expect(await model.saveAsync())
        let restarted = SettingsStore(legacySource: source)
        let config = try #require(restarted.load(cli: false))
        #expect(config.errors.isEmpty)
        #expect(SettingsStore.values(config)["env"] == token + "\nMODE=after")
    }
}
