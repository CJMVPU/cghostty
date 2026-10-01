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

    @MainActor static let catalog: [SettingsField] = {
        (try? JSONDecoder().decode([SettingsField].self, from: Ghostty.SettingsBridge.catalogData)) ?? []
    }()

    static func values(from entry: String) -> [String] {
        entry.components(separatedBy: "\n").compactMap { line in
            guard let equal = line.firstIndex(of: "=") else { return nil }
            return String(line[line.index(after: equal)...]).trimmingCharacters(in: .whitespaces)
        }
    }

    var defaultValue: String { Self.values(from: defaults).joined(separator: "\n") }
    var isFontFamily: Bool { key == "window-title-font-family" || key == "font-family" || key.hasPrefix("font-family-") }
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
        // Longest keys first so a shorter name cannot replace part of another.
        catalog.sorted { $0.key.count > $1.key.count }.reduce(text) { result, field in
            guard field.key.contains("-") else { return result }
            return result.replacingOccurrences(of: field.key, with: field.title)
        }
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
            switch key {
            case "font-size" where number <= 0: return "Font size must be greater than 0."
            case "window-width" where number != 0 && number < 10: return "Window width must be at least 10 columns. Use 0 for automatic sizing."
            case "window-height" where number != 0 && number < 4: return "Window height must be at least 4 rows. Use 0 for automatic sizing."
            case "background-opacity" where !(0...1).contains(number),
                 "cursor-opacity" where !(0...1).contains(number),
                 "faint-opacity" where !(0...1).contains(number):
                return "Enter a number from 0 to 1."
            case "unfocused-split-opacity" where !(0.15...1).contains(number): return "Enter a number from 0.15 to 1."
            case "font-thicken-strength" where !(0...255).contains(number): return "Thickening strength must be from 0 to 255."
            default: break
            }
        }
        return nil
    }
}
