import Foundation
import Darwin

/// Application-owned settings. Legacy text files are copied once into immutable
/// input layers; subsequent launches never consult those configuration files.
@MainActor final class SettingsStore {
    struct Layer: Codable, Equatable {
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

    struct Input: Codable, Equatable {
        var layers: [Layer] = []
        var values: [String: String] = [:]
    }

    struct Record: Codable {
        var schema = 1
        var revision = UUID()
        var current: Input
        var previous: Input?
    }

    enum Failure: LocalizedError, Equatable {
        case invalid([String]), changed, unreadable, unsupported
        var errorDescription: String? {
            switch self {
            case .invalid(let errors): return errors.joined(separator: "\n")
            case .changed: return "设置已被另一个窗口或应用实例修改。请重新读取后再编辑。"
            case .unreadable: return "无法读取应用设置。可重试，或使用“恢复默认设置”；原数据会先备份。"
            case .unsupported: return "设置来自较新版本，当前版本无法编辑。请使用较新版本的应用。"
            }
        }
    }

    let directory: URL
    let legacySource: URL
    var url: URL { directory.appendingPathComponent("settings.json") }
    var validationSource: URL { directory.appendingPathComponent("settings") }
    private(set) var startupErrors: [String] = []
    private static let maximumRecordBytes = 16 * 1024 * 1024

    init(legacySource: URL, directory: URL? = nil) {
        self.legacySource = legacySource
        self.directory = directory ?? legacySource.deletingLastPathComponent().appendingPathComponent("Settings", isDirectory: true)
    }

    func read() throws -> Record {
        let data = try Data(contentsOf: url)
        guard data.count <= Self.maximumRecordBytes else { throw Failure.unreadable }
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard record.schema == 1 else { throw Failure.unsupported }
        return record
    }

    func load(cli: Bool = true) -> Ghostty.ConfigHandle? {
        startupErrors = []
        do {
            let record = try FileManager.default.fileExists(atPath: url.path) ? read() : migrate()
            let result = parse(record.current)
            let errors = validate(record.current)
            if let result, errors.isEmpty && result.errors.isEmpty {
                result.report(startupErrors)
                return applyCLI(record.current, checked: result, cli: cli)
            }
            startupErrors = errors + (result?.errors ?? ["无法解析设置。"])
            if let previous = record.previous, validate(previous).isEmpty, let recovered = parse(previous), recovered.errors.isEmpty {
                startupErrors.insert("设置无效，已使用上次成功设置。请在设置窗口修正。", at: 0)
                recovered.report(startupErrors)
                return applyCLI(previous, checked: recovered, cli: cli)
            }
        } catch {
            startupErrors = [error.localizedDescription]
        }
        let defaults = parse(Input(), cli: false)
        startupErrors.insert("无法应用已保存设置，当前使用内置默认值。原数据已保留。", at: 0)
        defaults?.report(startupErrors)
        return defaults
    }

    private func applyCLI(_ input: Input, checked: Ghostty.ConfigHandle, cli: Bool) -> Ghostty.ConfigHandle {
        guard cli, Ghostty.ConfigHandle.hasCLIOverrides, let effective = parse(input, cli: true) else { return checked }
        if effective.errors.isEmpty {
            effective.report(checked.errors)
            return effective
        }
        checked.report(effective.errors + ["启动参数无效，本次启动未应用这些覆盖；已保存设置保持有效。"])
        return checked
    }

    func parse(_ input: Input, cli: Bool = false) -> Ghostty.ConfigHandle? {
        Ghostty.ConfigHandle.load(settings: input, source: validationSource, cli: cli)
    }

    func validate(_ input: Input) -> [String] {
        let known = Set(SettingsField.catalog.map(\.key))
        var errors = input.values.keys.filter { !known.contains($0) }.map { "未知设置：\($0)" }
        var explainedKeys = Set<String>()
        for field in SettingsField.catalog {
            if let value = input.values[field.key], let error = field.validate(value) {
                errors.append("\(field.key): \(error)")
                explainedKeys.insert(field.key)
            }
        }
        let coreErrors = parse(input)?.errors ?? ["无法创建配置解析器。"]
        errors += coreErrors.filter { diagnostic in
            !explainedKeys.contains { diagnostic.hasPrefix($0 + ":") }
        }
        return errors
    }

    @discardableResult
    func save(_ input: Input, revision: UUID) throws -> Record {
        let errors = validate(input)
        guard errors.isEmpty else { throw Failure.invalid(errors) }
        return try withLock {
            let old = try read()
            guard old.revision == revision else { throw Failure.changed }
            let previous = validate(old.current).isEmpty ? old.current : old.previous
            let record = Record(current: input, previous: previous)
            try write(record)
            return record
        }
    }

    @discardableResult
    func restoreDefaults() throws -> URL? {
        try withLock { try reset() }
    }

    private func reset() throws -> URL? {
        let backup: URL?
        if FileManager.default.fileExists(atPath: url.path) {
            let target = directory.appendingPathComponent("before-reset-\(UUID().uuidString).json")
            try Data(contentsOf: url).write(to: target, options: .atomic)
            backup = target
        } else { backup = nil }
        try write(Record(current: Input()))
        return backup
    }

    private func migrate() throws -> Record {
        try withLock {
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
            let legacy = Ghostty.ConfigStore(source: legacySource, directory: recoveryDirectory)
            guard let saved = legacy.successfulMigrationData(),
                  let recovered = Ghostty.ConfigHandle.load(data: saved, source: legacySource) else {
                throw Failure.invalid(["旧配置存在错误，尚未迁移。原文件已保留，可恢复默认设置后继续。"] + checked.errors)
            }
            startupErrors = ["旧配置存在错误，已迁入上次成功配置。原文件已保留，后续请使用设置窗口。"] + checked.errors
            data = saved
            checked = recovered
        }
        guard let text = String(data: data, encoding: .utf8) else { throw Failure.unreadable }
        var input = Input(layers: text.isEmpty ? [] : [Layer(text: text, source: legacySource)])
        // The core has already resolved the include graph, in its actual load
        // order, including paths relative to each source and optional includes.
        for value in SettingsField.values(from: checked.formattedEntry("config-file")) where !value.isEmpty {
            let optional = value.hasPrefix("?")
            let path = optional ? String(value.dropFirst()) : value
            let source = URL(fileURLWithPath: path)
            if optional && !FileManager.default.fileExists(atPath: source.path) { continue }
            input.layers.append(Layer(text: try String(contentsOf: source, encoding: .utf8), source: source))
        }
        // Compare against the bytes that will be imported before committing.
        if exists, try Data(contentsOf: legacySource) != original { throw Failure.changed }
        let errors = validate(input)
        guard errors.isEmpty else { throw Failure.invalid(errors) }
        guard let imported = parse(input), imported.hasSameSettings(as: checked) else { throw Failure.changed }
        let record = Record(current: input)
        try write(record)
        return record
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    private func write(_ record: Record) throws {
        try prepareDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        guard data.count <= Self.maximumRecordBytes else {
            throw Failure.invalid(["设置内容过大，无法保存。请减少设置内容后重试。"])
        }
        let temporary = directory.appendingPathComponent(".settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        // Set permissions before the only commit point. A failed write cannot
        // replace the previous complete record or claim an unsuccessful save.
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    private func withLock<T>(_ operation: () throws -> T) throws -> T {
        try prepareDirectory()
        let descriptor = open(directory.appendingPathComponent("settings.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }
}
