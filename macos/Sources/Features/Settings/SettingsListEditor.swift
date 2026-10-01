import AppKit

/// Ordered rows preserve duplicates, empty values and '=' inside values. The
/// advanced view retains sequences and expressions that have no simple editor.
final class SettingsListEditor: SettingsValueEditor, NSTextFieldDelegate, NSTextViewDelegate {
    private let field: SettingsField
    private let changed: (String) -> Void
    final class State {
        var entries: [String] = []
        var placeholders: Set<Int> = []
        var isAdvanced = false
        var visibleCount = 12
        var extraVisible: Set<Int> = []
        var serialized: String { entries.enumerated().filter { !placeholders.contains($0.offset) }.map(\.element).joined(separator: "\n") }
        var visibleIndices: [Int] { Set(entries.indices.prefix(visibleCount)).union(extraVisible.intersection(Set(entries.indices))).sorted() }
    }
    private let state: State
    private var entries: [String] { get { state.entries } set { state.entries = newValue } }
    private let content = NSStackView()
    private let advanced = SettingsButton("Advanced") {}
    private var rawEditor: SettingsTextView?
    private var inputs: [(index: Int, key: NSTextField, value: NSTextField?)] = []
    private var isAdvanced: Bool { get { state.isAdvanced } set { state.isAdvanced = newValue } }
    private var visibleCount: Int { get { state.visibleCount } set { state.visibleCount = newValue } }
    private var placeholders: Set<Int> { get { state.placeholders } set { state.placeholders = newValue } }
    private let recordingHint = settingsLabel("", muted: true)
    private var serialized: String { state.serialized }

    init(field: SettingsField, value: String, state: State = State(), changed: @escaping (String) -> Void) {
        self.field = field
        self.changed = changed
        self.state = state
        if state.serialized != value {
            state.entries = value.isEmpty ? [] : value.components(separatedBy: "\n")
            state.placeholders = []
            state.extraVisible = []
        }
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
                self.state.extraVisible = []
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
        for index in state.visibleIndices {
            let entry = entries[index]
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
                self.state.extraVisible = Set(self.state.extraVisible.filter { $0 != index }.map { $0 > index ? $0 - 1 : $0 })
                self.placeholders = Set(self.placeholders.filter { $0 != index }.map { $0 > index ? $0 - 1 : $0 })
                self.changed(self.serialized)
                self.render()
            }
            remove.setAccessibilityLabel("Remove entry \(index + 1)")
            row.addArrangedSubview(remove)
            inputs.append((index, left, right))
            controls += [left, remove]
            content.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        let remaining = entries.count - state.visibleIndices.count
        if remaining > 0 {
            let more = SettingsButton("Show More (\(remaining) remaining)") { [weak self] in
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
            self.state.extraVisible.insert(self.entries.count - 1)
            self.render()
            if let input = self.inputs.last?.key { self.window?.makeFirstResponder(input) }
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
        content.addArrangedSubview(scroll)
        scroll.heightAnchor.constraint(equalToConstant: 180).isActive = true
        scroll.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        content.addArrangedSubview(settingsLabel("One entry per line. Order is preserved.", muted: true))
        rawEditor = editor
    }

    private func publishRows() {
        for pair in inputs {
            let index = pair.index
            if placeholders.contains(index) {
                if pair.key.stringValue.isEmpty && (pair.value?.stringValue.isEmpty ?? true) { continue }
                placeholders.remove(index)
            }
            if let right = pair.value {
                // An untouched non-pair expression (e.g. 'clear') stays exact.
                if Self.split(entries[index]).1 == nil && right.stringValue.isEmpty && pair.key.stringValue == entries[index] { continue }
                entries[index] = pair.key.stringValue + "=" + right.stringValue
            } else { entries[index] = pair.key.stringValue }
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
              inputs.allSatisfy({ $0.key.currentEditor() == nil && $0.value?.currentEditor() == nil }),
              rawEditor == nil || window?.firstResponder !== rawEditor else { return }
        entries = value.isEmpty ? [] : value.components(separatedBy: "\n")
        placeholders = []
        state.extraVisible = []
        render()
    }

    override func setEnabled(_ enabled: Bool) {
        super.setEnabled(enabled)
        rawEditor?.isEditable = enabled
    }
}
