import AppKit

final class SettingsRow: NSStackView, NSTextFieldDelegate, NSTextViewDelegate {
    private let field: SettingsField
    private let changed: (String) -> Void
    private let errorLabel = settingsLabel("")
    private var input: NSTextField?
    private var editor: SettingsTextView?
    private var popup: NSPopUpButton?
    private var segments: NSSegmentedControl?
    private var fontPicker: SettingsFontPicker?

    init(field: SettingsField, value: String, usesFontPreset: Bool = false,
         presetSelected: @escaping (String) -> Void, changed: @escaping (String) -> Void) {
        self.field = field
        self.changed = changed
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        let heading = NSStackView()
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 16
        heading.addArrangedSubview(settingsLabel(field.title))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        heading.addArrangedSubview(spacer)
        addArrangedSubview(heading)
        if field.isFontFamily {
            let picker = SettingsFontPicker(field: field, value: value, usesPreset: usesFontPreset,
                                            changed: changed, presetSelected: presetSelected)
            addArrangedSubview(picker)
            fontPicker = picker
        } else if !field.choices.isEmpty {
            let values = field.choiceValues
            let effective = value.isEmpty ? field.defaultValue : value
            if values.count <= 4 {
                let segments = NSSegmentedControl(labels: values.map(SettingsField.choiceTitle), trackingMode: .selectOne,
                                                  target: self, action: #selector(segmentChanged))
                segments.font = SettingsTypography.font
                segments.selectedSegment = values.firstIndex(of: effective) ?? -1
                segments.setContentCompressionResistancePriority(.required, for: .horizontal)
                segments.setContentHuggingPriority(.required, for: .horizontal)
                segments.setAccessibilityIdentifier("settings.\(field.key)")
                heading.addArrangedSubview(segments)
                self.segments = segments
            } else {
                let popup = NSPopUpButton(frame: .zero, pullsDown: false)
                popup.font = SettingsTypography.font
                popup.menu?.font = SettingsTypography.font
                for choice in values {
                    popup.addItem(withTitle: SettingsField.choiceTitle(choice))
                    popup.lastItem?.representedObject = choice
                }
                if !values.contains(effective) {
                    popup.addItem(withTitle: effective)
                    popup.lastItem?.representedObject = effective
                }
                popup.selectItem(at: values.firstIndex(of: effective) ?? popup.numberOfItems - 1)
                popup.target = self
                popup.action = #selector(choiceChanged)
                popup.setAccessibilityIdentifier("settings.\(field.key)")
                addArrangedSubview(popup)
                self.popup = popup
            }
        } else if field.multiline {
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            let editor = SettingsTextView(frame: NSRect(x: 0, y: 0, width: 450, height: 100))
            editor.font = SettingsTypography.font
            editor.textColor = .white
            editor.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 1)
            editor.configurePlainText()
            editor.string = value
            editor.delegate = self
            editor.isVerticallyResizable = true
            editor.isHorizontallyResizable = false
            editor.autoresizingMask = [.width]
            editor.textContainer?.widthTracksTextView = true
            editor.textContainerInset = NSSize(width: 8, height: 8)
            editor.setAccessibilityIdentifier("settings.\(field.key)")
            scroll.documentView = editor
            scroll.heightAnchor.constraint(equalToConstant: field.key == "keybind" ? 220 : 96).isActive = true
            addArrangedSubview(scroll)
            self.editor = editor
            addArrangedSubview(settingsLabel("One value per line, applied in order.", muted: true))
        } else {
            let input = NSTextField()
            input.cell = SettingsTextCell(textCell: "")
            input.font = SettingsTypography.font
            input.isEditable = true
            input.isSelectable = true
            input.isBezeled = true
            input.drawsBackground = true
            input.textColor = .white
            input.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 1)
            input.stringValue = value
            input.placeholderString = field.defaultValue.isEmpty ? "Auto" : field.defaultValue
            input.delegate = self
            input.setAccessibilityIdentifier("settings.\(field.key)")
            input.heightAnchor.constraint(equalToConstant: 32).isActive = true
            if let width = compactInputWidth {
                input.widthAnchor.constraint(equalToConstant: width).isActive = true
                input.setContentCompressionResistancePriority(.required, for: .horizontal)
                heading.addArrangedSubview(input)
            } else {
                addArrangedSubview(input)
            }
            self.input = input
        }
        if !field.help.isEmpty { addArrangedSubview(settingsLabel(field.help, muted: true)) }
        errorLabel.textColor = NSColor(calibratedRed: 1, green: 0.57, blue: 0.5, alpha: 1)
        errorLabel.isHidden = true
        addArrangedSubview(errorLabel)
        for view in arrangedSubviews { view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Short scalar values leave enough room for the name, including at the
    /// minimum window width. Paths, commands and other long text keep a full row.
    private var compactInputWidth: CGFloat? {
        if field.kind == "integer" || field.kind == "number" { return 160 }
        if field.key.hasPrefix("adjust-") { return 160 }
        switch field.key {
        case "window-padding-x", "window-padding-y", "undo-timeout": return 160
        case "background", "foreground", "cursor-color", "cursor-text",
             "selection-foreground", "selection-background", "search-foreground", "search-background",
             "search-selected-foreground", "search-selected-background", "split-divider-color", "bold-color":
            return 220
        default: return nil
        }
    }

    @objc private func choiceChanged() {
        changed(popup?.selectedItem?.representedObject as? String ?? "")
    }

    @objc private func segmentChanged() {
        guard let index = segments?.selectedSegment, field.choiceValues.indices.contains(index) else { return }
        changed(field.choiceValues[index])
    }

    func controlTextDidChange(_ obj: Notification) { changed(input?.stringValue ?? "") }
    func textDidChange(_ notification: Notification) { changed(editor?.string ?? "") }

    func refreshFontPreset(_ active: Bool) { fontPicker?.refreshPreset(active) }

    func showError(_ error: String?, enabled: Bool) {
        errorLabel.stringValue = SettingsField.readable(error ?? "")
        errorLabel.isHidden = error == nil
        input?.isEnabled = enabled
        editor?.isEditable = enabled
        popup?.isEnabled = enabled
        segments?.isEnabled = enabled
        fontPicker?.setEnabled(enabled)
    }
}
