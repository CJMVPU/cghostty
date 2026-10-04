import Foundation
import Testing
@testable import Ghostty

@MainActor struct SettingsRecoveryTests {
    @Test(arguments: [false, true])
    func damagedDarkBranchSelectsPreviousOrDefaults(previousIsDamaged: Bool) throws {
        try withStore { store, root in
            let themes = try writeThemes(root)
            let current = SettingsStore.Input(values: ["title": "Current", "theme": themes.brokenDark])
            let previous = SettingsStore.Input(values: [
                "title": "Previous", "theme": previousIsDamaged ? themes.brokenDark : themes.valid
            ])
            let record = SettingsStore.Record(current: current, previous: previous)
            let bytes = try JSONEncoder().encode(record)
            try bytes.write(to: store.url)
            let expected: Ghostty.ConfigHandle.SettingsRecoverySource = previousIsDamaged ? .defaults : .previous
            #expect(try Ghostty.ConfigHandle.settingsRecoverySource(record, source: store.validationSource) == expected)
            let result = try #require(store.load(cli: false))
            #expect(result.formattedEntry("title") == (previousIsDamaged ? "title = \n" : "title = Previous\n"))
            #expect(!result.errors.isEmpty)
            #expect(store.startupErrors.contains { $0.contains("theme") || $0.contains("background") })
            #expect(try Data(contentsOf: store.url) == bytes)
        }
    }

    @Test func validLightAndDarkSelectCurrent() throws {
        try withStore { store, root in
            let themes = try writeThemes(root)
            let current = SettingsStore.Input(values: ["title": "Current", "theme": themes.valid])
            let record = SettingsStore.Record(current: current, previous: .init(values: ["theme": themes.brokenDark]))
            try JSONEncoder().encode(record).write(to: store.url)
            #expect(try Ghostty.ConfigHandle.settingsRecoverySource(record, source: store.validationSource) == .current)
            let result = try #require(store.load(cli: false))
            #expect(result.formattedEntry("title") == "title = Current\n")
            #expect(result.errors.isEmpty)
            #expect(store.startupErrors.isEmpty)
            #expect(store.parse(current, dark: true)?.formattedEntry("background") == "background = #445566\n")
        }
    }

    @Test func selectionUsesTheProvidedRecordSnapshot() throws {
        try withStore { store, root in
            let themes = try writeThemes(root)
            let captured = SettingsStore.Record(current: .init(values: ["theme": themes.brokenDark]), previous: .init(values: ["theme": themes.valid]))
            let replacement = SettingsStore.Record(current: .init(values: ["title": "Replacement", "theme": themes.valid]))
            try JSONEncoder().encode(replacement).write(to: store.url)
            #expect(try Ghostty.ConfigHandle.settingsRecoverySource(captured, source: store.validationSource) == .previous)
            #expect(store.load(cli: false)?.formattedEntry("title") == "title = Replacement\n")
        }
    }

    private func withStore(_ body: (SettingsStore, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SettingsStore(legacySource: root.appendingPathComponent("legacy.conf"), directory: root.appendingPathComponent("Settings"))
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try body(store, root)
    }

    private func writeThemes(_ root: URL) throws -> (valid: String, brokenDark: String) {
        let light = root.appendingPathComponent("light")
        let dark = root.appendingPathComponent("dark")
        let broken = root.appendingPathComponent("broken-dark")
        try "background = #112233\n".write(to: light, atomically: true, encoding: .utf8)
        try "background = #445566\n".write(to: dark, atomically: true, encoding: .utf8)
        try "background = invalid-color\n".write(to: broken, atomically: true, encoding: .utf8)
        return ("light:\(light.path),dark:\(dark.path)", "light:\(light.path),dark:\(broken.path)")
    }
}
