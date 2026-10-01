import AppKit

/// Ordered rows preserve duplicates, empty values and '=' inside values. The
/// advanced view retains sequences and expressions that have no simple editor.
final class SettingsListEditor: SettingsValueEditor, NSTextFieldDelegate, NSTextViewDelegate {
    private let field: SettingsField
    private let changed: (String) -> Void
    private var entries: [String]
    private let content = NSStackView()
    private let advanced = SettingsButton("Advanced") {}
    private var rawEditor: SettingsTextView?
    private var inputs: [(NSTextField, NSTextField?)] = []
    private var isAdvanced = false
    private var visibleCount = 12
    private var placeholders: Set<Int> = []
    private let recordingHint = settingsLabel("", muted: true)
    private var serialized: String { entries.enumerated().filter { !placeholders.contains($0.offset) }.map(\.element).joined(separator: "\n") }

    init(field: SettingsField, value: String, changed: @escaping (String) -> Void) {
        self.field = field
        self.changed = changed
        entries = value.isEmpty ? [] : value.components(separatedBy: "\n")
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        advanced.handler = { [weak self] in
            guard let self else { return }
            if !self.isAdvanced {
                let value = self.serialized
                self.entries = value.isEmpty ? [] : value.components(separatedBy: "\n")
                self.placeholders = []
            }
            self.isAdvanced.toggle()
            self.render()
        }
        advanced.setAccessibilityIdentifier("settings.\(field.key).advanced")
        addArrangedSubview(advanced)
        recordingHint.isHidden = true
        addArrangedSubview(recordingHint)
        recordingHint.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        addArrangedSubview(content)
        content.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        render()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func split(_ entry: String, binding: Bool = false) -> (String, String?) {
        // Match Binding.Parser: '=' may itself be the trigger key, including
        // '=+ctrl'. Only the separator after the complete trigger splits rows.
        let separator = entry.indices.first { index in
            guard entry[index] == "=" else { return false }
            let next = entry.index(after: index)
            return !binding || next == entry.endIndex || !["+", "="].contains(entry[next])
        }
        guard let separator else { return (entry, nil) }
        return (String(entry[..<separator]), String(entry[entry.index(after: separator)...]))
    }

    private func render() {
        content.arrangedSubviews.forEach { content.removeArrangedSubview($0); $0.removeFromSuperview() }
        controls = [advanced]
        inputs = []
        rawEditor = nil
        advanced.title = isAdvanced ? "Use Rows" : "Advanced"
        if isAdvanced { renderRaw(); return }
        if entries.isEmpty { content.addArrangedSubview(settingsLabel("No entries", muted: true)) }
        for (index, entry) in entries.prefix(visibleCount).enumerated() {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            let parts = field.isPairList ? Self.split(entry, binding: field.key == "keybind") : (entry, nil)
            let left = settingsInput(parts.0, id: "settings.\(field.key).\(index).key", delegate: self)
            left.placeholderString = field.isPairList ? (field.key == "keybind" ? "Shortcut" : "Name") : "Value"
            row.addArrangedSubview(left)
            var right: NSTextField?
            if field.isPairList {
                let value = settingsInput(parts.1 ?? "", id: "settings.\(field.key).\(index).value", delegate: self)
                value.placeholderString = field.key == "keybind" ? "Action" : "Value"
                row.addArrangedSubview(value)
                left.widthAnchor.constraint(equalTo: value.widthAnchor).isActive = true
                right = value
                controls.append(value)
            }
            if field.key == "keybind" {
                let recorder = SettingsShortcutRecorder(recorded: { [weak self, weak left] shortcut in
                    left?.stringValue = shortcut
                    self?.publishRows()
                }, status: { [weak self] message in
                    self?.recordingHint.stringValue = message
                    self?.recordingHint.isHidden = message.isEmpty
                })
                row.addArrangedSubview(recorder)
                controls.append(recorder)
            }
            let remove = SettingsButton("Remove") { [weak self] in
                guard let self else { return }
                self.entries.remove(at: index)
                self.placeholders = Set(self.placeholders.filter { $0 != index }.map { $0 > index ? $0 - 1 : $0 })
                self.changed(self.serialized)
                self.render()
            }
            remove.setAccessibilityLabel("Remove entry \(index + 1)")
            row.addArrangedSubview(remove)
            inputs.append((left, right))
            controls += [left, remove]
            content.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        if entries.count > visibleCount {
            let more = SettingsButton("Show More (\(entries.count - visibleCount) remaining)") { [weak self] in
                guard let self else { return }
                self.visibleCount += 12
                self.render()
            }
            content.addArrangedSubview(more)
            controls.append(more)
        }
        let add = SettingsButton("Add Entry") { [weak self] in
            guard let self else { return }
            self.placeholders.insert(self.entries.count)
            self.entries.append("")
            self.visibleCount = self.entries.count
            self.render()
            if let input = self.inputs.last?.0 { self.window?.makeFirstResponder(input) }
        }
        content.addArrangedSubview(add)
        controls.append(add)
    }

    private func renderRaw() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = false
        scroll.borderType = .bezelBorder
        let editor = SettingsTextView(frame: NSRect(x: 0, y: 0, width: 450, height: 160))
        editor.configurePlainText()
        editor.font = SettingsTypography.font
        editor.textColor = .white
        editor.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 1)
        editor.string = entries.joined(separator: "\n")
        editor.delegate = self
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.setAccessibilityIdentifier("settings.\(field.key)")
        scroll.documentView = editor
        scroll.heightAnchor.constraint(equalToConstant: 180).isActive = true
        scroll.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        content.addArrangedSubview(scroll)
        content.addArrangedSubview(settingsLabel("One entry per line. Order is preserved.", muted: true))
        rawEditor = editor
    }

    private func publishRows() {
        for (index, pair) in inputs.enumerated() {
            if placeholders.contains(index) {
                if pair.0.stringValue.isEmpty && (pair.1?.stringValue.isEmpty ?? true) { continue }
                placeholders.remove(index)
            }
            if let right = pair.1 {
                // An untouched non-pair expression (e.g. 'clear') stays exact.
                if Self.split(entries[index]).1 == nil && right.stringValue.isEmpty && pair.0.stringValue == entries[index] { continue }
                entries[index] = pair.0.stringValue + "=" + right.stringValue
            } else { entries[index] = pair.0.stringValue }
        }
        changed(serialized)
    }
    func controlTextDidChange(_ obj: Notification) { publishRows() }
    func textDidChange(_ notification: Notification) {
        guard let value = rawEditor?.string else { return }
        entries = value.isEmpty ? [] : value.components(separatedBy: "\n")
        changed(value)
    }
    override func refresh(context: [String: String]) {
        guard let value = context[field.key], value != serialized,
              inputs.allSatisfy({ $0.0.currentEditor() == nil && $0.1?.currentEditor() == nil }),
              rawEditor == nil || window?.firstResponder !== rawEditor else { return }
        entries = value.isEmpty ? [] : value.components(separatedBy: "\n")
        placeholders = []
        render()
    }

    override func setEnabled(_ enabled: Bool) {
        super.setEnabled(enabled)
        rawEditor?.isEditable = enabled
    }
}

final class SettingsShortcutRecorder: NSButton {
    private let recorded: (String) -> Void
    private var recording = false
    private let status: (String) -> Void
    override var acceptsFirstResponder: Bool { true }

    init(recorded: @escaping (String) -> Void, status: @escaping (String) -> Void) {
        self.recorded = recorded
        self.status = status
        super.init(frame: .zero)
        cell = SettingsButtonCell(textCell: "Record")
        title = "Record"
        font = SettingsTypography.font
        bezelStyle = .rounded
        target = self
        action = #selector(beginRecording)
        setContentHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func beginRecording() {
        // Finish AppKit's button tracking before transferring keyboard focus.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.makeFirstResponder(self) == true else { return }
            self.recording = true
            self.title = "Press Keys"
            self.status("Press a shortcut. Escape cancels. Shortcuts reserved by other apps may interrupt recording.")
            NotificationCenter.default.addObserver(self, selector: #selector(self.recordingInterrupted), name: NSWindow.didResignKeyNotification, object: self.window)
            NotificationCenter.default.addObserver(self, selector: #selector(self.recordingInterrupted), name: NSApplication.didResignActiveNotification, object: NSApp)
        }
    }
    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }
    isolated deinit { NotificationCenter.default.removeObserver(self) }

    private func stopRecording() {
        recording = false
        title = "Record"
        status("")
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSApplication.didResignActiveNotification, object: nil)
    }

    @objc private func recordingInterrupted() {
        guard recording else { return }
        stopRecording()
        status("Recording stopped because Settings lost focus. Try a shortcut that is not reserved by another app.")
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        capture(event) || super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if !capture(event) { super.keyDown(with: event) }
    }

    /// AppDelegate calls this before menu shortcuts. Otherwise combinations
    /// such as Command Shift K perform app actions instead of being recorded.
    func capture(_ event: NSEvent) -> Bool {
        guard recording else { return false }
        record(event)
        return true
    }

    private func record(_ event: NSEvent) {
        if event.keyCode == 53 { stopRecording(); window?.makeFirstResponder(nil); return }
        let specials: [UInt16: String] = [36: "enter", 48: "tab", 49: "space", 51: "backspace", 117: "delete",
                                         123: "left", 124: "right", 125: "down", 126: "up", 115: "home", 119: "end",
                                         116: "page_up", 121: "page_down",
                                         18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0"]
        let key = specials[event.keyCode] ?? event.charactersIgnoringModifiers?.lowercased() ?? ""
        guard specials[event.keyCode] != nil || (key.count == 1 && key.range(of: "^[a-z0-9]$", options: .regularExpression) != nil) else {
            NSSound.beep()
            toolTip = "Enter this key in Advanced. Escape cancels recording."
            return
        }
        var parts: [String] = []
        for (flag, name) in [(NSEvent.ModifierFlags.command, "super"), (.control, "ctrl"), (.option, "alt"), (.shift, "shift")] where event.modifierFlags.contains(flag) { parts.append(name) }
        parts.append(key)
        recorded(parts.joined(separator: "+"))
        stopRecording()
        window?.makeFirstResponder(nil)
    }
}
