import Foundation
import GhosttyKit

/// Each call owns its parser allocations on the calling executor. Only value
/// projections leave the call; raw handles are never sent between executors.
nonisolated struct SettingsEvaluator: Sendable {
    let source: URL
    let fields: [SettingsField]
    let catalogError: SettingsDiagnostic?

    struct Projection: Sendable {
        let values: [String: String]
        let darkValues: [String: String]
        let diagnostics: [SettingsDiagnostic]
    }

    struct Inheritance: Sendable {
        let original: SettingsStore.Input
        let displayed: [String: String]
        let keys: Set<String>
    }

    struct Draft: Sendable {
        let input: SettingsStore.Input
        let evaluation: Projection
    }

    func evaluateDraft(_ input: SettingsStore.Input, restoring inheritance: Inheritance?) throws -> Draft {
        var input = input
        var resolved: Projection?
        if let inheritance {
            for key in inheritance.keys.sorted() {
                guard input.values[key] == inheritance.displayed[key] else { continue }
                var candidate = input
                candidate.values[key] = inheritance.original.values[key]
                let evaluation = try evaluate(candidate)
                if evaluation.diagnostics.isEmpty, evaluation.values[key] == input.values[key] {
                    input = candidate
                    resolved = evaluation
                }
            }
        }
        return try Draft(input: input, evaluation: resolved ?? evaluate(input))
    }

    static func makeConfig(data: Data, source: URL, dark: Bool) -> ghostty_config_t? {
        guard let config = ghostty_config_new() else { return nil }
        ghostty_config_set_initial_theme(config, dark)
        let loaded = data.withUnsafeBytes { bytes in
            source.path.withCString { path in
                ghostty_settings_load(config, bytes.bindMemory(to: UInt8.self).baseAddress!, bytes.count, path)
            }
        }
        guard loaded else { ghostty_config_free(config); return nil }
        return config
    }

    func fieldDiagnostics(_ input: SettingsStore.Input) -> [SettingsDiagnostic] {
        let keys = Set(fields.map(\.key))
        var errors = catalogError.map { [$0] } ?? []
        errors += input.values.keys.sorted().filter { !keys.contains($0) }.map {
            SettingsDiagnostic(kind: .field, message: "Unknown setting: \($0)")
        }
        for field in fields {
            if let value = input.values[field.key], let error = field.validate(value) {
                errors.append(SettingsDiagnostic(key: field.key, kind: .field, message: error))
            }
        }
        return errors
    }

    func evaluate(_ input: SettingsStore.Input) throws -> Projection {
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(input)
        let light = try branch(data, dark: false)
        let dark = try branch(data, dark: true)
        let fieldErrors = fieldDiagnostics(input)
        let explained = Set(fieldErrors.compactMap(\.key))
        var seen = Set<SettingsDiagnostic>()
        let errors = fieldErrors + (light.diagnostics + dark.diagnostics).filter { !explained.contains($0.key ?? "") }
        return Projection(values: light.values, darkValues: dark.values,
                          diagnostics: errors.filter { seen.insert($0).inserted })
    }

    private func branch(_ data: Data, dark: Bool) throws -> (values: [String: String], diagnostics: [SettingsDiagnostic]) {
        try Task.checkCancellation()
        guard let config = Self.makeConfig(data: data, source: source, dark: dark) else {
            return ([:], [SettingsDiagnostic(kind: .core, message: "Unable to create the settings parser.")])
        }
        defer { ghostty_config_free(config) }
        ghostty_config_finalize(config)
        var values: [String: String] = [:]
        var errors = (0..<ghostty_config_diagnostics_count(config)).map {
            SettingsDiagnostic(core: ghostty_config_get_diagnostic(config, UInt32($0)))
        }
        for field in fields {
            try Task.checkCancellation()
            let entry = field.key.withCString { ghostty_config_format_entry(config, $0, field.key.utf8.count) }
            guard entry.ptr != nil else {
                errors.append(SettingsDiagnostic(key: field.key, kind: .core, message: "Unable to read the setting value."))
                values[field.key] = ""
                continue
            }
            values[field.key] = SettingsField.values(from: Ghostty.AllocatedString(entry).string).joined(separator: "\n")
        }
        return (values, errors)
    }

    func prepareSave(_ input: SettingsStore.Input, replacing old: SettingsStore.Record, revision: UUID,
                     restoring inheritance: Inheritance? = nil) throws -> SettingsStore.Saved {
        let draft = try evaluateDraft(input, restoring: inheritance)
        let evaluation = draft.evaluation
        guard evaluation.diagnostics.isEmpty else { throw SettingsStore.Failure.invalid(evaluation.diagnostics) }
        guard old.revision == revision else { throw SettingsStore.Failure.changed }
        let previous = try evaluate(old.current).diagnostics.isEmpty ? old.current : old.previous
        try Task.checkCancellation()
        return SettingsStore.Saved(record: .init(current: draft.input, previous: previous), evaluation: evaluation, replacingRevision: revision)
    }
}
