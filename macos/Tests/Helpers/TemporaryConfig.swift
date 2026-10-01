import Foundation
@testable import Ghostty
@testable import GhosttyKit

/// Create a temporary config file and delete it when this is deallocated
class TemporaryConfig: Ghostty.Config {
    enum Error: Swift.Error {
        case failedToLoad
    }

    let temporaryFile: URL

    private var settingsDirectory: URL {
        temporaryFile.deletingLastPathComponent()
            .appendingPathComponent(".settings-state-" + temporaryFile.lastPathComponent)
    }

    init(_ configText: String, finalize: Bool = true) throws {
        let temporaryFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("ghostty")
        try configText.write(to: temporaryFile, atomically: true, encoding: .utf8)
        self.temporaryFile = temporaryFile
        super.init(handle: Ghostty.ConfigHandle.load(at: temporaryFile.path(), finalize: finalize))
    }

    func reload(_ newConfigText: String?, finalize: Bool = true) throws {
        if let newConfigText {
            try newConfigText.write(to: temporaryFile, atomically: true, encoding: .utf8)
        }
        guard let cfg = Ghostty.ConfigHandle.load(at: temporaryFile.path(), finalize: finalize) else {
            throw Error.failedToLoad
        }
        replace(with: cfg)
    }

    /// Save through the same store as Settings after an App has migrated this
    /// fixture. Existing App and Config instances keep their loaded snapshots.
    func saveAppSettings(_ values: [String: String]) throws {
        let store = SettingsStore(legacySource: temporaryFile, directory: settingsDirectory)
        let record = try store.read()
        var edited = record.current
        edited.values.merge(values) { _, new in new }
        try store.save(edited, revision: record.revision)
    }

    isolated deinit {
        try? FileManager.default.removeItem(at: temporaryFile)
        try? FileManager.default.removeItem(at: settingsDirectory)
    }
}
