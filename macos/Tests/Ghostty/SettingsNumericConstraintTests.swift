import Foundation
import Testing
@testable import Ghostty

@MainActor struct SettingsNumericConstraintTests {
    @Test func contrastAndScrollUseInclusiveBounds() throws {
        let contrast = try #require(SettingsField.byKey["minimum-contrast"])
        for value in ["1", "21"] { #expect(contrast.validate(value) == nil) }
        for value in ["0.99", "21.01", "100", "nan", "inf"] { #expect(contrast.validate(value) != nil) }
        let scroll = try #require(SettingsField.byKey["mouse-scroll-multiplier"])
        for value in ["0.01", "10000", "precision:0.01,discrete:10000", "precision:10000,discrete:0.01"] {
            #expect(scroll.validate(value) == nil)
        }
        for value in ["0.009", "10001", "nan", "inf", "precision:0.009", "discrete:10001", "precision:nan", "discrete:inf"] {
            #expect(scroll.validate(value) != nil)
        }
        #expect(try #require(SettingsField.byKey["background-image-opacity"]).validate("2") == nil)
    }

    @Test func invalidContrastCannotSaveRawValueOrChangeRevision() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SettingsStore(legacySource: root.appendingPathComponent("legacy.conf"), directory: root.appendingPathComponent("Settings"))
        _ = try #require(store.load(cli: false))
        let original = try store.read()
        var input = original.current
        input.values["minimum-contrast"] = "100"
        #expect(!store.diagnostics(input).isEmpty)
        #expect(throws: (any Error).self) { try store.save(input, revision: original.revision) }
        #expect(try store.read().revision == original.revision)
        input.values["minimum-contrast"] = "21"
        let saved = try store.save(input, revision: original.revision)
        let restarted = SettingsStore(legacySource: root.appendingPathComponent("legacy.conf"), directory: root.appendingPathComponent("Settings"))
        let config = try #require(restarted.load(cli: false))
        #expect(saved.current.values["minimum-contrast"] == "21")
        #expect(SettingsStore.values(config)["minimum-contrast"] == "21")
    }
}
