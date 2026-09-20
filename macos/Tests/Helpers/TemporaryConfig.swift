import Foundation
@testable import Ghostty
@testable import GhosttyKit

/// Create a temporary config file and delete it when this is deallocated
class TemporaryConfig: Ghostty.Config {
    enum Error: Swift.Error {
        case failedToLoad
    }

    let temporaryFile: URL

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

    isolated deinit {
        try? FileManager.default.removeItem(at: temporaryFile)
    }
}
