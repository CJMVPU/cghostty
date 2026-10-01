import AppKit

private final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
           let editor = firstResponder as? NSTextView {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a": editor.selectAll(nil); return true
            case "c": editor.copy(nil); return true
            case "v": editor.pasteAsPlainText(nil); return true
            case "x": editor.cut(nil); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class SettingsList: NSStackView {
    override var isFlipped: Bool { true }
}

@MainActor final class SettingsController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    let model: SettingsModel
    private let groups = ["General", "Appearance", "Windows", "Quick Terminal", "Input", "Terminal", "Security", "Advanced"]
    private let preferences: UserDefaults
    private var category: Int
    private var query = ""
    private let rows = SettingsList()
    private let search = NSTextField()
    private let status = settingsLabel("")
    private let diagnostics = settingsLabel("")
    private var rowViews: [String: SettingsRow] = [:]
    private var categoryButtons: [SettingsButton] = []
    private var saveButton: SettingsButton!
    private var discardButton: SettingsButton!
    private let fieldEditor = SettingsTextView()

    init(store: SettingsStore, preferences: UserDefaults = .ghostty) {
        model = SettingsModel(store: store)
        self.preferences = preferences
        category = min(8, max(1, preferences.integer(forKey: "settings.category")))
        super.init(window: nil)
        let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 760),
                                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                    backing: .buffered, defer: false)
        window.title = "cghostty · Settings"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedWhite: 0.115, alpha: 1)
        window.minSize = NSSize(width: 840, height: 600)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        window.setFrameAutosaveName("cghostty-settings")
        if !window.setFrameUsingName("cghostty-settings") { window.center() }
        self.window = window
        fieldEditor.isFieldEditor = true
        fieldEditor.configurePlainText()
        fieldEditor.font = SettingsTypography.font
        buildContent()
        renderRows()
        updateState()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present() {
        if window?.isVisible != true && !model.dirty {
            model.reload()
            renderRows()
            updateState()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func settingsWereReset() {
        model.reload()
        renderRows()
        updateState()
    }

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? { fieldEditor }

    @IBAction func close(_ sender: Any?) { window?.performClose(sender) }
    @IBAction func closeWindow(_ sender: Any?) { window?.performClose(sender) }
    @objc func cancel(_ sender: Any?) { window?.performClose(sender) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.dirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes?"
        alert.informativeText = model.canSave ? "Restart the app to apply saved changes." : "Fix the invalid settings or discard your changes."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Keep Editing")
        alert.buttons[0].isEnabled = model.canSave
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let saved = model.save()
            updateState()
            return saved
        case .alertSecondButtonReturn: model.reload(); return true
        default: return false
        }
    }

    private func buildContent() {
        guard let root = window?.contentView else { return }
        let horizontal = NSStackView()
        horizontal.orientation = .horizontal
        horizontal.alignment = .top
        horizontal.spacing = 0
        horizontal.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(horizontal)
        NSLayoutConstraint.activate([
            horizontal.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            horizontal.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            horizontal.topAnchor.constraint(equalTo: root.topAnchor),
            horizontal.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        let sidebar = NSStackView()
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 14
        sidebar.edgeInsets = NSEdgeInsets(top: 26, left: 18, bottom: 20, right: 18)
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = NSColor(calibratedWhite: 0.145, alpha: 1).cgColor
        sidebar.addArrangedSubview(settingsLabel("Settings"))
        for (index, name) in groups.enumerated() {
            let button = SettingsButton(name) { [weak self] in self?.selectCategory(index + 1) }
            button.isBordered = false
            button.alignment = .left
            button.widthAnchor.constraint(equalToConstant: 155).isActive = true
            button.heightAnchor.constraint(equalToConstant: 34).isActive = true
            sidebar.addArrangedSubview(button)
            categoryButtons.append(button)
        }
        sidebar.addArrangedSubview(NSView())
        horizontal.addArrangedSubview(sidebar)
        let main = NSStackView()
        main.orientation = .vertical
        main.alignment = .leading
        main.spacing = 18
        main.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 20, right: 28)
        main.wantsLayer = true
        main.layer?.backgroundColor = NSColor(calibratedWhite: 0.115, alpha: 1).cgColor
        horizontal.addArrangedSubview(main)
        sidebar.heightAnchor.constraint(equalTo: horizontal.heightAnchor).isActive = true
        sidebar.widthAnchor.constraint(equalToConstant: 195).isActive = true
        main.heightAnchor.constraint(equalTo: horizontal.heightAnchor).isActive = true
        main.widthAnchor.constraint(equalTo: horizontal.widthAnchor, constant: -195).isActive = true
        search.cell = SettingsTextCell(textCell: "")
        search.font = SettingsTypography.font
        search.isEditable = true
        search.isSelectable = true
        search.focusRingType = .none
        search.isBezeled = true
        search.drawsBackground = true
        search.placeholderString = "Search settings"
        search.delegate = self
        search.setAccessibilityIdentifier("settings.search")
        search.heightAnchor.constraint(equalToConstant: 34).isActive = true
        main.addArrangedSubview(search)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 24
        rows.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 24, right: 14)
        rows.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = rows
        rows.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        main.addArrangedSubview(scroll)
        main.addArrangedSubview(diagnostics)
        diagnostics.textColor = NSColor(calibratedRed: 1, green: 0.57, blue: 0.5, alpha: 1)
        diagnostics.maximumNumberOfLines = 4
        diagnostics.setAccessibilityIdentifier("settings.errors")
        main.addArrangedSubview(status)
        status.maximumNumberOfLines = 2
        status.setAccessibilityIdentifier("settings.status")
        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.spacing = 12
        footer.addArrangedSubview(SettingsButton("Restore Defaults") { [weak self] in self?.resetDefaults() })
        footer.addArrangedSubview(SettingsButton("Reload") { [weak self] in self?.reload() })
        let space = NSView()
        space.setContentHuggingPriority(.init(1), for: .horizontal)
        footer.addArrangedSubview(space)
        discardButton = SettingsButton("Discard Changes") { [weak self] in self?.reload() }
        footer.addArrangedSubview(discardButton)
        saveButton = SettingsButton("Save") { [weak self] in self?.save() }
        saveButton.keyEquivalent = "s"
        saveButton.keyEquivalentModifierMask = .command
        saveButton.contentTintColor = NSColor(calibratedRed: 0.71, green: 0.81, blue: 0.63, alpha: 1)
        saveButton.setAccessibilityIdentifier("settings.save")
        footer.addArrangedSubview(saveButton)
        main.addArrangedSubview(footer)
        for view in [search, scroll, diagnostics, status, footer] {
            view.widthAnchor.constraint(equalTo: main.widthAnchor, constant: -56).isActive = true
        }
    }

    private func selectCategory(_ category: Int) {
        self.category = category
        preferences.set(category, forKey: "settings.category")
        query = ""
        search.stringValue = ""
        renderRows()
    }

    func controlTextDidChange(_ obj: Notification) {
        query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        renderRows()
    }

    private func renderRows() {
        rows.arrangedSubviews.forEach { rows.removeArrangedSubview($0); $0.removeFromSuperview() }
        rowViews = [:]
        for (index, button) in categoryButtons.enumerated() {
            button.contentTintColor = index + 1 == category ? NSColor(calibratedRed: 0.71, green: 0.81, blue: 0.63, alpha: 1) : .secondaryLabelColor
        }
        rows.addArrangedSubview(settingsLabel(query.isEmpty ? groups[category - 1] : "Search Results"))
        let pinned = ["initial-window", "quit-after-last-window-closed", "window-width", "window-height"]
        let fields = SettingsField.catalog.filter {
            query.isEmpty ? ($0.group == category || (category == 1 && pinned.contains($0.key))) : "\($0.title) \($0.key) \($0.help)".localizedCaseInsensitiveContains(query)
        }.sorted {
            (pinned.firstIndex(of: $0.key) ?? 1000) < (pinned.firstIndex(of: $1.key) ?? 1000)
        }
        if fields.isEmpty { rows.addArrangedSubview(settingsLabel("No matching settings", muted: true)) }
        for field in fields {
            let row = SettingsRow(field: field, value: model.displayed[field.key] ?? field.defaultValue,
                                  usesFontPreset: model.usesBundledFontPreset,
                                  presetSelected: { [weak self] families in
                self?.model.applyBundledFontPreset(families: families)
                // Let the native dropdown finish dispatching its selection first.
                DispatchQueue.main.async { [weak self] in self?.renderRows() }
            }, changed: { [weak self] value in
                self?.model.edit(field, value: value)
                self?.updateState()
            })
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -14).isActive = true
            rowViews[field.key] = row
        }
        rows.enclosingScrollView?.contentView.scroll(to: .zero)
        updateState()
    }

    private func updateState() {
        status.stringValue = model.status
        diagnostics.stringValue = SettingsField.readable(model.errors.joined(separator: "\n"))
        diagnostics.toolTip = diagnostics.stringValue
        diagnostics.isHidden = model.errors.isEmpty
        saveButton.isEnabled = model.canSave
        discardButton.isEnabled = model.dirty
        window?.isDocumentEdited = model.dirty
        for (key, row) in rowViews {
            row.showError(model.error(for: key), enabled: model.record != nil)
            row.refreshFontPreset(model.usesBundledFontPreset)
        }
    }

    private func save() { _ = model.save(); updateState() }

    private func reload() {
        if model.dirty {
            let alert = NSAlert()
            alert.messageText = "Discard unsaved changes?"
            alert.addButton(withTitle: "Discard and Reload")
            alert.addButton(withTitle: "Keep Editing")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        model.reload()
        renderRows()
    }

    private func resetDefaults() {
        let alert = NSAlert()
        alert.messageText = "Restore all defaults?"
        alert.informativeText = "Saved settings will be backed up. Unsaved changes will be discarded. Restart to apply."
        alert.addButton(withTitle: "Restore Defaults")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try model.store.restoreDefaults()
            settingsWereReset()
        } catch { NSAlert(error: error).runModal() }
    }
}
