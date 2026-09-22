import Foundation
import CryptoKit

extension Ghostty {
    /// Startup-only user file storage. A successful file snapshot is recovery
    /// data, never a second configuration source layered over the user's file.
    @MainActor final class ConfigStore {
        struct Fingerprint: Codable, Equatable {
            let size: UInt64
            let modified: Date
            let created: Date
            let inode: UInt64

            static func read(_ url: URL) throws -> Self? {
                do {
                    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                    guard attrs[.type] as? FileAttributeType == .typeRegular else {
                        throw CocoaError(.fileReadUnsupportedScheme)
                    }
                    return Self(size: (attrs[.size] as? NSNumber)?.uint64Value ?? 0,
                                modified: attrs[.modificationDate] as? Date ?? .distantPast,
                                created: attrs[.creationDate] as? Date ?? .distantPast,
                                inode: (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
                } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                    return nil
                }
            }
        }

        struct Record: Codable {
            let schema: Int
            let source: String
            let build: String
            let fingerprint: Fingerprint?
            let data: Data
            let digest: String
        }

        let source: URL
        let directory: URL
        let build: String
        private(set) var usedSavedInput = false
        private var recordURL: URL { directory.appendingPathComponent("last-success.json") }

        init(source: URL, directory: URL? = nil, build: String? = nil) {
            self.source = source
            self.directory = directory ?? source.deletingLastPathComponent().appendingPathComponent(".config-state")
            self.build = build ?? "\(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "development"):\(Bundle.main.executableURL.flatMap { try? Fingerprint.read($0) }?.modified.timeIntervalSince1970 ?? 0)"
        }

        func load(cli: Bool = true) -> ConfigHandle? {
            usedSavedInput = false
            let previous = readRecord()
            var errors: [String] = []
            do {
                let before = try Fingerprint.read(source)
                let data: Data
                if let previous, previous.build == build, previous.fingerprint == before {
                    data = previous.data
                    usedSavedInput = true
                } else {
                    data = before == nil ? Data() : try Data(contentsOf: source)
                }
                guard let checked = ConfigHandle.load(data: data, source: source) else { return nil }
                if checked.errors.isEmpty {
                    guard try Fingerprint.read(source) == before else {
                        throw CocoaError(.fileReadUnknown)
                    }
                    if !usedSavedInput {
                        do { try save(data, fingerprint: before) } catch {
                            errors.append("无法保存成功配置快照 / Could not save configuration snapshot: \(error.localizedDescription)")
                        }
                    }
                    return applyCLI(data, checked: checked, cli: cli, errors: errors)
                }
                errors += checked.errors
            } catch {
                errors.append("无法读取配置 / Could not read configuration: \(source.path)\n\(error.localizedDescription)")
            }

            // Referenced files and theme resources are revalidated too. A saved
            // main file cannot make missing or broken external resources valid.
            if let previous, let saved = ConfigHandle.load(data: previous.data, source: source), saved.errors.isEmpty {
                errors.insert("用户配置未应用，已恢复上次成功配置。修正后重启生效。 / Using the last successful configuration. Fix the file and restart.", at: 0)
                return applyCLI(previous.data, checked: saved, cli: cli, errors: errors)
            }
            guard let defaults = ConfigHandle.load(data: Data(), source: source) else { return nil }
            errors.insert("配置及快照不可用，已使用内置默认值。 / Using built-in defaults because no valid configuration snapshot is available.", at: 0)
            return applyCLI(Data(), checked: defaults, cli: cli, errors: errors)
        }

        private func applyCLI(_ data: Data, checked: ConfigHandle, cli: Bool, errors: [String]) -> ConfigHandle {
            guard cli, let effective = ConfigHandle.load(data: data, source: source, cli: true) else {
                checked.report(errors)
                return checked
            }
            guard effective.errors.isEmpty else {
                checked.report(errors + effective.errors + ["启动参数无效，未应用本次启动覆盖。 / Invalid command-line configuration was not applied."])
                return checked
            }
            effective.report(errors)
            return effective
        }

        /// Preserve recovery data before resetting; current in-memory config is
        /// untouched and the next startup sees the comment-only guide.
        @discardableResult
        func restoreDefaults() throws -> URL? {
            guard let defaults = ConfigHandle.defaultTemplate else { throw CocoaError(.fileWriteUnknown) }
            try prepareDirectory()
            let existed = try Fingerprint.read(source) != nil
            let data = existed ? try Data(contentsOf: source) : Data()
            let backup = data.isEmpty ? nil : directory.appendingPathComponent("before-reset-\(UUID().uuidString).ghostty")
            if let backup { try data.write(to: backup, options: .atomic) }
            try defaults.write(to: source, options: .atomic)
            // Keep the file and successful snapshot consistent. If committing
            // recovery data fails, restore the original file; its backup remains.
            do {
                try save(defaults, fingerprint: Fingerprint.read(source))
            } catch {
                if existed { try data.write(to: source, options: .atomic) } else {
                    try FileManager.default.removeItem(at: source)
                }
                throw error
            }
            return backup
        }

        private func readRecord() -> Record? {
            guard let data = try? Data(contentsOf: recordURL),
                  let record = try? JSONDecoder().decode(Record.self, from: data),
                  record.schema == 1, record.source == source.path,
                  record.digest == Self.digest(record.data) else { return nil }
            return record
        }

        private func save(_ data: Data, fingerprint: Fingerprint?) throws {
            try prepareDirectory()
            let record = Record(schema: 1, source: source.path, build: build,
                                fingerprint: fingerprint, data: data, digest: Self.digest(data))
            try JSONEncoder().encode(record).write(to: recordURL, options: .atomic)
        }

        private func prepareDirectory() throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }

        private static func digest(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }
}
