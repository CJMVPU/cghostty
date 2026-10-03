import Foundation
import Darwin
import Testing
@testable import Ghostty

@MainActor struct SettingsSourceTests {
    private func withSource(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.appendingPathComponent("config.ghostty"))
    }

    /// Foundation and the core may represent /var and /private/var differently.
    /// Compare file identities while keeping content and ordering assertions exact.
    private func sourcePaths(_ urls: [URL]) throws -> [String] {
        try urls.map { url in
            guard let path = url.path.withCString({ realpath($0, nil) }) else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            defer { free(path) }
            return String(cString: path)
        }
    }

    @Test func migrationPreservesSourceThatClearsIncludeList() throws {
        try withSource { source in
            let child = source.deletingLastPathComponent().appendingPathComponent("child.conf")
            let rootText = "font-size = 18\nconfig-file = child.conf\nconfig-file = skipped.conf\n"
            let childText = "font-size = 23\nconfig-file =\n"
            try rootText.write(to: source, atomically: true, encoding: .utf8)
            try childText.write(to: child, atomically: true, encoding: .utf8)
            let checked = try #require(Ghostty.ConfigHandle.load(data: Data(rootText.utf8), source: source))
            #expect(checked.errors.isEmpty)
            let snapshot = try checked.sourceFiles()
            #expect(snapshot.map(\.text) == [rootText, childText])
            #expect(try sourcePaths(snapshot.map(\.source)) == sourcePaths([source, child]))
            let store = SettingsStore(legacySource: source)
            let config = try #require(store.load(cli: false))
            #expect(config.errors.isEmpty)
            #expect(config.formattedEntry("font-size") == "font-size = 23\n")
            #expect(try store.read().current.layers == snapshot)
            try FileManager.default.removeItem(at: source)
            try FileManager.default.removeItem(at: child)
            let restarted = try #require(SettingsStore(legacySource: source).load(cli: false))
            #expect(restarted.errors.isEmpty)
            #expect(restarted.formattedEntry("font-size") == "font-size = 23\n")
        }
    }

    @Test func migrationPreservesActualOrderWhenChildReplacesIncludeList() throws {
        try withSource { source in
            let root = source.deletingLastPathComponent()
            let child = root.appendingPathComponent("child.conf")
            let grandchild = root.appendingPathComponent("grandchild.conf")
            let light = root.appendingPathComponent("Light")
            let rootText = "theme = \(light.path)\nconfig-file = child.conf\nconfig-file = abandoned.conf\n"
            let childText = "font-size = 23\nconfig-file =\nconfig-file = ?not-read.conf\nconfig-file = grandchild.conf\n"
            let grandchildText = "title = Nested\n"
            try rootText.write(to: source, atomically: true, encoding: .utf8)
            try childText.write(to: child, atomically: true, encoding: .utf8)
            try grandchildText.write(to: grandchild, atomically: true, encoding: .utf8)
            try "background = #123456".write(to: light, atomically: true, encoding: .utf8)
            let checked = try #require(Ghostty.ConfigHandle.load(data: Data(rootText.utf8), source: source))
            #expect(checked.errors.isEmpty)
            let snapshot = try checked.sourceFiles()
            #expect(snapshot.map(\.text) == [rootText, childText, grandchildText])
            #expect(try sourcePaths(snapshot.map(\.source)) == sourcePaths([source, child, grandchild]))
            let clone = try #require(Ghostty.ConfigHandle(cloning: checked.value))
            #expect(try clone.sourceFiles() == snapshot)
            let store = SettingsStore(legacySource: source)
            let config = try #require(store.load(cli: false))
            #expect(config.errors.isEmpty)
            #expect(config.formattedEntry("font-size") == "font-size = 23\n")
            #expect(config.formattedEntry("title") == "title = Nested\n")
            #expect(try store.read().current.layers == snapshot)
        }
    }
}
