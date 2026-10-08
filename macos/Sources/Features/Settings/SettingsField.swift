import Foundation

nonisolated struct SettingsField: Decodable, Sendable {
    /// Bounds come from the core catalog. Compound syntax still receives final
    /// validation by the core parser; this provides immediate editor feedback.
    struct NumericConstraint: Decodable, Sendable {
        let minimum: Double?
        let maximum: Double?
        let exclusiveMinimum: Bool
        let allowZero: Bool
        let components: [String]

        func error(_ number: Double) -> String? {
            guard number.isFinite else { return "Enter a finite number. NaN and Infinity are not allowed." }
            if allowZero && number == 0 { return nil }
            if let minimum, number < minimum || (exclusiveMinimum && number == minimum) {
                if allowZero { return "Enter at least \(minimum.formatted()), or 0 for automatic sizing." }
                return "Enter a number \(exclusiveMinimum ? "greater than" : "at least") \(minimum.formatted())."
            }
            if let maximum, number > maximum { return "Enter a number no greater than \(maximum.formatted())." }
            return nil
        }

        func compoundError(_ value: String) -> String? {
            // Bare values apply to both components. Named values may repeat;
            // mirror the parser's last-value-wins behavior before checking.
            if !value.contains(":") {
                guard let number = Double(value) else { return nil }
                return error(number)
            }
            var values: [String: Double] = [:]
            for part in value.components(separatedBy: ",") {
                guard let colon = part.firstIndex(of: ":") else { return nil }
                let name = String(part[..<colon]).trimmingCharacters(in: .whitespaces)
                var raw = String(part[part.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if raw.hasPrefix("\"") && raw.hasSuffix("\"") && raw.count >= 2 { raw = String(raw.dropFirst().dropLast()) }
                guard components.contains(name), let number = Double(raw) else { return nil }
                values[name] = number
            }
            return components.compactMap { values[$0].flatMap(error) }.first
        }
    }

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
    let numericConstraint: NumericConstraint?

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
        return english
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
            return numericConstraint?.error(number)
        }
        if let numericConstraint, !numericConstraint.components.isEmpty { return numericConstraint.compoundError(value) }
        return nil
    }
}
