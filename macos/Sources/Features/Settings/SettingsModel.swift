import Foundation

@MainActor final class SettingsModel {
    let store: SettingsStore
    private(set) var record: SettingsStore.Record?
    private(set) var input = SettingsStore.Input()
    private(set) var displayed: [String: String] = [:]
    private(set) var errors: [String] = []
    private(set) var status = ""
    private var inputIsValid = false
    var dirty: Bool { record.map { $0.current != input } ?? false }
    var canSave: Bool { dirty && inputIsValid && record != nil }

    init(store: SettingsStore) {
        self.store = store
        reload()
    }

    func reload() {
        do {
            let loaded = try store.read()
            record = loaded
            input = loaded.current
            displayed = [:]
            if let parsed = store.parse(input) {
                for field in SettingsField.catalog {
                    displayed[field.key] = SettingsField.values(from: parsed.formattedEntry(field.key)).joined(separator: "\n")
                }
            }
            // Invalid edits in a damaged record must remain visible and fixable.
            input.values.forEach { displayed[$0.key] = $0.value }
            errors = store.validate(input)
            inputIsValid = errors.isEmpty
            status = "Settings are stored in the app. Restart after saving to apply changes."
        } catch {
            record = nil
            inputIsValid = false
            errors = [error.localizedDescription]
            status = "Unable to read settings. Retry or restore defaults."
        }
    }

    func edit(_ field: SettingsField, value: String) {
        edit([field.key: value])
    }

    var usesBundledFontPreset: Bool {
        let family = displayed["font-family", default: ""].components(separatedBy: "\n").first ?? ""
        let style = displayed["font-style", default: "default"].lowercased()
        return (family.isEmpty || family == SettingsFontPicker.bundledFamily)
            && ["", "default", "medium"].contains(style)
            && displayed["font-thicken"] == "true" && displayed["font-thicken-strength"] == "255"
    }

    func applyBundledFontPreset(families: String) {
        // The bundled family's automatic face is Medium. Leave style discovery
        // automatic so later choices and fallback families use their own face.
        edit(["font-family": families, "font-style": "default", "font-thicken": "true", "font-thicken-strength": "255"])
    }

    private func edit(_ changes: [String: String]) {
        let original = record?.current
        let parsed = original.flatMap { store.parse($0) }
        // Returning a field to its original value should also remove its dirty
        // state, instead of introducing an unnecessary explicit override.
        for (key, value) in changes {
            displayed[key] = value
            input.values[key] = value
            if let original, let parsed {
                let initial = original.values[key] ?? SettingsField.values(from: parsed.formattedEntry(key)).joined(separator: "\n")
                if value == initial { input.values[key] = original.values[key] }
            }
        }
        errors = store.validate(input)
        inputIsValid = errors.isEmpty
        status = errors.isEmpty ? "Unsaved changes. Restart after saving to apply changes." : "Fix the invalid settings before saving."
    }

    func error(for key: String) -> String? {
        errors.filter { $0.contains(key) }.joined(separator: "\n").nonEmpty
    }

    @discardableResult
    func save() -> Bool {
        guard let record else { return false }
        do {
            self.record = try store.save(input, revision: record.revision)
            errors = []
            status = "Saved. Restart the app to apply changes."
            return true
        } catch {
            errors = [error.localizedDescription]
            status = "Unable to save. Your edits are still available in this window."
            return false
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
