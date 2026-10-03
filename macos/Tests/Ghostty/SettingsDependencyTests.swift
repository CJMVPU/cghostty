import Foundation
import Testing
@testable import Ghostty

@MainActor struct SettingsDependencyTests {
    @Test func explicitFontChoiceSurvivesChangedInheritance() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("legacy.conf")
        try "font-family = Menlo\n".write(to: source, atomically: true, encoding: .utf8)
        let store = SettingsStore(legacySource: source)
        _ = try #require(store.load(cli: false))
        let model = SettingsModel(store: store)
        #expect(model.displayed["font-family-bold"] == "Menlo")
        let regular = try #require(SettingsField.byKey["font-family"])
        let bold = try #require(SettingsField.byKey["font-family-bold"])
        model.edit(regular, value: "Monaco")
        #expect(model.displayed["font-family-bold"] == "Monaco")
        model.edit(bold, value: "Menlo")
        #expect(model.input.values["font-family-bold"] == "Menlo")
        #expect(model.displayed["font-family-bold"] == "Menlo")
        #expect(await model.saveAsync())
        let reloaded = SettingsModel(store: store)
        #expect(reloaded.displayed["font-family"] == "Monaco")
        #expect(reloaded.displayed["font-family-bold"] == "Menlo")
    }

    @Test func unchangedInheritanceCanStillReturnToSavedState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("legacy.conf")
        try "font-family = Menlo\n".write(to: source, atomically: true, encoding: .utf8)
        let store = SettingsStore(legacySource: source)
        _ = try #require(store.load(cli: false))
        let model = SettingsModel(store: store)
        let bold = try #require(SettingsField.byKey["font-family-bold"])
        model.edit(bold, value: "Monaco")
        #expect(model.dirty)
        model.edit(bold, value: "Menlo")
        #expect(model.input.values["font-family-bold"] == nil)
        #expect(!model.dirty)
    }
}
