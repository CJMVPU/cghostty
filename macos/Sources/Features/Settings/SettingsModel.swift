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
    private var draftRevision = UUID()
    private var inheritanceKeys: Set<String> = []
    private var inheritance: SettingsEvaluator.Inheritance? {
        record.map { .init(original: $0.current, displayed: originalDisplayed, keys: inheritanceKeys) }
    }
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
        draftRevision = UUID()
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
            let evaluation = try await store.evaluateAsync(loaded.current)
            apply(loaded, evaluation: evaluation)
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
        let evaluation = store.evaluate(loaded.current)
        apply(loaded, evaluation: .init(values: evaluation.values, darkValues: evaluation.darkValues, diagnostics: evaluation.diagnostics))
    }

    private func apply(_ loaded: SettingsStore.Record, evaluation: SettingsEvaluator.Projection) {
        inheritanceKeys.removeAll()
        record = loaded
        input = loaded.current
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

    func applyBundledFontPreset(families: String, deferred: Bool = false) {
        // The bundled family's automatic face is Medium. Leave style discovery
        // automatic so later choices and fallback families use their own face.
        edit(["font-family": families, "font-style": "default", "font-thicken": "true", "font-thicken-strength": "255"], deferred: deferred)
    }

    private func edit(_ changes: [String: String], deferred: Bool = false) {
        guard !isBusy else { return }
        failure = nil
        cancelValidation()
        for (key, value) in changes {
            displayed[key] = value
            input.values[key] = value
            if value == originalDisplayed[key] { inheritanceKeys.insert(key) } else { inheritanceKeys.remove(key) }
        }
        if deferred {
            diagnostics = store.fieldDiagnostics(input)
            validation = .pending
            let revision = draftRevision
            // Coalesce typing. Each worker receives an immutable draft snapshot.
            validationTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                guard !Task.isCancelled, let self else { return }
                if await self.validateDraft(revision: revision) { self.stateChanged?() }
            }
        } else { flushValidation() }
    }

    /// Returns false when cancelled or superseded, so close requests cannot use
    /// a result that belongs to an older draft.
    @discardableResult
    func flushValidationAsync() async -> Bool {
        guard !isBusy else { return false }
        cancelValidation()
        validation = .pending
        let applied = await validateDraft(revision: draftRevision)
        if applied { stateChanged?() }
        return applied
    }

    private func validateDraft(revision: UUID) async -> Bool {
        do {
            let draft = try await store.evaluateDraftAsync(input, restoring: inheritance)
            guard !Task.isCancelled, revision == draftRevision else { return false }
            input = draft.input
            inheritanceKeys.removeAll()
            diagnostics = draft.evaluation.diagnostics
            if diagnostics.isEmpty { effectiveValues = draft.evaluation.values }
            refreshDisplayed()
            validation = diagnostics.isEmpty ? .valid : .invalid
            failure = nil
            return true
        } catch {
            guard revision == draftRevision else { return false }
            validation = .invalid
            if !(error is CancellationError) {
                diagnostics = [SettingsDiagnostic(kind: .core, message: error.localizedDescription)]
            }
            return false
        }
    }

    func flushValidation() {
        cancelValidation()
        if let original = record?.current {
            for key in inheritanceKeys.sorted() {
                var candidate = input
                candidate.values[key] = original.values[key]
                let evaluation = store.evaluate(candidate)
                if evaluation.diagnostics.isEmpty, evaluation.values[key] == input.values[key] { input = candidate }
            }
        }
        inheritanceKeys.removeAll()
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
            let saved = try await store.prepareSaveAsync(input, revision: record.revision, restoring: inheritance)
            validation = .valid
            try await store.commitPreparedAsync(saved)
            didSave(saved)
            return true
        } catch {
            // Storage failures preserve draft validity without parsing on MainActor.
            if !(error is CancellationError), case .invalid = validation,
               let evaluation = try? await store.evaluateAsync(input) {
                validation = evaluation.diagnostics.isEmpty ? .valid : .invalid
            }
            saveFailed(error)
            return false
        }
    }

    private func didSave(_ saved: SettingsStore.Saved) {
        record = saved.record
        input = saved.record.current
        inheritanceKeys.removeAll()
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
        }
    }

}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
