import Foundation
import Darwin

/// Application-owned settings. Legacy text files are copied once into immutable
/// input layers; subsequent launches never consult those configuration files.
@MainActor final class SettingsStore {
    nonisolated struct Layer: Codable, Equatable, Sendable {
        var text: String
        var source: URL

        init(text: String, source: URL) { self.text = text; self.source = source }
        private enum CodingKeys: String, CodingKey { case text, source }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            text = try values.decode(String.self, forKey: .text)
            source = URL(fileURLWithPath: try values.decode(String.self, forKey: .source))
        }
        func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(text, forKey: .text)
            try values.encode(source.path, forKey: .source)
        }
    }

    nonisolated struct Input: Codable, Equatable, Sendable {
        var layers: [Layer] = []
        var values: [String: String] = [:]
    }

    nonisolated struct Record: Codable, Sendable {
        var schema = 1
        var revision = UUID()
        var current: Input
        var previous: Input?
    }

    nonisolated enum Failure: LocalizedError, Equatable {
        case invalid([SettingsDiagnostic]), changed, unreadable, unsupported, locked
        var errorDescription: String? {
            switch self {
            case .invalid(let errors): return errors.map(\.rawMessage).joined(separator: "\n")
            case .changed: return "Settings were changed by another app instance. Discard this draft to load the saved settings."
            case .unreadable: return "Unable to read settings. Retry or restore defaults; existing data will be backed up."
            case .locked: return "Settings are busy in another app instance. Your edits are preserved; try saving again."
            case .unsupported: return "These settings require a newer version of the app."
            }
        }
    }

    let directory: URL
    let legacySource: URL
    var url: URL { directory.appendingPathComponent("settings.json") }
    var validationSource: URL { directory.appendingPathComponent("settings") }
    private(set) var startupErrors: [String] = []
    private(set) var runningValues: [String: String] = [:]
    private var disk: Disk { Disk(directory: directory) }
    private(set) var startupValues: [String: String] = [:]

    init(legacySource: URL, directory: URL? = nil) {
        self.legacySource = legacySource
        self.directory = directory ?? legacySource.deletingLastPathComponent().appendingPathComponent("Settings", isDirectory: true)
    }

    func read() throws -> Record { try disk.read() }

    func readAsync() async throws -> Record {
        let disk = disk
        return try await Task.detached(priority: .userInitiated) { try disk.read() }.value
    }

    func load(cli: Bool = true) -> Ghostty.ConfigHandle? {
        let config = loadConfiguration(cli: cli)
        runningValues = Self.values(config)
        return config
    }

    static func values(_ config: Ghostty.ConfigHandle?) -> [String: String] {
        guard let config else { return [:] }
        return Dictionary(uniqueKeysWithValues: SettingsField.catalog.map {
            ($0.key, SettingsField.values(from: config.formattedEntry($0.key)).joined(separator: "\n"))
        })
    }

    private func loadConfiguration(cli: Bool) -> Ghostty.ConfigHandle? {
        startupErrors = []
        startupValues = [:]
        do {
            let record = try FileManager.default.fileExists(atPath: url.path) ? read() : migrate()
            let recovery = evaluateRecovery(record)
            let evaluation = recovery.current
            switch recovery.source {
            case .current:
                guard let result = evaluation.config, evaluation.diagnostics.isEmpty else { throw Failure.invalid(evaluation.diagnostics) }
                startupValues = evaluation.values
                result.report(startupErrors)
                return applyCLI(record.current, checked: result, cli: cli)
            case .previous:
                guard let previous = record.previous else { throw Failure.unreadable }
                guard let recovered = recovery.previous, let config = recovered.config,
                      recovered.diagnostics.isEmpty else { throw Failure.unreadable }
                startupErrors = evaluation.diagnostics.map(\.rawMessage)
                startupErrors.insert("Invalid settings. The last valid settings were restored. Open Settings to correct the errors.", at: 0)
                startupValues = recovered.values
                config.report(startupErrors)
                return applyCLI(previous, checked: config, cli: cli)
            case .defaults:
                startupErrors = evaluation.diagnostics.map(\.rawMessage)
            }
        } catch {
            startupErrors = [error.localizedDescription]
        }
        let defaults = parse(Input(), cli: false)
        startupErrors.insert("Unable to apply saved settings. Built in defaults are in use. Existing data has been preserved.", at: 0)
        startupValues = Self.values(defaults)
        defaults?.report(startupErrors)
        return defaults
    }

    private func applyCLI(_ input: Input, checked: Ghostty.ConfigHandle, cli: Bool) -> Ghostty.ConfigHandle {
        guard cli, Ghostty.ConfigHandle.hasCLIOverrides, let effective = parse(input, cli: true) else { return checked }
        if effective.errors.isEmpty {
            effective.report(checked.errors)
            return effective
        }
        checked.report(effective.errors + ["Invalid launch arguments were ignored. Saved settings remain in effect."])
        return checked
    }

    func parse(_ input: Input, cli: Bool = false, dark: Bool = false) -> Ghostty.ConfigHandle? {
        Ghostty.ConfigHandle.load(settings: input, source: validationSource, cli: cli, dark: dark)
    }

    func validate(_ input: Input) -> [String] { diagnostics(input).map(\.rawMessage) }

    struct Evaluation {
        let config: Ghostty.ConfigHandle?
        let darkConfig: Ghostty.ConfigHandle?
        let values: [String: String]
        let darkValues: [String: String]
        let diagnostics: [SettingsDiagnostic]
    }

    struct RecoveryEvaluation {
        let source: Ghostty.ConfigHandle.SettingsRecoverySource
        let current: Evaluation
        let previous: Evaluation?
    }

    /// Evaluate each appearance once, using only this immutable record snapshot.
    func evaluateRecovery(_ record: Record) -> RecoveryEvaluation {
        let current = evaluate(record.current)
        let previous = current.diagnostics.isEmpty ? nil : record.previous.map(evaluate)
        let source = Ghostty.ConfigHandle.settingsRecoverySource(
            currentValid: current.diagnostics.isEmpty,
            previousValid: previous?.diagnostics.isEmpty == true)
        return RecoveryEvaluation(source: source, current: current, previous: previous)
    }

    func diagnostics(_ input: Input) -> [SettingsDiagnostic] { evaluate(input).diagnostics }

    func fieldDiagnostics(_ input: Input) -> [SettingsDiagnostic] {
        var errors: [SettingsDiagnostic] = SettingsField.catalogError.map { [$0] } ?? []
        errors += input.values.keys.sorted().filter { SettingsField.byKey[$0] == nil }.map {
            SettingsDiagnostic(kind: .field, message: "Unknown setting: \($0)")
        }
        for field in SettingsField.catalog {
            if let value = input.values[field.key], let error = field.validate(value) {
                errors.append(SettingsDiagnostic(key: field.key, kind: .field, message: error))
            }
        }
        return errors
    }

    func evaluate(_ input: Input) -> Evaluation {
        let config = parse(input)
        let darkConfig = parse(input, dark: true)
        // Formatting failures must block editing/saving instead of becoming an
        // empty repeatable value that can overwrite inherited settings.
        let values = Self.values(config)
        let darkValues = Self.values(darkConfig)
        var errors = fieldDiagnostics(input)
        let explainedKeys = Set(errors.compactMap(\.key))
        let parserError = SettingsDiagnostic(kind: .core, message: "Unable to create the settings parser.")
        let coreErrors = (config?.settingsDiagnostics ?? [parserError]) + (darkConfig?.settingsDiagnostics ?? [parserError])
        errors += coreErrors.filter { !explainedKeys.contains($0.key ?? "") }
        var seen = Set<SettingsDiagnostic>()
        return Evaluation(config: config, darkConfig: darkConfig, values: values, darkValues: darkValues,
                          diagnostics: errors.filter { seen.insert($0).inserted })
    }

    @discardableResult
    func save(_ input: Input, revision: UUID) throws -> Record {
        try saveEvaluated(input, revision: revision).record
    }

    struct Saved {
        let record: Record
        let evaluation: Evaluation
    }

    func saveEvaluated(_ input: Input, revision: UUID) throws -> Saved {
        let saved = try prepareSave(input, replacing: read(), revision: revision)
        try disk.withLock { try disk.commit(saved.record, replacing: revision) }
        return saved
    }

    private func prepareSave(_ input: Input, replacing old: Record, revision: UUID) throws -> Saved {
        let evaluation = evaluate(input)
        guard evaluation.diagnostics.isEmpty else { throw Failure.invalid(evaluation.diagnostics) }
        guard old.revision == revision else { throw Failure.changed }
        let previous = validate(old.current).isEmpty ? old.current : old.previous
        return Saved(record: Record(current: input, previous: previous), evaluation: evaluation)
    }

    @discardableResult
    func restoreDefaults() throws -> URL? {
        try disk.withLock { try disk.reset() }
    }

    func restoreDefaultsAsync() async throws -> URL? {
        let disk = disk
        let task = Task.detached(priority: .userInitiated) { try await disk.withLockAsync { try disk.reset() } }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func saveEvaluatedAsync(_ input: Input, revision: UUID) async throws -> Saved {
        let old = try await readAsync()
        try Task.checkCancellation()
        let saved = try prepareSave(input, replacing: old, revision: revision)
        let disk = disk
        let record = saved.record
        let task = Task.detached(priority: .userInitiated) {
            try await disk.withLockAsync { try disk.commit(record, replacing: revision) }
        }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        return saved
    }

    private func migrate() throws -> Record {
        try disk.withLock {
            // Another instance may have finished migration while we waited.
            if FileManager.default.fileExists(atPath: url.path) { return try read() }
            return try importLegacy()
        }
    }

    private func importLegacy() throws -> Record {
        let exists = FileManager.default.fileExists(atPath: legacySource.path)
        let original = exists ? try Data(contentsOf: legacySource) : Data()
        var data = original
        guard var checked = Ghostty.ConfigHandle.load(data: data, source: legacySource) else { throw Failure.unreadable }
        if !checked.errors.isEmpty {
            let recoveryDirectory = directory.lastPathComponent.hasPrefix(".settings-state-") ?
                legacySource.deletingLastPathComponent().appendingPathComponent(".config-state-" + legacySource.lastPathComponent) : nil
            let legacy = SettingsLegacyMigration(source: legacySource, directory: recoveryDirectory)
            guard let saved = legacy.successfulMigrationData(),
                  let recovered = Ghostty.ConfigHandle.load(data: saved, source: legacySource) else {
                throw Failure.invalid([SettingsDiagnostic(kind: .storage, message: "The old configuration contains errors and could not be imported. The original file was preserved. Restore defaults to continue.")] + checked.settingsDiagnostics)
            }
            startupErrors = ["The old configuration contains errors. The last valid configuration was imported. The original file was preserved. Use Settings for future changes."] + checked.errors
            data = saved
            checked = recovered
        }
        let layers = try checked.sourceFiles()
        guard let darkChecked = Ghostty.ConfigHandle.load(data: data, source: legacySource, dark: true) else { throw Failure.unreadable }
        guard darkChecked.errors.isEmpty else { throw Failure.invalid(darkChecked.settingsDiagnostics) }
        // User includes currently have no conditional syntax. Require identical
        // source graphs rather than merging branches that could change meaning.
        guard try darkChecked.sourceFiles() == layers else { throw Failure.changed }
        let input = Input(layers: layers)
        // Compare against the bytes that will be imported before committing.
        if exists, try Data(contentsOf: legacySource) != original { throw Failure.changed }
        for layer in layers where layer.source != legacySource {
            if try Data(contentsOf: layer.source) != Data(layer.text.utf8) { throw Failure.changed }
        }
        let evaluation = evaluate(input)
        guard evaluation.diagnostics.isEmpty else { throw Failure.invalid(evaluation.diagnostics) }
        guard let imported = evaluation.config, imported.hasSameSettings(as: checked),
              let darkImported = evaluation.darkConfig, darkImported.hasSameSettings(as: darkChecked) else { throw Failure.changed }
        let record = Record(current: input)
        try disk.write(record)
        return record
    }

    /// Only immutable records cross executors; core handles stay on MainActor.
    nonisolated struct Disk: Sendable {
        let directory: URL
        var url: URL { directory.appendingPathComponent("settings.json") }
        static let maximumRecordBytes = 16 * 1024 * 1024

        func read() throws -> Record {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            // Bound allocation before decoding, including files that grow while read.
            let data = try handle.read(upToCount: Self.maximumRecordBytes + 1) ?? Data()
            guard data.count <= Self.maximumRecordBytes else { throw Failure.unreadable }
            let record = try JSONDecoder().decode(Record.self, from: data)
            guard record.schema == 1 else { throw Failure.unsupported }
            return record
        }

        /// Recheck under the lock: validation may race another instance's save.
        func commit(_ record: Record, replacing revision: UUID) throws {
            guard try read().revision == revision else { throw Failure.changed }
            try write(record)
        }

        func reset() throws -> URL? {
            let backup: URL?
            if FileManager.default.fileExists(atPath: url.path) {
                let target = directory.appendingPathComponent("before-reset-\(UUID().uuidString).json")
                try FileManager.default.copyItem(at: url, to: target)
                backup = target
            } else { backup = nil }
            try write(Record(current: Input()))
            return backup
        }

        func prepareDirectory() throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }

        func write(_ record: Record) throws {
            try prepareDirectory()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(record)
            guard data.count <= Self.maximumRecordBytes else {
                throw Failure.invalid([SettingsDiagnostic(kind: .storage, message: "Settings are too large to save. Reduce their size and try again.")])
            }
            let temporary = directory.appendingPathComponent(".settings-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try data.write(to: temporary, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            // Set permissions before the only commit point. A failed write cannot
            // replace the previous complete record or claim an unsuccessful save.
            guard rename(temporary.path, url.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        }

        private func openLock() throws -> Int32 {
            try prepareDirectory()
            let descriptor = open(directory.appendingPathComponent("settings.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            return descriptor
        }

        private func acquire(_ descriptor: Int32, deadline: ContinuousClock.Instant) throws -> Bool {
            try Task.checkCancellation()
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return true }
            let code = errno
            guard code == EWOULDBLOCK || code == EINTR else { throw POSIXError(.init(rawValue: code) ?? .EIO) }
            guard ContinuousClock.now < deadline else { throw Failure.locked }
            return false
        }

        func withLock<T>(timeout: Duration = .seconds(2), _ operation: () throws -> T) throws -> T {
            let descriptor = try openLock()
            defer { close(descriptor) }
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while try !acquire(descriptor, deadline: deadline) { Thread.sleep(forTimeInterval: 0.02) }
            defer { flock(descriptor, LOCK_UN) }
            try Task.checkCancellation()
            return try operation()
        }

        func withLockAsync<T: Sendable>(timeout: Duration = .seconds(2), _ operation: @Sendable () throws -> T) async throws -> T {
            let descriptor = try openLock()
            defer { close(descriptor) }
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while try !acquire(descriptor, deadline: deadline) { try await Task.sleep(for: .milliseconds(20)) }
            defer { flock(descriptor, LOCK_UN) }
            // Cancellation is accepted before the transaction starts. Once the
            // atomic rename commits, report success even if cancellation arrives.
            try Task.checkCancellation()
            return try operation()
        }
    }
}
