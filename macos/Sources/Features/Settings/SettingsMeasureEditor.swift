import AppKit

/// Number and unit stay separate, without lossy conversions of existing values.
final class SettingsMeasureEditor: SettingsValueEditor, NSTextFieldDelegate {
    private let field: SettingsField
    private let changed: (String) -> Void
    private var numbers: [NSTextField] = []
    private var units: [NSControl] = []
    private var modes: [[String]] = []

    init(field: SettingsField, value: String, changed: @escaping (String) -> Void) {
        self.field = field
        self.changed = changed
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        if field.key == "quick-terminal-size" {
            let parts = value.components(separatedBy: ",")
            addMeasure(parts.first ?? "", choices: ["", "%", "px", "raw"], label: "Primary")
            addMeasure(parts.count > 1 ? parts[1] : "", choices: ["", "%", "px", "raw"], label: "Secondary")
        } else if field.isDuration {
            addMeasure(value, choices: ["", "ms", "s", "m", "h", "d", "w", "y", "us", "µs", "ns", "raw"])
        } else if field.isLimit {
            addMeasure(value, choices: ["", "unlimited", "number"], label: nil)
        } else {
            addMeasure(value, choices: ["false", "true", "macos-glass-regular", "macos-glass-clear", "number"])
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func split(_ value: String, choices: [String]) -> (String, String) {
        if choices.contains(value), value != "number", value != "raw" { return ("", value) }
        for suffix in choices.filter({ !["", "raw", "number"].contains($0) }).sorted(by: { $0.count > $1.count }) {
            guard value.hasSuffix(suffix) else { continue }
            let number = String(value.dropLast(suffix.count))
            if Double(number) != nil { return (number, suffix) }
        }
        if choices.contains("number") { return (value, "number") }
        if value == "0", choices.contains("ms") { return ("0", "ms") }
        return (value, "raw")
    }

    private func addMeasure(_ value: String, choices: [String], label: String? = nil) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        if let label { row.addArrangedSubview(settingsLabel(label, muted: true)) }
        let index = numbers.count
        let parsed = Self.split(value, choices: choices)
        let input = settingsInput(parsed.0, id: "settings.\(field.key).\(index).value", delegate: self)
        input.widthAnchor.constraint(equalToConstant: field.isLimit ? 100 : 110).isActive = true
        input.toolTip = field.isLimit ? (field.key.hasSuffix("lines") ? "Number of lines" : "Number of bytes") : nil
        let unit = NSPopUpButton()
        unit.font = SettingsTypography.font
        unit.menu?.font = SettingsTypography.font
        for choice in choices {
            let title: String
            switch choice {
            case "": title = "Auto"
            case "number": title = field.isLimit ? "Limited" : "Radius"
            case "raw": title = "Advanced"
            case "macos-glass-regular": title = "Glass Regular"
            case "macos-glass-clear": title = "Glass Clear"
            case "unlimited": title = "Unlimited"
            case "true", "false": title = SettingsField.choiceTitle(choice)
            default: title = choice
            }
            unit.addItem(withTitle: title)
            unit.lastItem?.representedObject = choice
        }
        unit.selectItem(at: choices.firstIndex(of: parsed.1) ?? 0)
        let selector: NSControl
        if choices.count <= 4 {
            let segments = NSSegmentedControl(labels: unit.itemTitles, trackingMode: .selectOne, target: self, action: #selector(unitChanged))
            segments.font = SettingsTypography.font
            segments.selectedSegment = unit.indexOfSelectedItem
            selector = segments
        } else {
            unit.target = self
            unit.action = #selector(unitChanged)
            selector = unit
        }
        selector.setAccessibilityIdentifier("settings.\(field.key).\(index).unit")
        row.addArrangedSubview(input)
        row.addArrangedSubview(selector)
        numbers.append(input)
        units.append(selector)
        modes.append(choices)
        controls += [input, selector]
        addArrangedSubview(row)
        refreshInputs()
    }

    override func refresh(context: [String: String]) {
        guard let value = context[field.key], numbers.allSatisfy({ $0.currentEditor() == nil }) else { return }
        let parts = numbers.count == 2 ? value.components(separatedBy: ",") : [value]
        for index in numbers.indices {
            let parsed = Self.split(parts.indices.contains(index) ? parts[index] : "", choices: modes[index])
            numbers[index].stringValue = parsed.0
            let selected = modes[index].firstIndex(of: parsed.1) ?? 0
            if let segments = units[index] as? NSSegmentedControl { segments.selectedSegment = selected }
            if let popup = units[index] as? NSPopUpButton { popup.selectItem(at: selected) }
        }
        refreshInputs()
    }

    private func selected(_ index: Int) -> String {
        if let segments = units[index] as? NSSegmentedControl {
            let selected = segments.selectedSegment
            return modes[index].indices.contains(selected) ? modes[index][selected] : ""
        }
        return (units[index] as? NSPopUpButton)?.selectedItem?.representedObject as? String ?? ""
    }
    private func takesNumber(_ mode: String) -> Bool {
        !["", "unlimited", "true", "false", "macos-glass-regular", "macos-glass-clear"].contains(mode)
    }
    private func refreshInputs() {
        for index in numbers.indices { numbers[index].isHidden = !takesNumber(selected(index)) }
    }
    private func publish() {
        let parts = numbers.indices.map { index -> String in
            let mode = selected(index)
            if !takesNumber(mode) { return mode }
            return numbers[index].stringValue + (["number", "raw"].contains(mode) ? "" : mode)
        }
        if parts.count == 2 {
            // A secondary dimension needs a primary one. Keep the incomplete
            // expression visible to validation instead of silently discarding it.
            changed(parts[1].isEmpty ? parts[0] : parts.joined(separator: ","))
        } else { changed(parts[0]) }
    }
    @objc private func unitChanged() { refreshInputs(); publish() }
    func controlTextDidChange(_ obj: Notification) { publish() }
}
