import AppKit

final class SettingsRow: NSStackView, NSTextFieldDelegate, NSTextViewDelegate {
    private let field: SettingsField
    private let changed: (String) -> Void
    private let errorLabel = settingsLabel("")
    private var input: NSTextField?
    private var editor: SettingsTextView?
    private var popup: NSPopUpButton?
    private var resetButton: SettingsButton!

    init(field: SettingsField, value: String, changed: @escaping (String) -> Void) {
        self.field = field
        self.changed = changed
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        let heading = NSStackView()
        heading.orientation = .horizontal
        heading.addArrangedSubview(settingsLabel(field.title))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        heading.addArrangedSubview(spacer)
        resetButton = SettingsButton("默认") { [weak self] in self?.setValue("") }
        heading.addArrangedSubview(resetButton)
        addArrangedSubview(heading)
        addArrangedSubview(settingsLabel(field.key, muted: true))
        if !field.choices.isEmpty {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.font = SettingsTypography.font
            popup.menu?.font = SettingsTypography.font
            popup.addItem(withTitle: "默认 / 自动")
            for choice in field.choices {
                popup.addItem(withTitle: field.kind == "bool" ? (choice == "true" ? "开启" : "关闭") : choice)
                popup.lastItem?.representedObject = choice
            }
            if !value.isEmpty && !field.choices.contains(value) { popup.addItem(withTitle: value) }
            popup.selectItem(at: value.isEmpty ? 0 : (field.choices.firstIndex(of: value).map { $0 + 1 } ?? popup.numberOfItems - 1))
            popup.target = self
            popup.action = #selector(choiceChanged)
            popup.setAccessibilityIdentifier("settings.\(field.key)")
            addArrangedSubview(popup)
            self.popup = popup
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
            addArrangedSubview(settingsLabel("每行一个值，按顺序应用。", muted: true))
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
            input.placeholderString = field.defaultValue.isEmpty ? "自动 / 未设置" : field.defaultValue
            input.delegate = self
            input.setAccessibilityIdentifier("settings.\(field.key)")
            input.heightAnchor.constraint(equalToConstant: 32).isActive = true
            addArrangedSubview(input)
            self.input = input
        }
        if !field.help.isEmpty { addArrangedSubview(settingsLabel(field.help, muted: true)) }
        let defaultText = field.defaultValue.isEmpty ? "自动 / 未设置" : field.defaultValue.components(separatedBy: "\n").prefix(2).joined(separator: " · ")
        let summary = settingsLabel("默认：\(defaultText)", muted: true)
        summary.maximumNumberOfLines = 2
        addArrangedSubview(summary)
        errorLabel.textColor = NSColor(calibratedRed: 1, green: 0.57, blue: 0.5, alpha: 1)
        errorLabel.isHidden = true
        addArrangedSubview(errorLabel)
        for view in arrangedSubviews { view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func setValue(_ value: String) {
        input?.stringValue = value
        editor?.string = value
        popup?.selectItem(at: value.isEmpty ? 0 : (popup?.indexOfItem(withTitle: value) ?? 0))
        changed(value)
    }

    @objc private func choiceChanged() {
        guard let popup else { return }
        changed(popup.indexOfSelectedItem == 0 ? "" : popup.selectedItem?.representedObject as? String ?? popup.titleOfSelectedItem ?? "")
    }

    func controlTextDidChange(_ obj: Notification) { changed(input?.stringValue ?? "") }
    func textDidChange(_ notification: Notification) { changed(editor?.string ?? "") }

    func showError(_ error: String?, enabled: Bool) {
        errorLabel.stringValue = error ?? ""
        errorLabel.isHidden = error == nil
        input?.isEnabled = enabled
        editor?.isEditable = enabled
        popup?.isEnabled = enabled
        resetButton.isEnabled = enabled
    }
}
