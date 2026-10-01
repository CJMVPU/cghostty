import Foundation
import CryptoKit
import Testing
@testable import Ghostty

@MainActor enum LegacySettingsFixture {
    @discardableResult static func write(_ text: String, source: URL, directory: URL? = nil) throws -> URL {
        let directory = directory ?? source.deletingLastPathComponent().appendingPathComponent(".config-state")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = Data(text.utf8)
        let record: [String: Any] = [
            "schema": 1, "source": source.path, "build": "legacy-build",
            "fingerprint": ["size": data.count, "modified": 123.0, "created": 100.0, "inode": 42],
            "data": data.base64EncodedString(),
            "digest": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        ]
        let url = directory.appendingPathComponent("last-success.json")
        try JSONSerialization.data(withJSONObject: record).write(to: url)
        return url
    }
}

@MainActor struct SettingsLegacyMigrationTests {
    private func withSource(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.appendingPathComponent("config.ghostty"))
    }

    @Test func migratesSnapshotIncludesWithoutWritingLegacyFiles() throws {
        try withSource { source in
            let child = source.deletingLastPathComponent().appendingPathComponent("child.conf")
            try "font-size = 19".write(to: child, atomically: true, encoding: .utf8)
            let snapshot = try LegacySettingsFixture.write("title = Previous\nconfig-file = child.conf", source: source)
            let original = try Data(contentsOf: snapshot)
            try "font-size = invalid".write(to: source, atomically: true, encoding: .utf8)
            let store = SettingsStore(legacySource: source)
            let parsed = try #require(store.load(cli: false))
            #expect(parsed.formattedEntry("font-size") == "font-size = 19\n")
            #expect(parsed.formattedEntry("title") == "title = Previous\n")
            #expect(try Data(contentsOf: snapshot) == original)
            #expect(try String(contentsOf: source, encoding: .utf8) == "font-size = invalid")
            try FileManager.default.removeItem(at: child)
            try FileManager.default.removeItem(at: snapshot)
            #expect(store.load(cli: false)?.errors.isEmpty == true)
        }
    }

    @Test(arguments: ["schema", "source", "digest", "payload", "json"])
    func rejectsUnusableSnapshots(_ fault: String) throws {
        try withSource { source in
            let url = try LegacySettingsFixture.write(fault == "payload" ? "font-size = invalid" : "font-size = 19", source: source)
            if fault == "json" { try Data("broken".utf8).write(to: url) } else if fault != "payload" {
                var record = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
                switch fault {
                case "schema": record["schema"] = 2
                case "source": record["source"] = "/another/config.ghostty"
                default: record["digest"] = "invalid"
                }
                try JSONSerialization.data(withJSONObject: record).write(to: url)
            }
            let before = try Data(contentsOf: url)
            #expect(SettingsLegacyMigration(source: source).successfulMigrationData() == nil)
            #expect(try Data(contentsOf: url) == before)
        }
    }

    @Test func missingSnapshotDoesNotCreateFiles() throws {
        try withSource { source in
            let reader = SettingsLegacyMigration(source: source)
            #expect(reader.successfulMigrationData() == nil)
            #expect(!FileManager.default.fileExists(atPath: reader.directory.path))
            #expect(!FileManager.default.fileExists(atPath: source.path))
        }
    }

    @Test func customSnapshotDirectoryAndLegacySymlinkArePreserved() throws {
        try withSource { source in
            let target = source.deletingLastPathComponent().appendingPathComponent("shared.conf")
            try "font-size = invalid".write(to: target, atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(at: source, withDestinationURL: target)
            let recovery = source.deletingLastPathComponent().appendingPathComponent(".config-state-" + source.lastPathComponent)
            try LegacySettingsFixture.write("font-size = 21", source: source, directory: recovery)
            let directory = source.deletingLastPathComponent().appendingPathComponent(".settings-state-" + source.lastPathComponent)
            let store = SettingsStore(legacySource: source, directory: directory)
            #expect(store.load(cli: false)?.formattedEntry("font-size") == "font-size = 21\n")
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: source.path) == target.path)
            #expect(try String(contentsOf: target, encoding: .utf8) == "font-size = invalid")
        }
    }
}
