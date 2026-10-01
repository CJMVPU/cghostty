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
            status = "设置保存在应用内；保存后重启生效。"
        } catch {
            record = nil
            inputIsValid = false
            errors = [error.localizedDescription]
            status = "读取失败，可重试或恢复默认设置。"
        }
    }

    func edit(_ field: SettingsField, value: String) {
        displayed[field.key] = value
        input.values[field.key] = value
        // Returning a field to its original value should also remove its dirty
        // state, instead of introducing an unnecessary explicit override.
        if let original = record?.current, let parsed = store.parse(original) {
            let initial = original.values[field.key] ?? SettingsField.values(from: parsed.formattedEntry(field.key)).joined(separator: "\n")
            if value == initial { input.values[field.key] = original.values[field.key] }
        }
        errors = store.validate(input)
        inputIsValid = errors.isEmpty
        status = errors.isEmpty ? "有未保存的修改；保存后重启生效。" : "请先修正无效设置。"
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
            status = "已保存。重启应用后生效。"
            return true
        } catch {
            errors = [error.localizedDescription]
            status = "保存失败；修改内容仍保留在窗口中。"
            return false
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
