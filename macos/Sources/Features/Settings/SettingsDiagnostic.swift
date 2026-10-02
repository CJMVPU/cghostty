import Foundation

/// Field identity is separate from text so paths and user input remain exact.
nonisolated struct SettingsDiagnostic: Equatable, Hashable, Sendable {
    enum Kind: Hashable, Sendable { case field, core, catalog, storage }
    let key: String?
    let kind: Kind
    let message: String
    var source: String?
    var line: UInt = 0

    init(key: String? = nil, kind: Kind, message: String) {
        self.key = key
        self.kind = kind
        self.message = message
    }

    var rawMessage: String {
        let prefix = source.map { "\($0):\(line):" } ?? ""
        return prefix + (key.map { "\($0): " } ?? (source == nil ? "" : " ")) + message
    }
    @MainActor var displayMessage: String {
        key.map { "\(SettingsField.byKey[$0]?.title ?? $0): \(message)" } ?? message
    }
}
