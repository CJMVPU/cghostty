import Foundation

struct SettingsField: Decodable {
    let key: String
    let group: Int
    let title: String
    let note: String
    let kind: String
    let choices: [String]
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
    var help: String { note.components(separatedBy: " / ").first ?? note }

    func validate(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        if input.contains("\u{0}") || input.contains("\r") { return "不能包含空字符或回车字符。" }
        if input.components(separatedBy: "\n").contains(where: { $0.utf8.count + key.utf8.count + 3 > 4094 }) {
            return "单行内容过长，请缩短到 4094 字节以内（含设置名称）。"
        }
        if !multiline && input.contains("\n") { return "此设置只能填写一个值。" }
        if kind == "bool" || kind == "enum" {
            return choices.contains(value) ? nil : "请选择有效值：\(choices.joined(separator: "、"))。"
        }
        if kind == "integer" || kind == "number" {
            guard let number = Double(value), number.isFinite else { return "请输入有限数值，不能使用 NaN 或 Infinity。" }
            if kind == "integer" && Int64(value) == nil { return "请输入有效整数。" }
            switch key {
            case "font-size" where number <= 0: return "字号必须大于 0。"
            case "window-width" where number != 0 && number < 10: return "窗口宽度至少为 10 列；0 表示自动。"
            case "window-height" where number != 0 && number < 4: return "窗口高度至少为 4 行；0 表示自动。"
            case "background-opacity" where !(0...1).contains(number),
                 "cursor-opacity" where !(0...1).contains(number),
                 "faint-opacity" where !(0...1).contains(number):
                return "请输入 0 到 1 之间的数值。"
            case "unfocused-split-opacity" where !(0.15...1).contains(number): return "请输入 0.15 到 1 之间的数值。"
            case "font-thicken-strength" where !(0...255).contains(number): return "加厚强度范围为 0 到 255。"
            default: break
            }
        }
        return nil
    }
}
