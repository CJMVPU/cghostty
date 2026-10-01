import AppKit

final class SettingsRow: NSStackView, NSTextFieldDelegate {
    private let field: SettingsField
    private let changed: (String) -> Void
    private let errorLabel = settingsLabel("")
    private var input: NSTextField?
    private var popup: NSPopUpButton?
    private var segments: NSSegmentedControl?
    private var fontPicker: SettingsFontPicker?
    private var valueEditor: SettingsValueEditor?

    init(field: SettingsField, value: String, usesFontPreset: Bool = false, context: [String: String] = [:],
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
        if !field.help.isEmpty {
            let help = SettingsButton("?") {}
            help.bezelStyle = .helpButton
            help.toolTip = field.help
            help.setAccessibilityLabel("Help for \(field.title)")
            help.handler = { [weak help] in
                guard let help else { return }
                let popover = NSPopover()
                popover.behavior = .transient
                let controller = NSViewController()
                let scroll = NSScrollView(frame: NSRect(x: 16, y: 16, width: 420, height: 180))
                scroll.hasVerticalScroller = false
                let text = SettingsTextView(frame: scroll.bounds)
                text.configurePlainText()
                text.font = SettingsTypography.font
                text.string = field.help
                text.isEditable = false
                text.isVerticallyResizable = true
                text.autoresizingMask = [.width]
                text.textContainer?.widthTracksTextView = true
                text.drawsBackground = false
                scroll.drawsBackground = false
                scroll.documentView = text
                controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 452, height: 212))
                controller.view.addSubview(scroll)
                popover.contentViewController = controller
                popover.show(relativeTo: help.bounds, of: help, preferredEdge: .maxY)
            }
            heading.addArrangedSubview(help)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        heading.addArrangedSubview(spacer)
        addArrangedSubview(heading)
        if field.isFontFamily {
            let picker = SettingsFontPicker(field: field, value: value, usesPreset: usesFontPreset,
                                            changed: changed, presetSelected: presetSelected)
            addArrangedSubview(picker)
            fontPicker = picker
        } else if let editor = Self.makeEditor(field, value: value, context: context, changed: changed) {
            valueEditor = editor
            if let control = editor.headingControl { heading.addArrangedSubview(control) }
            if field.presentation.inline {
                heading.addArrangedSubview(editor)
                editor.widthAnchor.constraint(lessThanOrEqualToConstant: 330).isActive = true
                editor.setContentCompressionResistancePriority(.required, for: .horizontal)
            } else {
                addArrangedSubview(editor)
            }
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
                heading.addArrangedSubview(popup)
                popup.widthAnchor.constraint(lessThanOrEqualToConstant: 280).isActive = true
                self.popup = popup
            }
        } else {
            let input = settingsInput(value, id: "settings.\(field.key)", delegate: self)
            input.placeholderString = field.defaultValue.isEmpty ? "Auto" : field.defaultValue
            if let width = field.presentation.width {
                input.widthAnchor.constraint(equalToConstant: width).isActive = true
                input.setContentCompressionResistancePriority(.required, for: .horizontal)
                heading.addArrangedSubview(input)
                if let unit = field.unitLabel { heading.addArrangedSubview(settingsLabel(unit, muted: true)) }
            } else {
                addArrangedSubview(input)
            }
            self.input = input
        }
        errorLabel.textColor = NSColor(calibratedRed: 1, green: 0.57, blue: 0.5, alpha: 1)
        errorLabel.isHidden = true
        addArrangedSubview(errorLabel)
        for view in arrangedSubviews { view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func choiceChanged() {
        changed(popup?.selectedItem?.representedObject as? String ?? "")
    }

    @objc private func segmentChanged() {
        guard let index = segments?.selectedSegment, field.choiceValues.indices.contains(index) else { return }
        changed(field.choiceValues[index])
    }

    func controlTextDidChange(_ obj: Notification) { changed(input?.stringValue ?? "") }

    func refresh(context: [String: String], preset: Bool) {
        let value = context[field.key] ?? field.defaultValue
        fontPicker?.refresh(value: value, preset: preset)
        valueEditor?.refresh(context: context)
        if input?.currentEditor() == nil { input?.stringValue = value }
        if let index = field.choiceValues.firstIndex(of: value.isEmpty ? field.defaultValue : value) {
            segments?.selectedSegment = index
            popup?.selectItem(at: index)
        }
    }

    private static func makeEditor(_ field: SettingsField, value: String, context: [String: String],
                                   changed: @escaping (String) -> Void) -> SettingsValueEditor? {
        switch field.presentation.editor {
        case .flags: return SettingsFlagsEditor(field: field, value: value, changed: changed)
        case .theme: return SettingsThemeEditor(value: value, changed: changed)
        case .fontStyle, .color, .path: return SettingsScalarEditor(field: field, value: value, context: context, changed: changed)
        case .duration, .limit, .quickSize, .blur: return SettingsMeasureEditor(field: field, value: value, changed: changed)
        case .list: return SettingsListEditor(field: field, value: value, changed: changed)
        case .scalar, .fontFamily: return nil
        }
    }

    func showError(_ error: String?, enabled: Bool) {
        errorLabel.stringValue = error ?? ""
        errorLabel.isHidden = error == nil
        input?.isEnabled = enabled
        valueEditor?.setEnabled(enabled)
        popup?.isEnabled = enabled
        segments?.isEnabled = enabled
        fontPicker?.setEnabled(enabled)
    }
}
