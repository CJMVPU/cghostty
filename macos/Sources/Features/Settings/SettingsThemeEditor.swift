import AppKit

final class SettingsThemeEditor: SettingsValueEditor, NSComboBoxDelegate, NSComboBoxDataSource {
    private let changed: (String) -> Void
    private let mode = NSSegmentedControl(labels: ["Single", "Light and Dark"], trackingMode: .selectOne, target: nil, action: nil)
    private var combos: [SettingsComboBox] = []
    private var themeRows: [NSStackView] = []
    private let preview = settingsLabel("Aa Bb 0123   Terminal preview")
    private let names: [String]
    private var filtered: [ObjectIdentifier: [String]] = [:]
    override var headingControl: NSControl? { mode }
    private var raw: String

    init(value: String, changed: @escaping (String) -> Void) {
        self.changed = changed
        raw = value
        var directories: [URL] = []
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            directories.append(support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.cjmvpu.cghostty").appendingPathComponent("themes"))
        }
        if let resources = Bundle.main.resourceURL { directories.append(resources.appendingPathComponent("cghostty/themes")) }
        #if !DEBUG
        if let resources = ProcessInfo.processInfo.environment["CGHOSTTY_RESOURCES_DIR"], !resources.isEmpty {
            directories.append(URL(fileURLWithPath: resources).appendingPathComponent("themes"))
        }
        #endif
        names = Set(directories.flatMap { directory in
            ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: .skipsHiddenFiles)) ?? [])
                .filter { (try? $0.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.map(\.lastPathComponent)
        }).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        mode.font = SettingsTypography.font
        mode.target = self
        mode.action = #selector(modeChanged)
        mode.setAccessibilityIdentifier("settings.theme.mode")
        mode.selectedSegment = value.hasPrefix("light:") || value.hasPrefix("dark:") ? 1 : 0
        controls.append(mode)
        let pair = Self.split(value)
        for index in 0..<2 {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            let label = settingsLabel(index == 0 ? "Light" : "Dark", muted: true)
            label.widthAnchor.constraint(equalToConstant: 50).isActive = true
            row.addArrangedSubview(label)
            let combo = SettingsComboBox()
            combo.font = SettingsTypography.font
            combo.isEditable = true
            combo.completes = true
            combo.usesDataSource = true
            combo.dataSource = self
            combo.delegate = self
            combo.target = self
            combo.action = #selector(committed)
            combo.numberOfVisibleItems = 12
            combo.stringValue = index == 0 ? pair.0 : pair.1
            combo.placeholderString = "Auto"
            combo.heightAnchor.constraint(equalToConstant: 32).isActive = true
            combo.setAccessibilityIdentifier("settings.theme.\(index)")
            row.addArrangedSubview(combo)
            addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
            themeRows.append(row)
            combos.append(combo)
            controls.append(combo)
        }
        preview.drawsBackground = true
        preview.backgroundColor = .black
        preview.heightAnchor.constraint(equalToConstant: 60).isActive = true
        preview.setAccessibilityIdentifier("settings.theme.preview")
        addArrangedSubview(preview)
        preview.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        updateVisibility()
        updatePreview()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    static func split(_ value: String) -> (String, String) {
        guard value.hasPrefix("light:") || value.hasPrefix("dark:") else { return (value, value) }
        var light = "", dark = ""
        for part in value.split(separator: ",") {
            let text = part.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("light:") { light = String(text.dropFirst(6)) }
            if text.hasPrefix("dark:") { dark = String(text.dropFirst(5)) }
        }
        return (light, dark)
    }
    override func refresh(context: [String: String]) {
        guard let value = context["theme"], value != raw, combos.allSatisfy({ $0.currentEditor() == nil }) else { return }
        raw = value
        let pair = Self.split(value)
        mode.selectedSegment = value.hasPrefix("light:") || value.hasPrefix("dark:") ? 1 : 0
        combos[0].stringValue = pair.0
        combos[1].stringValue = pair.1
        updateVisibility()
        updatePreview()
    }

    private func updateVisibility() {
        themeRows[1].isHidden = mode.selectedSegment == 0
        themeRows[0].arrangedSubviews.first?.isHidden = mode.selectedSegment == 0
    }
    private func publish() {
        raw = mode.selectedSegment == 0 ? combos[0].stringValue : "light:\(combos[0].stringValue),dark:\(combos[1].stringValue)"
        changed(raw)
    }
    private func updatePreview() {
        // Use the core parser for theme includes and named colors, just as the
        // terminal does. This preview never updates a running terminal surface.
        let value = mode.selectedSegment == 0 ? combos[0].stringValue : combos[1].stringValue
        guard !value.contains("\n"), let config = Ghostty.ConfigHandle.load(data: Data("theme = \(value)".utf8), source: URL(fileURLWithPath: "/settings-theme-preview")), config.errors.isEmpty else {
            preview.stringValue = "Preview unavailable"
            return
        }
        preview.stringValue = mode.selectedSegment == 0 ? "Aa Bb 0123   Terminal preview" : "Aa Bb 0123   Dark theme preview"
        preview.backgroundColor = SettingsScalarEditor.color(SettingsField.values(from: config.formattedEntry("background")).first ?? "") ?? .black
        preview.textColor = SettingsScalarEditor.color(SettingsField.values(from: config.formattedEntry("foreground")).first ?? "") ?? .white
    }
    @objc private func modeChanged() { updateVisibility(); publish(); updatePreview() }
    @objc private func committed() { publish(); updatePreview() }
    func controlTextDidChange(_ notification: Notification) {
        guard let combo = notification.object as? NSComboBox else { return }
        filtered[ObjectIdentifier(combo)] = names.filter { $0.localizedCaseInsensitiveContains(combo.stringValue) }
        combo.reloadData()
        publish()
    }
    func controlTextDidEndEditing(_ notification: Notification) { updatePreview() }
    func comboBoxSelectionDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.committed() }
    }
    func comboBoxWillPopUp(_ notification: Notification) {
        guard let combo = notification.object as? NSComboBox else { return }
        if names.contains(combo.stringValue) { filtered[ObjectIdentifier(combo)] = nil; combo.reloadData() }
    }
    func numberOfItems(in comboBox: NSComboBox) -> Int { (filtered[ObjectIdentifier(comboBox)] ?? names).count }
    func comboBox(_ comboBox: NSComboBox, objectValueForItemAt index: Int) -> Any? {
        let items = filtered[ObjectIdentifier(comboBox)] ?? names
        return items.indices.contains(index) ? items[index] : nil
    }
    func comboBox(_ comboBox: NSComboBox, completedString string: String) -> String? {
        names.first { $0.lowercased().hasPrefix(string.lowercased()) }
    }
}
