import AppKit

final class SettingsScalarEditor: SettingsValueEditor, NSTextFieldDelegate, NSComboBoxDelegate {
    private let field: SettingsField
    private let changed: (String) -> Void
    private let combo = SettingsComboBox()
    private var choices: [(String, String)] = []
    private var colorWell: NSColorWell?
    private var pathInput: NSTextField?
    private var family = ""
    private var raw = ""

    init(field: SettingsField, value: String, context: [String: String], changed: @escaping (String) -> Void) {
        self.field = field
        self.changed = changed
        raw = value
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 8
        combo.font = SettingsTypography.font
        combo.isEditable = true
        combo.completes = true
        combo.delegate = self
        combo.target = self
        combo.action = #selector(committed)
        combo.heightAnchor.constraint(equalToConstant: 32).isActive = true
        combo.setAccessibilityIdentifier("settings.\(field.key)")
        combo.setAccessibilityLabel(field.title)
        if field.isPath {
            let input = settingsInput(value, id: "settings.\(field.key)", delegate: self)
            input.placeholderString = "Auto"
            input.setAccessibilityLabel(field.title)
            pathInput = input
            addArrangedSubview(input)
            controls.append(input)
        } else {
            combo.widthAnchor.constraint(equalToConstant: 210).isActive = true
            addArrangedSubview(combo)
            controls.append(combo)
        }
        if field.isFontStyle {
            refresh(context: context)
        } else if field.isColor {
            choices = field.colorModes.map { ($0, $0.isEmpty ? "Auto" : SettingsField.choiceTitle($0)) }
            let well = NSColorWell()
            well.target = self
            well.action = #selector(colorChanged)
            well.supportsAlpha = false
            well.widthAnchor.constraint(equalToConstant: 42).isActive = true
            well.heightAnchor.constraint(equalToConstant: 32).isActive = true
            well.setAccessibilityLabel("Choose \(field.title.lowercased())")
            addArrangedSubview(well)
            controls.append(well)
            colorWell = well
        } else if field.isPath {
            let browse = SettingsButton("Browse…") { [weak self] in self?.browse() }
            addArrangedSubview(browse)
            controls.append(browse)
        }
        populate()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func refresh(context: [String: String]) {
        if combo.currentEditor() == nil, pathInput?.currentEditor() == nil,
           let value = context[field.key], raw != value {
            raw = value
            pathInput?.stringValue = value
            populate()
        }
        guard field.isFontStyle else { return }
        let familyKey = field.key.replacingOccurrences(of: "font-style", with: "font-family")
        let selected = context[familyKey]?.components(separatedBy: "\n").first ?? ""
        let next = selected.isEmpty ? (context["font-family"]?.components(separatedBy: "\n").first ?? SettingsFontPicker.bundledFamily) : selected
        guard family != next || choices.isEmpty else { return }
        family = next
        let styles = (NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []).compactMap { $0.count > 1 ? $0[1] as? String : nil }
        let available = family == SettingsFontPicker.bundledFamily ? styles + ["Medium"] : styles
        choices = [("default", "Auto"), ("false", "Disabled")] + Set(available).sorted().map { ($0, $0) }
        populate()
    }

    private func populate() {
        combo.removeAllItems()
        combo.addItems(withObjectValues: choices.map(\.1))
        combo.stringValue = choices.first { $0.0 == raw }?.1 ?? raw
        updateSwatch()
    }

    private func update() {
        let text = pathInput?.stringValue ?? combo.stringValue
        raw = choices.first { $0.1 == text }?.0 ?? text
        updateSwatch()
        changed(raw)
    }

    private func updateSwatch() {
        guard let well = colorWell else { return }
        var color = Self.color(raw)
        if color == nil, !field.colorModes.contains(raw), !raw.contains("\n"), !raw.contains("\r") {
            let config = Ghostty.ConfigHandle.load(data: Data("background = \(raw)".utf8), source: URL(fileURLWithPath: "/settings-color-preview"))
            if config?.errors.isEmpty == true, let entry = config?.formattedEntry("background") {
                color = Self.color(SettingsField.values(from: entry).first ?? "")
            }
        }
        well.color = color ?? .clear
        well.toolTip = color == nil ? "Choose an explicit color" : raw
    }

    static func color(_ text: String) -> NSColor? {
        let hex = text.hasPrefix("#") ? String(text.dropFirst()) : text
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                       green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }

    @objc private func colorChanged() {
        guard let color = colorWell?.color.usingColorSpace(.sRGB) else { return }
        raw = String(format: "#%02x%02x%02x", Int((color.redComponent * 255).rounded()),
                     Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
        combo.stringValue = raw
        changed(raw)
    }

    private func browse() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = field.isDirectory
        panel.canChooseFiles = !field.isDirectory
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            self.raw = url.path
            self.pathInput?.stringValue = url.path
            self.changed(url.path)
        }
    }

    @objc private func committed() { update() }
    func controlTextDidChange(_ obj: Notification) { update() }
    func comboBoxSelectionDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.update() }
    }
}

final class SettingsFlagsEditor: SettingsValueEditor {
    private let field: SettingsField
    private let changed: (String) -> Void
    private var toggles: [SettingsButton] = []

    init(field: SettingsField, value: String, changed: @escaping (String) -> Void) {
        self.field = field
        self.changed = changed
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        let enabled = Self.enabledFlags(value, defaults: field.defaultValue, names: field.flags)
        for name in field.flags {
            let button = SettingsButton(SettingsField.choiceTitle(name)) { [weak self] in self?.publish() }
            button.setButtonType(.switch)
            button.state = enabled.contains(name) ? .on : .off
            button.setAccessibilityIdentifier("settings.\(field.key).\(name)")
            toggles.append(button)
            controls.append(button)
            addArrangedSubview(button)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func enabledFlags(_ text: String, defaults: String, names: [String]) -> Set<String> {
        var result = Set<String>()
        for source in [defaults, text] {
            for token in source.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                if token == "true" { result = Set(names) } else if token == "false" { result = [] } else if token.hasPrefix("no-") { result.remove(String(token.dropFirst(3))) } else if names.contains(token) { result.insert(token) }
            }
        }
        return result
    }

    override func refresh(context: [String: String]) {
        guard let value = context[field.key] else { return }
        let enabled = Self.enabledFlags(value, defaults: field.defaultValue, names: field.flags)
        for (name, button) in zip(field.flags, toggles) { button.state = enabled.contains(name) ? .on : .off }
    }

    private func publish() {
        changed(zip(field.flags, toggles).map { name, button in button.state == .on ? name : "no-\(name)" }.joined(separator: ","))
    }
}
