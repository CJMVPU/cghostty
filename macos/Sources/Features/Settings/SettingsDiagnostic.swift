import Foundation

/// Field identity is separate from text so paths and user input remain exact.
struct SettingsDiagnostic: Equatable, Hashable {
    enum Kind: Hashable { case field, core, catalog, storage }
    let key: String?
    let kind: Kind
    let message: String

    init(key: String? = nil, kind: Kind, message: String) {
        self.key = key
        self.kind = kind
        self.message = message
    }

    @MainActor init(coreMessage: String) {
        // Older core diagnostics expose only text. Recognize an exact leading
        // key, never a key appearing in another field, path or supplied value.
        if let colon = coreMessage.firstIndex(of: ":"),
           SettingsField.byKey[String(coreMessage[..<colon])] != nil {
            key = String(coreMessage[..<colon])
            message = String(coreMessage[coreMessage.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        } else {
            key = nil
            message = coreMessage
        }
        kind = .core
    }

    var rawMessage: String { key.map { "\($0): \(message)" } ?? message }
    @MainActor var displayMessage: String {
        key.map { "\(SettingsField.byKey[$0]?.title ?? $0): \(message)" } ?? message
    }
}
