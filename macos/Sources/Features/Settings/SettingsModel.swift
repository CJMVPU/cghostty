import Foundation

@MainActor final class SettingsModel {
    let store: SettingsStore
    private(set) var record: SettingsStore.Record?
    private(set) var input = SettingsStore.Input()
    private(set) var displayed: [String: String] = [:]
    private(set) var errors: [String] = []
    private(set) var status = ""
    private var inputIsValid = false
    private var originalDisplayed: [String: String] = [:]
    private var restartRequired = false
    private var savedStatus: String { restartRequired ? "Saved. Restart the app to apply changes." : "No unsaved changes." }
    var dirty: Bool { record.map { $0.current != input } ?? false }
    var changedCount: Int {
        guard let original = record?.current else { return 0 }
        return Set(original.values.keys).union(input.values.keys).filter { original.values[$0] != input.values[$0] }.count
    }
    var canSave: Bool { dirty && inputIsValid && record != nil }

    init(store: SettingsStore) {
        self.store = store
        reload()
    }

    func reload(afterReset: Bool = false) {
        if afterReset { restartRequired = true }
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
            originalDisplayed = displayed
            errors = store.validate(input)
            inputIsValid = errors.isEmpty
            status = savedStatus
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
        // Returning a field to its original value should also remove its dirty
        // state, instead of introducing an unnecessary explicit override.
        for (key, value) in changes {
            displayed[key] = value
            input.values[key] = value
            if let original, let initial = originalDisplayed[key] {
                if value == initial { input.values[key] = original.values[key] }
            }
        }
        errors = store.validate(input)
        inputIsValid = errors.isEmpty
        if !errors.isEmpty {
            status = "Fix the invalid settings before saving."
        } else if dirty {
            status = "\(changedCount) modified \(changedCount == 1 ? "setting" : "settings"). Restart after saving to apply changes."
        } else { status = savedStatus }
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
            originalDisplayed = displayed
            restartRequired = true
            status = savedStatus
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
