import Foundation

struct SettingsField: Decodable {
    let key: String
    let group: Int
    let title: String
    let note: String
    let kind: String
    let choices: [String]
    let flags: [String]
    let multiline: Bool
    let defaults: String
    let example: String

    @MainActor static let catalogResult = Result { try decodeCatalog(Ghostty.SettingsBridge.catalogData) }
    @MainActor static let catalog: [SettingsField] = (try? catalogResult.get()) ?? []
    @MainActor static let byKey = Dictionary(uniqueKeysWithValues: catalog.map { ($0.key, $0) })
    @MainActor static var catalogError: SettingsDiagnostic? {
        guard case .failure(let error) = catalogResult else { return nil }
        return SettingsDiagnostic(kind: .catalog, message: "Unable to load the settings catalog: \(error.localizedDescription)")
    }

    static func decodeCatalog(_ data: Data) throws -> [SettingsField] {
        let fields = try JSONDecoder().decode([SettingsField].self, from: data)
        guard !fields.isEmpty, Set(fields.map(\.key)).count == fields.count,
              fields.allSatisfy({ (1...8).contains($0.group) && !$0.key.isEmpty }) else {
            throw CocoaError(.coderReadCorrupt)
        }
        return fields
    }

    static func values(from entry: String) -> [String] {
        entry.components(separatedBy: "\n").compactMap { line in
            guard let equal = line.firstIndex(of: "=") else { return nil }
            return String(line[line.index(after: equal)...]).trimmingCharacters(in: .whitespaces)
        }
    }

    var defaultValue: String { Self.values(from: defaults).joined(separator: "\n") }
    var choiceValues: [String] { choices.isEmpty ? [] : (defaultValue.isEmpty ? [""] : []) + choices }

    static func choiceTitle(_ value: String) -> String {
        switch value {
        case "": return "Auto"
        case "true": return "On"
        case "false": return "Off"
        case "srgb": return "sRGB"
        case "macos": return "macOS"
        case "ssh-env": return "SSH Environment"
        case "ssh-terminfo": return "SSH Terminfo"
        case "block_hollow": return "Hollow Block"
        default: return value.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    @MainActor var help: String {
        if isFontFamily { return multiline ? "Choose fonts in order of preference. Type a name to find a font or keep a custom family." : "Type a name to find a font." }
        let english = note.components(separatedBy: " / ").last ?? note
        return Self.readable(english)
    }

    @MainActor static func readable(_ text: String) -> String {
        text.components(separatedBy: "\n").map { SettingsDiagnostic(coreMessage: $0).displayMessage }.joined(separator: "\n")
    }

    func validate(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        if input.contains("\u{0}") || input.contains("\r") { return "Null and carriage return characters are not allowed." }
        if input.components(separatedBy: "\n").contains(where: { $0.utf8.count + key.utf8.count + 3 > 4094 }) {
            return "Each line must fit within 4094 bytes, including the setting name."
        }
        if !multiline && input.contains("\n") { return "Enter a single value." }
        if kind == "bool" || kind == "enum" {
            return choices.contains(value) ? nil : "Choose a valid value: \(choices.map(Self.choiceTitle).joined(separator: ", "))."
        }
        if kind == "integer" || kind == "number" {
            guard let number = Double(value), number.isFinite else { return "Enter a finite number. NaN and Infinity are not allowed." }
            if kind == "integer" && Int64(value) == nil { return "Enter a valid whole number." }
            return presentation.numericRule?.error(number)
        }
        return nil
    }
}
