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
    enum Operation { case idle, loading, saving, resetting }
    enum Validation { case pending, valid, invalid }
    private enum Failure { case reading, saving }
    private(set) var operation: Operation = .idle
    private(set) var validation: Validation = .invalid
    private var failure: Failure?
    private var inputIsValid: Bool { validation == .valid }
    private var validationTask: Task<Void, Never>?
    var validationPending: Bool { validation == .pending }
    var stateChanged: (() -> Void)?
    private var originalDisplayed: [String: String] = [:]
    private let startupValues: [String: String]
    var restartRequired: Bool { savedValues != startupValues }
    var isBusy: Bool { operation != .idle }
    private var savedStatus: String { restartRequired ? "Saved. Restart to apply." : "No unsaved changes." }
    var dirty: Bool { record.map { $0.current != input } ?? false }
    var changedCount: Int {
        guard let original = record?.current else { return 0 }
        return Set(original.values.keys).union(input.values.keys).filter { original.values[$0] != input.values[$0] }.count
    }
    var canSave: Bool { !isBusy && dirty && inputIsValid && record != nil }

    init(store: SettingsStore, loadImmediately: Bool = true) {
        self.store = store
        runningValues = store.runningValues
        startupValues = store.startupValues
        if loadImmediately { reload() }
    }

    private func cancelValidation() {
        validationTask?.cancel()
        validationTask = nil
        if validation == .pending { validation = .invalid }
    }

    func reload() {
        guard !isBusy else { return }
        cancelValidation()
        do { apply(try store.read()) } catch { readFailed(error) }
    }

    @discardableResult
    func reloadAsync(reset: Bool = false) async -> Bool {
        guard !isBusy else { return false }
        operation = reset ? .resetting : .loading
        cancelValidation()
        failure = nil
        stateChanged?()
        defer { operation = .idle; stateChanged?() }
        do {
            if reset { _ = try await store.restoreDefaultsAsync() }
            let loaded = try await store.readAsync()
            apply(loaded)
            return true
        } catch {
            // A failed reset has not replaced the draft or the saved record.
            if reset, record != nil { saveFailed(error) } else { readFailed(error) }
            return false
        }
    }

    /// Discard against the latest persisted revision, which another instance
    /// may have changed since this window loaded its original record.
    func discardDraft() async -> Bool {
        await reloadAsync()
    }

    private func apply(_ loaded: SettingsStore.Record) {
        record = loaded
        input = loaded.current
        let evaluation = store.evaluate(input)
        effectiveValues = evaluation.values
        savedValues = effectiveValues
        refreshDisplayed()
        originalDisplayed = displayed
        diagnostics = evaluation.diagnostics
        validation = diagnostics.isEmpty ? .valid : .invalid
        failure = nil
    }

    private func readFailed(_ error: any Error) {
        record = nil
        validation = .invalid
        diagnostics = [SettingsDiagnostic(kind: .storage, message: error.localizedDescription)]
        failure = .reading
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
        guard !isBusy else { return }
        failure = nil
        let original = record?.current
        for (key, value) in changes {
            displayed[key] = value
            input.values[key] = value
        }
        // Restore saved inheritance only when it still resolves to the value
        // selected now. Another field may have changed its effective default.
        for (key, value) in changes {
            guard let original, value == originalDisplayed[key] else { continue }
            var inherited = input
            inherited.values[key] = original.values[key]
            let evaluation = store.evaluate(inherited)
            if evaluation.diagnostics.isEmpty, evaluation.values[key] == value {
                input = inherited
            }
        }
        validationTask?.cancel()
        if deferred {
            diagnostics = store.fieldDiagnostics(input)
            validation = .pending
            // Coalesce typing; saving and closing always flush the current draft.
            validationTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                guard !Task.isCancelled, let self else { return }
                self.flushValidation()
                self.stateChanged?()
            }
        } else { flushValidation() }
    }

    func flushValidation() {
        validationTask?.cancel()
        validationTask = nil
        if validation == .pending { validation = .invalid }
        let evaluation = store.evaluate(input)
        diagnostics = evaluation.diagnostics
        // Keep the last coherent resolution while invalid raw edits stay visible.
        if diagnostics.isEmpty { effectiveValues = evaluation.values }
        refreshDisplayed()
        validation = diagnostics.isEmpty ? .valid : .invalid
        failure = nil
    }

    private func refreshDisplayed() {
        displayed = effectiveValues.merging(input.values) { _, raw in raw }
    }

    var status: String {
        switch operation {
        case .loading: return "Loading settings…"
        case .saving: return "Saving…"
        case .resetting: return "Restoring defaults…"
        case .idle: break
        }
        switch failure {
        case .reading: return "Unable to read settings. Retry or restore defaults."
        case .saving: return "Unable to save. Your edits are still available."
        case nil: break
        }
        if !diagnostics.isEmpty { return "Fix the invalid settings before saving." }
        if validationPending { return "Checking settings…" }
        if dirty { return "\(changedCount) unsaved \(changedCount == 1 ? "change" : "changes")." }
        return savedStatus
    }

    func error(for key: String) -> String? {
        diagnostics.filter { $0.key == key }.map(\.message).joined(separator: "\n").nonEmpty
    }

    func saveAsync() async -> Bool {
        guard !isBusy, let record else { return false }
        cancelValidation()
        operation = .saving
        failure = nil
        stateChanged?()
        defer { operation = .idle; stateChanged?() }
        do {
            didSave(try await store.saveEvaluatedAsync(input, revision: record.revision))
            return true
        } catch { saveFailed(error); return false }
    }

    private func didSave(_ saved: SettingsStore.Saved) {
        record = saved.record
        effectiveValues = saved.evaluation.values
        savedValues = effectiveValues
        refreshDisplayed()
        diagnostics = []
        validation = .valid
        originalDisplayed = displayed
        failure = nil
    }

    private func saveFailed(_ error: any Error) {
        if case SettingsStore.Failure.invalid(let errors) = error {
            diagnostics = errors
            validation = .invalid
            failure = nil
        } else {
            diagnostics = [SettingsDiagnostic(kind: .storage, message: error.localizedDescription)]
            failure = .saving
            validation = store.evaluate(input).diagnostics.isEmpty ? .valid : .invalid
        }
    }

}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
