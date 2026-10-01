import Foundation

@MainActor final class SettingsModel {
    let store: SettingsStore
    private(set) var record: SettingsStore.Record?
    private(set) var input = SettingsStore.Input()
    /// Raw edits remain in input; these snapshots contain resolved core values.
    private(set) var effectiveValues: [String: String] = [:]
    private(set) var savedValues: [String: String] = [:]
    let runningValues: [String: String]
    private(set) var displayed: [String: String] = [:]
    private(set) var diagnostics: [SettingsDiagnostic] = []
    var errors: [String] { diagnostics.map(\.displayMessage) }
    private(set) var status = ""
    private var inputIsValid = false
    private var validationTask: Task<Void, Never>?
    private(set) var validationPending = false
    var validationCompleted: (() -> Void)?
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
        runningValues = store.runningValues
        reload()
    }

    func reload(afterReset: Bool = false) {
        validationTask?.cancel()
        validationPending = false
        if afterReset { restartRequired = true }
        do {
            let loaded = try store.read()
            record = loaded
            input = loaded.current
            let evaluation = store.evaluate(input)
            effectiveValues = SettingsStore.values(evaluation.config)
            savedValues = effectiveValues
            refreshDisplayed()
            originalDisplayed = displayed
            diagnostics = evaluation.diagnostics
            inputIsValid = errors.isEmpty
            status = savedStatus
        } catch {
            record = nil
            inputIsValid = false
            diagnostics = [SettingsDiagnostic(kind: .storage, message: error.localizedDescription)]
            status = "Unable to read settings. Retry or restore defaults."
        }
    }

    func edit(_ field: SettingsField, value: String, deferred: Bool = false) {
        edit([field.key: value], deferred: deferred)
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

    private func edit(_ changes: [String: String], deferred: Bool = false) {
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
        validationTask?.cancel()
        if deferred {
            diagnostics = store.fieldDiagnostics(input)
            inputIsValid = false
            validationPending = true
            updateStatus()
            // Coalesce typing; saving and closing always flush the current draft.
            validationTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                guard !Task.isCancelled, let self else { return }
                self.flushValidation()
                self.validationCompleted?()
            }
        } else { flushValidation() }
    }

    func flushValidation() {
        validationTask?.cancel()
        validationTask = nil
        validationPending = false
        let evaluation = store.evaluate(input)
        diagnostics = evaluation.diagnostics
        // Keep the last coherent resolution while invalid raw edits stay visible.
        if diagnostics.isEmpty { effectiveValues = SettingsStore.values(evaluation.config) }
        refreshDisplayed()
        inputIsValid = diagnostics.isEmpty
        updateStatus()
    }

    private func refreshDisplayed() {
        displayed = effectiveValues.merging(input.values) { _, raw in raw }
    }

    private func updateStatus() {
        if !diagnostics.isEmpty {
            status = "Fix the invalid settings before saving."
        } else if validationPending {
            status = "Checking settings…"
        } else if dirty {
            status = "\(changedCount) modified \(changedCount == 1 ? "setting" : "settings"). Restart after saving to apply changes."
        } else { status = savedStatus }
    }

    func error(for key: String) -> String? {
        diagnostics.filter { $0.key == key }.map(\.message).joined(separator: "\n").nonEmpty
    }

    @discardableResult
    func save() -> Bool {
        validationTask?.cancel()
        validationPending = false
        guard let record else { return false }
        do {
            let saved = try store.saveEvaluated(input, revision: record.revision)
            self.record = saved.record
            effectiveValues = SettingsStore.values(saved.evaluation.config)
            savedValues = effectiveValues
            refreshDisplayed()
            diagnostics = []
            inputIsValid = true
            originalDisplayed = displayed
            restartRequired = true
            status = savedStatus
            return true
        } catch {
            diagnostics = [SettingsDiagnostic(kind: .storage, message: error.localizedDescription)]
            status = "Unable to save. Your edits are still available in this window."
            return false
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
