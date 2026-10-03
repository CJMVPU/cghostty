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
    private var cachedRows: [String: SettingsRow] = [:]
    private var decorations: [String: NSView] = [:]
    private var listStates: [String: SettingsListEditor.State] = [:]
    private var renderedKeys: [String] = []
    private var renderedSearch = false
    private var categoryButtons: [SettingsButton] = []
    private var saveButton: SettingsButton!
    private var discardButton: SettingsButton!
    private var resetButton: SettingsButton!
    private let fieldEditor = SettingsTextView()
    private var collapsedSections: Set<String> = ["Advanced Typography"]
    private var renderedContext: [String: String] = [:]
    private var renderedErrors: [String: String] = [:]
    private var renderedEnabled: Bool?
    private var renderedPreset: Bool?
    private var loadTask: Task<Void, Never>?
    private var categoryOffsets: [Int: NSPoint] = [:]

    init(store: SettingsStore, preferences: UserDefaults = .ghostty) {
        model = SettingsModel(store: store, loadImmediately: false)
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
        model.stateChanged = { [weak self] in self?.updateState() }
        buildContent()
        renderRows()
        updateState()
        loadSettings()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present() {
        if window?.isVisible != true && !model.dirty { loadSettings() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? { fieldEditor }

    @IBAction func close(_ sender: Any?) { window?.performClose(sender) }
    @IBAction func closeWindow(_ sender: Any?) { window?.performClose(sender) }
    @objc func cancel(_ sender: Any?) { window?.performClose(sender) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        confirmClose { sender.close() }
    }

    func confirmClose(
        runModal: (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() },
        afterSave: @escaping () -> Void
    ) -> Bool {
        guard !model.isBusy else { return false }
        guard model.dirty else { return true }
        if model.validationPending { model.flushValidation() }
        let alert = NSAlert()
        alert.messageText = "Save changes?"
        alert.informativeText = model.canSave ? "Restart the app to apply saved changes." : "Fix the invalid settings or discard your changes."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Keep Editing")
        alert.buttons[0].isEnabled = model.canSave
        switch runModal(alert) {
        case .alertFirstButtonReturn:
            Task { if await model.saveAsync() { afterSave() } }
            return false
        case .alertSecondButtonReturn:
            Task {
                guard await model.discardDraft() else { return }
                refreshLoadedRows()
                afterSave()
            }
            return false
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
        sidebar.spacing = 6
        sidebar.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 20, right: 18)
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = NSColor(calibratedWhite: 0.145, alpha: 1).cgColor
        sidebar.addArrangedSubview(settingsLabel("Settings"))
        for (index, name) in groups.enumerated() {
            let button = SettingsButton(name) { [weak self] in self?.selectCategory(index + 1) }
            button.isBordered = false
            button.alignment = .left
            button.widthAnchor.constraint(equalToConstant: 155).isActive = true
            button.heightAnchor.constraint(equalToConstant: 30).isActive = true
            sidebar.addArrangedSubview(button)
            categoryButtons.append(button)
        }
        sidebar.addArrangedSubview(NSView())
        horizontal.addArrangedSubview(sidebar)
        let main = NSStackView()
        main.orientation = .vertical
        main.alignment = .leading
        main.spacing = 12
        main.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 14, right: 20)
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
        search.heightAnchor.constraint(equalToConstant: 30).isActive = true
        main.addArrangedSubview(search)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 6
        rows.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 12, right: 14)
        rows.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = rows
        rows.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        main.addArrangedSubview(scroll)
        main.addArrangedSubview(diagnostics)
        diagnostics.textColor = NSColor(calibratedRed: 1, green: 0.57, blue: 0.5, alpha: 1)
        diagnostics.maximumNumberOfLines = 4
        diagnostics.setAccessibilityIdentifier("settings.errors")
        status.maximumNumberOfLines = 1
        status.lineBreakMode = .byTruncatingTail
        status.alignment = .right
        status.textColor = .secondaryLabelColor
        status.setContentHuggingPriority(.init(1), for: .horizontal)
        status.setAccessibilityIdentifier("settings.status")
        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.spacing = 8
        resetButton = SettingsButton("Restore Defaults") { [weak self] in self?.resetDefaults() }
        footer.addArrangedSubview(resetButton)
        discardButton = SettingsButton("Discard Changes") { [weak self] in self?.reload() }
        footer.addArrangedSubview(discardButton)
        footer.addArrangedSubview(status)
        saveButton = SettingsButton("Save") { [weak self] in self?.save() }
        saveButton.keyEquivalent = "s"
        saveButton.keyEquivalentModifierMask = .command
        saveButton.contentTintColor = NSColor(calibratedRed: 0.71, green: 0.81, blue: 0.63, alpha: 1)
        saveButton.setAccessibilityIdentifier("settings.save")
        footer.addArrangedSubview(saveButton)
        main.addArrangedSubview(footer)
        for view in [search, scroll, diagnostics, footer] {
            view.widthAnchor.constraint(equalTo: main.widthAnchor, constant: -40).isActive = true
        }
    }

    private func selectCategory(_ category: Int) {
        if query.isEmpty { categoryOffsets[self.category] = rows.enclosingScrollView?.contentView.bounds.origin }
        self.category = category
        preferences.set(category, forKey: "settings.category")
        query = ""
        search.stringValue = ""
        renderRows(offset: categoryOffsets[category] ?? .zero)
    }

    func controlTextDidChange(_ obj: Notification) {
        query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        renderRows(offset: .zero, searchOnly: true)
    }

    private func renderRows(offset: NSPoint? = nil, searchOnly: Bool = false) {
        let fields = SettingsField.visibleFields(category: category, query: query)
        let keys = fields.map(\.key)
        if searchOnly && renderedSearch && !query.isEmpty && keys == renderedKeys { return }
        renderedKeys = keys
        renderedSearch = !query.isEmpty
        let savedOffset = offset ?? rows.enclosingScrollView?.contentView.bounds.origin ?? .zero
        var desired: [NSView] = []
        rowViews = [:]
        renderedContext = [:]
        renderedErrors = [:]
        renderedEnabled = nil
        renderedPreset = nil
        for (index, button) in categoryButtons.enumerated() {
            button.wantsLayer = true
            button.layer?.backgroundColor = NSColor.clear.cgColor
            button.setAccessibilityValue(index + 1 == category ? "Selected" : "")
            button.contentTintColor = index + 1 == category ? NSColor(calibratedRed: 0.71, green: 0.81, blue: 0.63, alpha: 1) : .secondaryLabelColor
        }
        desired.append(label(query.isEmpty ? groups[category - 1] : "\(fields.count) Search \(fields.count == 1 ? "Result" : "Results")", key: "heading"))
        if fields.isEmpty { desired.append(label("No matching settings", key: "empty", muted: true)) }
        let sections = category == 2 && query.isEmpty ? ["Font", "Colors", "Cursor", "Advanced Typography"] : [""]
        var lastBreadcrumb = ""
        for section in sections {
            if !section.isEmpty {
                let button = (decorations["section." + section] as? SettingsButton) ?? SettingsButton(section) { [weak self] in
                    guard let self else { return }
                    if self.collapsedSections.contains(section) { self.collapsedSections.remove(section) } else { self.collapsedSections.insert(section) }
                    self.renderRows()
                }
                decorations["section." + section] = button
                button.title = "\(collapsedSections.contains(section) ? "▸" : "▾") \(section)"
                button.isBordered = false
                button.setAccessibilityIdentifier("settings.section.\(section)")
                desired.append(button)
                if collapsedSections.contains(section) { continue }
            }
            for field in fields where section.isEmpty || field.section == section {
                if !query.isEmpty {
                    let breadcrumb = groups[field.group - 1] + (field.section.isEmpty ? "" : " · " + field.section)
                    if breadcrumb != lastBreadcrumb { desired.append(label(breadcrumb, key: "breadcrumb." + field.key, muted: true)) }
                    lastBreadcrumb = breadcrumb
                }
                let listState = listStates[field.key] ?? SettingsListEditor.State()
                listStates[field.key] = listState
                let row = cachedRows[field.key] ?? SettingsRow(field: field, value: model.displayed[field.key] ?? field.defaultValue,
                                      usesFontPreset: model.usesBundledFontPreset, context: model.displayed, listState: listState,
                                      presetSelected: { [weak self] families in
                    self?.model.applyBundledFontPreset(families: families)
                    self?.updateState()
                }, changed: { [weak self] value in
                    self?.model.edit(field, value: value, deferred: true)
                    self?.updateState()
                })
                cachedRows[field.key] = row
                let divider = (decorations["divider." + field.key] as? NSBox) ?? NSBox()
                decorations["divider." + field.key] = divider
                divider.boxType = .separator
                divider.setAccessibilityElement(false)
                desired.append(contentsOf: [divider, row])
                rowViews[field.key] = row
            }
        }
        reconcileRows(desired)
        rows.layoutSubtreeIfNeeded()
        if let scroll = rows.enclosingScrollView {
            let maxY = max(0, rows.bounds.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(savedOffset.y, maxY)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        updateState()
    }

    private func label(_ title: String, key: String, muted: Bool = false) -> NSTextField {
        let label = (decorations[key] as? NSTextField) ?? settingsLabel(title, muted: muted)
        label.stringValue = title
        decorations[key] = label
        return label
    }

    /// Keep surviving views attached so their editors and constraints stay intact.
    /// The cache is bounded by the catalog and cleared after an explicit reload.
    private func reconcileRows(_ desired: [NSView]) {
        let identities = Set(desired.map(ObjectIdentifier.init))
        for view in rows.arrangedSubviews where !identities.contains(ObjectIdentifier(view)) {
            rows.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, view) in desired.enumerated() {
            if index < rows.arrangedSubviews.count, rows.arrangedSubviews[index] === view { continue }
            let attached = view.superview === rows
            if attached { rows.removeArrangedSubview(view) }
            rows.insertArrangedSubview(view, at: index)
            if !attached, view is SettingsRow || view is NSBox {
                view.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -14).isActive = true
            }
        }
    }

    private func updateState() {
        status.stringValue = model.status
        status.toolTip = model.status
        diagnostics.stringValue = model.errors.joined(separator: "\n")
        diagnostics.toolTip = model.diagnostics.map(\.rawMessage).joined(separator: "\n")
        diagnostics.isHidden = model.errors.isEmpty
        saveButton.isEnabled = model.canSave
        discardButton.isEnabled = !model.isBusy && (model.dirty || model.record == nil)
        resetButton.isEnabled = !model.isBusy
        discardButton.title = model.record == nil ? "Retry" : "Discard Changes"
        window?.isDocumentEdited = model.dirty
        let context = model.displayed
        let enabled = model.record != nil && !model.isBusy
        let preset = model.usesBundledFontPreset
        let changed = Set(context.keys).union(renderedContext.keys).filter { context[$0] != renderedContext[$0] }
        let fontChanged = changed.contains { $0.hasPrefix("font-family") }
        for (key, row) in rowViews {
            let error = model.error(for: key)
            if renderedEnabled != enabled || renderedErrors[key] != error {
                row.showError(error, enabled: enabled)
            }
            if changed.contains(key) || renderedPreset != preset || (fontChanged && key.hasPrefix("font-style")) {
                row.refresh(context: context, preset: preset)
            }
            renderedErrors[key] = error
        }
        renderedContext = context
        renderedEnabled = enabled
        renderedPreset = preset
    }

    private func save() { Task { _ = await model.saveAsync() } }

    private func loadSettings(reset: Bool = false) {
        guard loadTask == nil, !model.isBusy else { return }
        loadTask = Task { [weak self] in
            guard let self else { return }
            defer { self.loadTask = nil }
            guard await self.model.reloadAsync(reset: reset) else { return }
            self.refreshLoadedRows()
        }
    }

    private func refreshLoadedRows() {
        listStates = [:]
        cachedRows = [:]
        renderRows()
    }

    private func reload() {
        if model.dirty {
            let alert = NSAlert()
            alert.messageText = "Discard unsaved changes?"
            alert.addButton(withTitle: "Discard and Reload")
            alert.addButton(withTitle: "Keep Editing")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        loadSettings()
    }

    private func resetDefaults() {
        let alert = NSAlert()
        alert.messageText = "Restore all defaults?"
        alert.informativeText = "Saved settings will be backed up. Unsaved changes will be discarded. Restart to apply."
        alert.addButton(withTitle: "Restore Defaults")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        loadSettings(reset: true)
    }
}
