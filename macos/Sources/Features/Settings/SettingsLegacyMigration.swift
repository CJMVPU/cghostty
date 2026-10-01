import Foundation
import CryptoKit

/// Read-only compatibility with snapshots written before application-owned settings.
/// Unknown legacy fields (build and fingerprint) are intentionally ignored.
@MainActor struct SettingsLegacyMigration {
    private struct Record: Decodable {
        let schema: Int
        let source: String
        let data: Data
        let digest: String
    }

    let source: URL
    let directory: URL

    init(source: URL, directory: URL? = nil) {
        self.source = source
        self.directory = directory ?? source.deletingLastPathComponent().appendingPathComponent(".config-state")
    }

    func successfulMigrationData() -> Data? {
        let url = directory.appendingPathComponent("last-success.json")
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.schema == 1, record.source == source.path,
              record.digest == SHA256.hash(data: record.data).map({ String(format: "%02x", $0) }).joined(),
              let checked = Ghostty.ConfigHandle.load(data: record.data, source: source), checked.errors.isEmpty else { return nil }
        return record.data
    }
}
