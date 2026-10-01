import AppKit

/// A native searchable font dropdown for each family, preserving fallback order.
final class SettingsFontPicker: NSStackView, NSComboBoxDelegate {
    static let bundledFamily = "LXGW WenKai Mono"
    static let presetTitle = "default:LXGW WenKai Mono:medium:thickened"
    private static let installed = Set(NSFontManager.shared.availableFontFamilies + [bundledFamily])
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

    private let field: SettingsField
    private let changed: (String) -> Void
    private let presetSelected: (String) -> Void
    private var families: [String]
    private var usesPreset: Bool
    private var controls: [NSControl] = []
    private var combos: [NSComboBox] = []
    private var addButton: SettingsButton?

    init(field: SettingsField, value: String, usesPreset: Bool,
         changed: @escaping (String) -> Void, presetSelected: @escaping (String) -> Void) {
        self.field = field
        self.changed = changed
        self.presetSelected = presetSelected
        families = value.isEmpty ? [""] : value.components(separatedBy: "\n")
        self.usesPreset = usesPreset
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        render()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var automaticTitle: String {
        switch field.key {
        case "font-family": return Self.presetTitle
        case "window-title-font-family": return "System Font"
        default: return "Inherit Regular Font"
        }
    }

    private func render() {
        arrangedSubviews.forEach { removeArrangedSubview($0); $0.removeFromSuperview() }
        combos = []
        controls = []
        for (index, family) in families.enumerated() {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            let combo = SettingsFontComboBox()
            combo.font = SettingsTypography.font
            combo.isEditable = true
            combo.isSelectable = true
            combo.completes = true
            combo.numberOfVisibleItems = 12
            combo.addItems(withObjectValues: index == 0 ? [automaticTitle] + Self.installed : Self.installed)
            if !family.isEmpty && !Self.installed.contains(family) { combo.addItem(withObjectValue: family) }
            if index == 0 && field.key == "font-family" {
                combo.stringValue = usesPreset ? Self.presetTitle : (family.isEmpty ? Self.bundledFamily : family)
            } else {
                combo.stringValue = index == 0 && family.isEmpty ? automaticTitle : family
            }
            combo.placeholderString = "Choose a font"
            combo.toolTip = combo.stringValue
            combo.delegate = self
            combo.target = self
            combo.action = #selector(fontCommitted)
            combo.setAccessibilityIdentifier("settings.\(field.key).\(index)")
            combo.setAccessibilityLabel(index == 0 ? field.title : "Fallback font \(index)")
            combo.heightAnchor.constraint(equalToConstant: 32).isActive = true
            row.addArrangedSubview(combo)
            combos.append(combo)
            controls.append(combo)
            if index > 0 {
                let remove = SettingsButton("Remove") { [weak self] in
                    guard let self else { return }
                    self.families.remove(at: index)
                    self.changed(self.serialized)
                    self.render()
                }
                remove.setAccessibilityLabel("Remove fallback font \(index)")
                row.addArrangedSubview(remove)
                controls.append(remove)
            }
            addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        if field.multiline {
            let add = SettingsButton("Add Fallback") { [weak self] in
                guard let self else { return }
                self.families.append("")
                self.render()
                if let last = self.combos.last { self.window?.makeFirstResponder(last) }
            }
            addArrangedSubview(add)
            controls.append(add)
            addButton = add
            add.isEnabled = canAddFallback
            add.toolTip = "Choose a primary font before adding fallbacks."
        }
    }

    private var serialized: String {
        var values = families
        if values.count > 1 && values[0].isEmpty && field.key == "font-family" { values[0] = Self.bundledFamily }
        return values.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private func update(_ combo: NSComboBox, value: String) {
        guard let index = combos.firstIndex(of: combo) else { return }
        if index == 0 && value == automaticTitle {
            if field.key == "font-family" {
                families[0] = Self.bundledFamily
                usesPreset = true
                presetSelected(serialized)
                return
            }
            // Inheritance applies to the entire style-specific family list.
            families = [""]
            DispatchQueue.main.async { [weak self] in self?.render() }
        } else {
            families[index] = value
            if index == 0 { usesPreset = false }
        }
        changed(serialized)
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard let combo = notification.object as? NSComboBox else { return }
        // AppKit updates the editable text after the selection notification.
        DispatchQueue.main.async { [weak self, weak combo] in
            guard let combo else { return }
            self?.update(combo, value: combo.stringValue)
        }
    }

    @objc private func fontCommitted(_ combo: NSComboBox) { update(combo, value: combo.stringValue) }

    func comboBoxWillPopUp(_ notification: Notification) {
        guard let combo = notification.object as? NSComboBox, combo === combos.first else { return }
        DispatchQueue.main.async { [weak combo] in combo?.scrollItemAtIndexToTop(0) }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let combo = notification.object as? NSComboBox else { return }
        update(combo, value: combo.stringValue)
    }

    private var canAddFallback: Bool { field.key == "font-family" || !families[0].isEmpty }

    func setEnabled(_ enabled: Bool) {
        controls.forEach { $0.isEnabled = enabled }
        addButton?.isEnabled = enabled && canAddFallback
    }

    func refresh(value: String, preset: Bool) {
        if value != serialized, combos.allSatisfy({ $0.currentEditor() == nil }) {
            families = value.isEmpty ? [""] : value.components(separatedBy: "\n")
            usesPreset = preset
            render()
        }
        refreshPreset(preset)
    }

    func refreshPreset(_ active: Bool) {
        guard field.key == "font-family", active != usesPreset, let primary = combos.first else { return }
        usesPreset = active
        // Keep an in-progress search intact. Invalidate a stale preset caption
        // immediately when its style or thickening settings change elsewhere.
        guard primary.currentEditor() == nil || primary.stringValue == Self.presetTitle else { return }
        primary.stringValue = active ? Self.presetTitle : (families[0].isEmpty ? Self.bundledFamily : families[0])
    }
}

private final class SettingsFontComboBox: NSComboBox {
    override func draw(_ dirtyRect: NSRect) {
        SettingsTypography.draw { super.draw(dirtyRect) }
    }
}
