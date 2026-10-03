import Foundation
import Testing
@testable import Ghostty

@MainActor struct SettingsThemeBranchTests {
    private func withSource(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.appendingPathComponent("config.ghostty"))
    }

    @Test func rejectsInvalidDarkThemeBeforeSaving() throws {
        try withSource { source in
            let root = source.deletingLastPathComponent()
            let light = root.appendingPathComponent("Light")
            let dark = root.appendingPathComponent("Dark")
            try "background = #123456".write(to: light, atomically: true, encoding: .utf8)
            try "background = invalid".write(to: dark, atomically: true, encoding: .utf8)
            let store = SettingsStore(legacySource: source)
            _ = try #require(store.load(cli: false))
            let before = try Data(contentsOf: store.url)
            let record = try store.read()
            var input = record.current
            input.values["theme"] = "light:\(light.path),dark:\(dark.path)"
            let evaluation = store.evaluate(input)
            #expect(evaluation.config?.formattedEntry("background") == "background = #123456\n")
            #expect(evaluation.diagnostics.contains { $0.source == dark.path && $0.key == "background" })
            #expect(throws: SettingsStore.Failure.self) { try store.save(input, revision: record.revision) }
            #expect(try Data(contentsOf: store.url) == before)
        }
    }

    @Test func bothValidThemesKeepDisplayedBranch() throws {
        try withSource { source in
            let root = source.deletingLastPathComponent()
            let light = root.appendingPathComponent("Light")
            let dark = root.appendingPathComponent("Dark")
            try "background = #123456".write(to: light, atomically: true, encoding: .utf8)
            try "background = #654321".write(to: dark, atomically: true, encoding: .utf8)
            let store = SettingsStore(legacySource: source)
            let input = SettingsStore.Input(values: ["theme": "light:\(light.path),dark:\(dark.path)"])
            let result = store.evaluate(input)
            #expect(result.diagnostics.isEmpty)
            #expect(result.config?.formattedEntry("background") == "background = #123456\n")
            #expect(store.parse(input, dark: true)?.formattedEntry("background") == "background = #654321\n")
        }
    }

    @Test func invalidDarkLegacyThemePreservesOriginalAndDoesNotCommitMigration() throws {
        try withSource { source in
            let root = source.deletingLastPathComponent()
            let light = root.appendingPathComponent("Light")
            let dark = root.appendingPathComponent("Dark")
            try "background = #123456".write(to: light, atomically: true, encoding: .utf8)
            try "background = invalid".write(to: dark, atomically: true, encoding: .utf8)
            let original = Data("theme = light:\(light.path),dark:\(dark.path)\n".utf8)
            try original.write(to: source)
            let store = SettingsStore(legacySource: source)
            let config = try #require(store.load(cli: false))
            #expect(!config.errors.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: store.url.path))
            #expect(try Data(contentsOf: source) == original)
        }
    }

}
