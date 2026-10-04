import AppKit
import Foundation
import Testing
@testable import Ghostty

@MainActor struct SettingsTests {
    private func withStore(_ text: String = "", _ body: (SettingsStore, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("legacy.conf")
        if !text.isEmpty { try text.write(to: source, atomically: true, encoding: .utf8) }
        let store = SettingsStore(legacySource: source, directory: root.appendingPathComponent("Settings"))
        try body(store, source)
    }

    private func withStoreAsync(_ text: String = "", _ body: (SettingsStore, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("legacy.conf")
        if !text.isEmpty { try text.write(to: source, atomically: true, encoding: .utf8) }
        let store = SettingsStore(legacySource: source, directory: root.appendingPathComponent("Settings"))
        try await body(store, source)
    }

    @Test func diagnosticsMatchExactKeysAndPreserveValues() throws {
        let source = URL(fileURLWithPath: "/tmp/settings:custom")
        let config = try #require(Ghostty.ConfigHandle.load(data: Data("font-size = bad\n".utf8), source: source))
        let error = try #require(config.settingsDiagnostics.first)
        #expect(error.key == "font-size")
        #expect(error.source == source.path)
        #expect(error.line == 1)
        #expect(error.rawMessage.contains("/tmp/settings:custom:1:font-size:"))
        let global = SettingsDiagnostic(kind: .core, message: "Unable to read /tmp/font-family-bold")
        #expect(global.key == nil)
        #expect(global.displayMessage == global.message)
        #expect(throws: (any Error).self) { try SettingsField.decodeCatalog(Data("[]".utf8)) }
        #expect(throws: (any Error).self) { try SettingsField.decodeCatalog(Data("broken".utf8)) }
        try withStore { store, _ in
            _ = store.load(cli: false)
            let model = SettingsModel(store: store)
            model.edit(try #require(SettingsField.byKey["font-thicken-strength"]), value: "256")
            #expect(model.error(for: "font-thicken-strength") != nil)
            #expect(model.error(for: "font-thicken") == nil)
        }
    }

    @Test func deferredValidationUsesLatestDraftAndSaveChecksIt() async throws {
        try await withStoreAsync { store, _ in
            _ = store.load(cli: false)
            let model = SettingsModel(store: store)
            let field = try #require(SettingsField.byKey["font-size"])
            model.edit(field, value: "1", deferred: true)
            model.edit(field, value: "19", deferred: true)
            #expect(model.validationPending)
            #expect(!model.canSave)
            model.flushValidation()
            #expect(model.canSave)
            #expect(model.displayed[field.key] == "19")
            model.edit(field, value: "nan", deferred: true)
            #expect(model.error(for: field.key) != nil)
            #expect(await model.saveAsync() == false)
            #expect(model.error(for: field.key) != nil)
            model.reload()
            #expect(!model.validationPending)
            #expect(!model.dirty)
        }
    }

    @Test func themeInheritanceUpdatesDraftWithoutChangingRunningSettings() async throws {
        try await withStoreAsync("background = #102030") { store, source in
            _ = store.load(cli: false)
            let model = SettingsModel(store: store)
            let theme = source.deletingLastPathComponent().appendingPathComponent("TestTheme")
            try "background = #abcdef\nforeground = #123456".write(to: theme, atomically: true, encoding: .utf8)
            let original = model.runningValues
            model.edit(try #require(SettingsField.byKey["theme"]), value: theme.path)
            #expect(model.errors.isEmpty)
            #expect(model.displayed["foreground"] == "#123456")
            #expect(model.displayed["background"] == "#102030")
            #expect(model.savedValues == original)
            let size = try #require(SettingsField.byKey["font-size"])
            model.edit(size, value: "invalid")
            #expect(model.displayed["font-size"] == "invalid")
            #expect(model.effectiveValues["foreground"] == "#123456")
            model.edit(size, value: "18")
            #expect(await model.saveAsync())
            #expect(model.savedValues["foreground"] == "#123456")
            #expect(model.runningValues == original)
            model.reload()
            #expect(model.displayed["foreground"] == "#123456")
        }
    }

    @Test func longListsKeepNewRowsBoundedAndRetainEditingState() throws {
        let field = try #require(SettingsField.byKey["env"])
        let value = (0..<1000).map { "KEY\($0)=value" }.joined(separator: "\n")
        let state = SettingsListEditor.State()
        var published = value
        let editor = SettingsListEditor(field: field, value: value, state: state) { published = $0 }
        let add = try #require(editor.controls.compactMap { $0 as? NSButton }.first { $0.title == "Add Entry" })
        add.performClick(nil)
        #expect(state.visibleIndices.count == 13)
        #expect(published == value)
        let key = try #require(editor.controls.first { $0.accessibilityIdentifier() == "settings.env.1000.key" } as? NSTextField)
        key.stringValue = "LAST"
        editor.controlTextDidChange(Notification(name: NSText.didChangeNotification))
        #expect(published.hasSuffix("LAST="))
        #expect(published.components(separatedBy: "\n")[999] == "KEY999=value")
        let advanced = try #require(editor.controls.compactMap { $0 as? NSButton }.first { $0.title == "Advanced" })
        advanced.performClick(nil)
        let rebuilt = SettingsListEditor(field: field, value: published, state: state) { _ in }
        #expect(state.isAdvanced)
        #expect(rebuilt.controls.compactMap { $0 as? NSButton }.contains { $0.title == "Use Rows" })
    }

    @Test func themeCatalogNoticesAddedAndRemovedThemes() throws {
        try withStore { _, source in
            let directory = source.deletingLastPathComponent().appendingPathComponent("themes")
            let catalog = SettingsThemeCatalog(directories: [directory])
            #expect(catalog.load().isEmpty)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("Custom")
            try "background = #123456".write(to: file, atomically: true, encoding: .utf8)
            #expect(catalog.load() == ["Custom"])
            #expect(catalog.load() == ["Custom"])
            try FileManager.default.removeItem(at: file)
            #expect(catalog.load().isEmpty)
        }
    }

    @Test func equivalentSearchResultsReuseControls() throws {
        try withStore { store, _ in
            _ = store.load(cli: false)
            let controller = SettingsController(store: store)
            let root = try #require(controller.window?.contentView)
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let search = try #require(descendants(root).first { $0.accessibilityIdentifier() == "settings.search" } as? NSTextField)
            search.stringValue = "font-size"
            controller.controlTextDidChange(Notification(name: NSText.didChangeNotification, object: search))
            let before = try #require(descendants(root).first { $0.accessibilityIdentifier() == "settings.font-size" })
            search.stringValue = "font-size font"
            controller.controlTextDidChange(Notification(name: NSText.didChangeNotification, object: search))
            let after = try #require(descendants(root).first { $0.accessibilityIdentifier() == "settings.font-size" })
            #expect(before === after)
        }
    }

    @Test func changingSearchAndCategoriesReuseRowsAndDrafts() async throws {
        try await withStoreAsync("font-size = 17") { store, _ in
            _ = store.load(cli: false)
            let controller = SettingsController(store: store)
            let root = try #require(controller.window?.contentView)
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            try await NativeTestWait.until("settings loaded", timeout: .seconds(3), polling: .milliseconds(5),
                                           diagnostics: { controller.model.status }, { controller.model.record != nil && !controller.model.isBusy })
            let search = try #require(descendants(root).first { $0.accessibilityIdentifier() == "settings.search" } as? NSTextField)
            @MainActor func find(_ query: String) {
                search.stringValue = query
                controller.controlTextDidChange(Notification(name: NSText.didChangeNotification, object: search))
            }
            find("font-size")
            let input = try #require(descendants(root).first { $0.accessibilityIdentifier() == "settings.font-size" } as? NSTextField)
            controller.model.edit(try #require(SettingsField.byKey["font-size"]), value: "19")
            for _ in 0..<3 {
                find("font")
                #expect(descendants(root).contains { $0 === input })
                find("window-width")
                #expect(!descendants(root).contains { $0 === input })
                find("font-size")
                #expect(descendants(root).contains { $0 === input })
                #expect(input.stringValue == "19")
            }
            let appearance = try #require(descendants(root).compactMap { $0 as? NSButton }.first { $0.title == "Appearance" })
            appearance.performClick(nil)
            #expect(descendants(root).contains { $0 === input })
            root.layoutSubtreeIfNeeded()
            #expect(input.bounds.width > 0)
            #expect(controller.model.dirty)
        }
    }

    @Test func settingsFieldSelectionPinsGeneralAndSearchesAcrossGroups() {
        let general = SettingsField.visibleFields(category: 1, query: "")
        #expect(Array(general.prefix(4).map(\.key)) == ["initial-window", "quit-after-last-window-closed", "window-width", "window-height"])
        let searched = SettingsField.visibleFields(category: 1, query: "font-size font")
        #expect(searched.contains { $0.key == "font-size" })
        #expect(!SettingsField.visibleFields(category: 3, query: "").contains { $0.key == "fullscreen" })
    }

    @Test func incompleteLimitModeSurvivesItsOwnDraftRefresh() throws {
        let field = try #require(SettingsField.byKey["scrollback-limit-lines"])
        var editor: SettingsMeasureEditor?
        var published: String?
        editor = SettingsMeasureEditor(field: field, value: "unlimited") { value in
            published = value
            editor?.refresh(context: [field.key: value])
        }
        let view = try #require(editor)
        defer { editor = nil }
        let selector = try #require(view.controls.compactMap { $0 as? NSSegmentedControl }.first)
        let input = try #require(view.controls.compactMap { $0 as? NSTextField }.first)
        selector.selectedSegment = 2
        _ = NSApp.sendAction(try #require(selector.action), to: selector.target, from: selector)
        #expect(published == "")
        #expect(selector.selectedSegment == 2)
        #expect(!input.isHidden)
        input.stringValue = "5000"
        view.controlTextDidChange(Notification(name: NSText.didChangeNotification))
        #expect(published == "5000")
        view.refresh(context: [field.key: "unlimited"])
        #expect(selector.selectedSegment == 1 && input.isHidden)
    }

    @Test func defaultsAreInternalAndDoNotCreateLegacyFile() throws {
        try withStore { store, source in
            #expect(store.load(cli: false)?.errors.isEmpty == true)
            #expect(!FileManager.default.fileExists(atPath: source.path))
            let record = try store.read()
            #expect(record.current.layers.isEmpty)
            let config = try #require(store.parse(record.current))
            #expect(config.formattedEntry("window-width") == "window-width = 157\n")
            #expect(config.formattedEntry("window-height") == "window-height = 43\n")
            #expect(config.formattedEntry("macos-titlebar-style") == "macos-titlebar-style = hidden\n")
            #expect(SettingsField.catalog.count > 150)
            #expect(!SettingsField.catalog.contains { $0.key == "config-file" })
        }
    }

    @Test func migrationCapturesIncludesAndNeverReadsThemAgain() throws {
        try withStore("title = Main\nconfig-file = child.conf\nfont-family = Menlo\nfont-family = Monaco") { store, source in
            let child = source.deletingLastPathComponent().appendingPathComponent("child.conf")
            try "title = Included\nfont-size = 19".write(to: child, atomically: true, encoding: .utf8)
            let current = try #require(store.load(cli: false))
            #expect(current.errors.isEmpty)
            #expect(current.formattedEntry("title") == "title = Included\n")
            #expect(current.formattedEntry("font-family").contains("Monaco"))
            try FileManager.default.removeItem(at: child)
            try "unknown-key = bad".write(to: source, atomically: true, encoding: .utf8)
            let restarted = try #require(store.load(cli: false))
            #expect(restarted.errors.isEmpty)
            #expect(restarted.formattedEntry("title") == current.formattedEntry("title"))
            #expect(restarted.formattedEntry("font-size") == "font-size = 19\n")
        }
    }

    @Test func invalidValuesCannotReplaceSavedSettings() throws {
        try withStore("title = Keep") { store, _ in
            _ = store.load(cli: false)
            let original = try Data(contentsOf: store.url)
            let record = try store.read()
            let invalid: [(String, String)] = [
                ("window-width", "9"), ("window-height", "3"), ("font-size", "0"),
                ("background-opacity", "1.5"), ("cursor-opacity", "-1"),
                ("font-thicken-strength", "256"), ("font-size", "nan"),
                ("initial-window", "yes please"), ("cursor-style", "triangle"),
                ("title", String(repeating: "文", count: 2000)), ("title", "x\u{0}y"),
                ("missing-setting", "true")
            ]
            for (key, value) in invalid {
                var input = record.current
                input.values[key] = value
                #expect(throws: (any Error).self) { try store.save(input, revision: record.revision) }
                #expect(try Data(contentsOf: store.url) == original)
            }
        }
    }

    @Test(arguments: [
        "background = #000000\nforeground = #ffffff\nselection-background = #ff0000\nselection-foreground = #000000\n",
        "cursor-style-blink = false\ncursor-effect = false\nshell-integration = none\nbackground-image-fit = stretch\nbackground-image-opacity = 1\nbackground-image = ?image.png"
    ])
    func migrationPreservesExplicitAppearance(_ text: String) throws {
        try withStore(text) { store, source in
            let original = try #require(Ghostty.ConfigHandle.load(data: Data(text.utf8), source: source))
            let imported = try #require(store.parse(.init(layers: [.init(text: text, source: source)])))
            for field in SettingsField.catalog {
                #expect(imported.formattedEntry(field.key) == original.formattedEntry(field.key), "\(field.key)")
            }
            let loaded = try #require(store.load(cli: false))
            #expect(loaded.errors.isEmpty)
            #expect(FileManager.default.fileExists(atPath: store.url.path))
        }
    }

    @Test func saveIsRestartOnlyAndStaleDraftIsRejected() throws {
        try withStore("title = Before") { store, _ in
            let current = try #require(store.load(cli: false))
            let record = try store.read()
            var input = record.current
            input.values["title"] = "After"
            let saved = try store.save(input, revision: record.revision)
            #expect(saved.previous == record.current)
            #expect(current.formattedEntry("title") == "title = Before\n")
            #expect(store.load(cli: false)?.formattedEntry("title") == "title = After\n")
            #expect(throws: SettingsStore.Failure.changed) { try store.save(record.current, revision: record.revision) }
            #expect(try store.read().revision == saved.revision)
        }
    }

    @Test func repeatableReplacementAndResetPreserveOtherSettings() throws {
        try withStore("font-family = Menlo\nfont-family = Monaco\ntitle = Keep\nkeybind = super+a=ignore") { store, _ in
            _ = store.load(cli: false)
            var record = try store.read()
            var input = record.current
            input.values["font-family"] = "LXGW WenKai Mono\nMenlo"
            input.values["keybind"] = "super+b=ignore"
            record = try store.save(input, revision: record.revision)
            let changed = try #require(store.parse(record.current))
            #expect(changed.formattedEntry("font-family") == "font-family = LXGW WenKai Mono\nfont-family = Menlo\n")
            #expect(changed.formattedEntry("keybind").contains("super+b=ignore"))
            #expect(!changed.formattedEntry("keybind").contains("super+a=ignore"))
            input.values["font-family"] = ""
            input.values["keybind"] = ""
            record = try store.save(input, revision: record.revision)
            #expect(store.parse(record.current)?.formattedEntry("font-family") == "font-family = \n")
            #expect(store.parse(record.current)?.formattedEntry("title") == "title = Keep\n")
        }
    }

    @Test func damagedCurrentRecordUsesPreviousAndCanBeRepairedInUI() async throws {
        try await withStoreAsync("title = Good") { store, _ in
            _ = store.load(cli: false)
            let record = try store.read()
            var bad = record.current
            bad.values["background-opacity"] = "invalid"
            let damaged = SettingsStore.Record(current: bad, previous: record.current)
            try JSONEncoder().encode(damaged).write(to: store.url)
            let recovered = try #require(store.load(cli: false))
            #expect(!recovered.errors.isEmpty)
            #expect(recovered.formattedEntry("title") == "title = Good\n")
            let model = SettingsModel(store: store)
            let field = try #require(SettingsField.catalog.first { $0.key == "background-opacity" })
            #expect(model.displayed[field.key] == "invalid")
            model.edit(field, value: "0.8")
            #expect(model.canSave)
            #expect(await model.saveAsync())
            #expect(store.load(cli: false)?.errors.isEmpty == true)
        }
    }

    @Test func malformedLegacyIsPreservedUntilExplicitReset() throws {
        let original = "font-size = broken"
        try withStore(original) { store, source in
            #expect(store.load(cli: false)?.errors.isEmpty == false)
            #expect(!FileManager.default.fileExists(atPath: store.url.path))
            #expect(try String(contentsOf: source, encoding: .utf8) == original)
            try store.restoreDefaults()
            #expect(store.load(cli: false)?.errors.isEmpty == true)
            #expect(try String(contentsOf: source, encoding: .utf8) == original)
        }
    }

    @Test func migrationUsesLegacySuccessfulSnapshotWhenCurrentFileIsBroken() throws {
        try withStore("title = Previous") { store, source in
            try LegacySettingsFixture.write("title = Previous", source: source)
            try "font-size = invalid".write(to: source, atomically: true, encoding: .utf8)
            let migrated = try #require(store.load(cli: false))
            #expect(migrated.formattedEntry("title") == "title = Previous\n")
            #expect(!migrated.errors.isEmpty)
            #expect(store.load(cli: false)?.errors.isEmpty == true)
            #expect(try String(contentsOf: source, encoding: .utf8) == "font-size = invalid")
        }
    }

    @Test func failedWritePreservesRecordAndDraft() async throws {
        try await withStoreAsync("title = Original") { store, _ in
            _ = store.load(cli: false)
            let data = try Data(contentsOf: store.url)
            let model = SettingsModel(store: store)
            let title = try #require(SettingsField.catalog.first { $0.key == "title" })
            model.edit(title, value: "Draft")
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: store.directory.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.directory.path) }
            #expect(await model.saveAsync() == false)
            #expect(model.dirty)
            #expect(model.canSave)
            #expect(model.displayed["title"] == "Draft")
            #expect(try Data(contentsOf: store.url) == data)
        }
    }

    @Test func appReusesOneSettingsWindow() throws {
        try withStore("initial-window = false") { _, source in
            let app = Ghostty.App(configPath: source.path)
            app.openConfig()
            let controller = try #require(app.settingsController)
            defer { controller.window?.close() }
            app.openConfig()
            #expect(app.settingsController === controller)
            #expect(controller.window?.isVisible == true)
        }
    }

    @Test func fixedTypographyAndWindowHaveIndependentState() throws {
        try withStore { store, _ in
            _ = store.load(cli: false)
            #expect(SettingsTypography.font.familyName == "LXGW WenKai Mono")
            #expect(SettingsTypography.font.pointSize == 16)
            #expect(SettingsTypography.thicken && SettingsTypography.strength == 255)
            let controller = SettingsController(store: store)
            let window = try #require(controller.window)
            #expect(window.appearance?.name == .darkAqua)
            #expect(window.styleMask.contains(.resizable))
            #expect(!window.isRestorable)
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let search = try #require(window.contentView.flatMap { descendants($0).first { $0.accessibilityIdentifier() == "settings.search" } } as? NSTextField)
            #expect(search.focusRingType == .none)
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    @Test func bundledFontPresetPreservesFallbacksAndPersistsAllParameters() async throws {
        try await withStoreAsync("font-family = Menlo\nfont-family = Unavailable Custom Font\nfont-style = Regular\nfont-thicken = false\nfont-thicken-strength = 100") { store, _ in
            _ = store.load(cli: false)
            let model = SettingsModel(store: store)
            #expect(!model.usesBundledFontPreset)
            model.applyBundledFontPreset(families: "LXGW WenKai Mono\nUnavailable Custom Font")
            #expect(model.usesBundledFontPreset)
            #expect(model.canSave)
            #expect(await model.saveAsync())
            let restored = SettingsModel(store: store)
            #expect(restored.usesBundledFontPreset)
            #expect(restored.displayed["font-family"] == "LXGW WenKai Mono\nUnavailable Custom Font")
            #expect(restored.displayed["font-style"] == "default")
            let thicken = try #require(SettingsField.catalog.first { $0.key == "font-thicken" })
            restored.edit(thicken, value: "false")
            #expect(!restored.usesBundledFontPreset)
        }
    }

    @Test func choicesPreserveAutomaticMeaningAndCatalogUsesEnglish() throws {
        let blink = try #require(SettingsField.catalog.first { $0.key == "cursor-style-blink" })
        #expect(blink.choiceValues == ["", "true", "false"])
        let initial = try #require(SettingsField.catalog.first { $0.key == "initial-window" })
        #expect(initial.choiceValues == ["true", "false"])
        for field in SettingsField.catalog {
            #expect(!field.title.contains("-"), "\(field.key): \(field.title)")
            #expect(!(field.title + field.help).unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }, "\(field.key)")
        }
    }
    @Test func returningToSavedValueClearsStatusAndDirtyState() throws {
        try withStore("font-size = 17") { store, _ in
            _ = store.load(cli: false)
            let model = SettingsModel(store: store)
            let field = try #require(SettingsField.catalog.first { $0.key == "font-size" })
            model.edit(field, value: "18")
            #expect(model.changedCount == 1 && model.canSave)
            model.edit(field, value: "17")
            #expect(!model.dirty && !model.canSave && model.changedCount == 0)
            #expect(model.status == "No unsaved changes.")
        }
    }

    @Test func semanticEditorsPreserveComplexValuesUntilExplicitEdit() throws {
        let duration = try #require(SettingsField.catalog.first { $0.key == "undo-timeout" })
        var updates: [String] = []
        let measure = SettingsMeasureEditor(field: duration, value: "1h 30m", changed: { updates.append($0) })
        #expect(updates.isEmpty)
        let number = try #require(measure.controls.compactMap { $0 as? NSTextField }.first)
        #expect(number.stringValue == "1h 30m")
        measure.controlTextDidChange(Notification(name: NSText.didChangeNotification))
        #expect(updates == ["1h 30m"])
        #expect(SettingsField.catalog.first { $0.key == "key-remap" }?.multiline == true)
        #expect(SettingsField.catalog.filter { ["maximize", "fullscreen"].contains($0.key) }.allSatisfy { !$0.isVisible })
    }

    @Test func flagControlsPersistExactCoreOptions() async throws {
        try await withStoreAsync("shell-integration-features = cursor,no-sudo,title,no-ssh-env,no-ssh-terminfo,path") { store, _ in
            _ = store.load(cli: false)
            let model = SettingsModel(store: store)
            let field = try #require(SettingsField.catalog.first { $0.key == "shell-integration-features" })
            #expect(field.flags.contains("ssh-terminfo"))
            let editor = SettingsFlagsEditor(field: field, value: model.displayed[field.key] ?? "") { model.edit(field, value: $0) }
            let sudo = try #require(editor.controls.first { $0.accessibilityIdentifier() == "settings.shell-integration-features.sudo" } as? NSButton)
            sudo.performClick(nil)
            #expect(model.canSave)
            #expect(await model.saveAsync())
            let parsed = try #require(store.load(cli: false))
            #expect(parsed.errors.isEmpty)
            let value = SettingsField.values(from: parsed.formattedEntry(field.key)).joined(separator: "\n")
            #expect(value.contains("sudo") && !value.contains("no-sudo"))
            #expect(value.contains("no-ssh-env") && value.contains("no-ssh-terminfo"))
        }
    }

    @Test func rowEditorPreservesEqualsInsideEnvironmentValues() async throws {
        try await withStoreAsync("env = TOKEN=a=b=c\nenv = MODE=before") { store, _ in
            _ = store.load(cli: false)
            let model = SettingsModel(store: store)
            let field = try #require(SettingsField.catalog.first { $0.key == "env" })
            let editor = SettingsListEditor(field: field, value: "TOKEN=a=b=c\nMODE=before") { model.edit(field, value: $0) }
            #expect(!model.dirty)
            let add = try #require(editor.controls.compactMap { $0 as? NSButton }.first { $0.title == "Add Entry" })
            add.performClick(nil)
            let second = try #require(editor.controls.first { $0.accessibilityIdentifier() == "settings.env.1.value" } as? NSTextField)
            second.stringValue = "after=kept"
            editor.controlTextDidChange(Notification(name: NSText.didChangeNotification))
            #expect(model.canSave)
            #expect(await model.saveAsync())
            let record = try store.read()
            #expect(record.current.values["env"] == "TOKEN=a=b=c\nMODE=after=kept")
            #expect(store.load(cli: false)?.errors.isEmpty == true)
        }
    }

    @Test func themePairsAndMeasurementUnitsKeepTheirMeaning() {
        let pair = SettingsThemeEditor.split("dark:Night,light:Day")
        #expect(pair.0 == "Day" && pair.1 == "Night")
        let microseconds = SettingsMeasureEditor.split("250ms", choices: ["", "m", "s", "ms", "raw"])
        #expect(microseconds.0 == "250" && microseconds.1 == "ms")
        let binding = SettingsListEditor.split("super+==increase_font_size:1", binding: true)
        #expect(binding.0 == "super+=" && binding.1 == "increase_font_size:1")
        let action = SettingsListEditor.split("super+a=text:a=b=c", binding: true)
        #expect(action.0 == "super+a" && action.1 == "text:a=b=c")
        let color = SettingsScalarEditor.color("#12abff")?.usingColorSpace(.sRGB)
        #expect(color != nil && abs((color?.redComponent ?? 0) - 18.0 / 255) < 0.001)
    }

    @Test func savedRestartNoticeSurvivesReopeningAndDiscardingDraft() async throws {
        try await withStoreAsync("font-size = 17") { store, _ in
            _ = store.load(cli: false)
            let model = SettingsModel(store: store)
            let field = try #require(SettingsField.catalog.first { $0.key == "font-size" })
            model.edit(field, value: "18")
            #expect(await model.saveAsync())
            model.reload()
            #expect(model.status.contains("Restart"))
            model.edit(field, value: "19")
            model.edit(field, value: "18")
            #expect(!model.dirty && model.status.contains("Restart"))
            try store.restoreDefaults()
            model.reload()
            #expect(!model.dirty && model.status.contains("Restart"))
        }
    }

    @Test func compactEditorsFitMinimumSettingsWidth() throws {
        try withStore { store, _ in
            _ = store.load(cli: false)
            let model = SettingsModel(store: store)
            for key in ["clipboard-write-limit-bytes", "notify-on-command-finish-after", "background-blur", "unfocused-split-fill", "font-style-bold-italic"] {
                let field = try #require(SettingsField.catalog.first { $0.key == key })
                let row = SettingsRow(field: field, value: model.displayed[key] ?? "", context: model.displayed,
                                      presetSelected: { _ in }, changed: { _ in })
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 575, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = row
                row.layoutSubtreeIfNeeded()
                func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                for control in descendants(row).compactMap({ $0 as? NSControl }) where !control.isHiddenOrHasHiddenAncestor {
                    let rect = control.convert(control.alignmentRect(forFrame: control.bounds), to: row)
                    #expect(rect.minX >= -1 && rect.maxX <= row.bounds.width + 1, "\(key): \(rect)")
                }
            }
        }
    }

    @Test func shortcutRecordingCancelsOnFocusLossAndPreservesShiftedDigits() async throws {
        var recorded: [String] = []
        var message = ""
        let recorder = SettingsShortcutRecorder(recorded: { recorded.append($0) }, status: { message = $0 })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = recorder
        recorder.performClick(nil)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        #expect(recorder.title == "Press Keys")
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(recorder.title == "Record" && message.contains("lost focus"))
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .shift], timestamp: 0,
                                                windowNumber: window.windowNumber, context: nil, characters: "(", charactersIgnoringModifiers: "(", isARepeat: false, keyCode: 25))
        #expect(!recorder.capture(event) && recorded.isEmpty)
        recorder.performClick(nil)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        #expect(recorder.capture(event))
        #expect(recorded == ["ctrl+shift+9"])
        #expect(!recorder.capture(event))
    }

    @Test func fontFallbackAvailabilityTracksPrimaryAndEditorState() throws {
        let field = try #require(SettingsField.byKey["font-family-bold"])
        var published = ""
        let picker = SettingsFontPicker(field: field, value: "", usesPreset: false,
                                        changed: { published = $0 }, presetSelected: { _ in })
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let primary = try #require(descendants(picker).compactMap { $0 as? NSComboBox }.first)
        let add = try #require(descendants(picker).compactMap { $0 as? NSButton }.first { $0.title == "Add Fallback" })
        #expect(!add.isEnabled)
        primary.stringValue = "Menlo"
        picker.controlTextDidChange(Notification(name: NSText.didChangeNotification, object: primary))
        #expect(add.isEnabled && published == "Menlo")
        picker.setEnabled(false)
        #expect(!add.isEnabled)
        picker.setEnabled(true)
        add.performClick(nil)
        #expect(descendants(picker).compactMap { $0 as? NSComboBox }.count == 2)
        picker.refresh(value: "", preset: false)
        let inheritedAdd = try #require(descendants(picker).compactMap { $0 as? NSButton }.first { $0.title == "Add Fallback" })
        #expect(!inheritedAdd.isEnabled)
    }

    @Test func restartNoticeTracksResolvedSavedDifferenceAcrossModels() async throws {
        try await withStoreAsync("font-size = 17") { store, _ in
            _ = store.load(cli: false)
            let field = try #require(SettingsField.byKey["font-size"])
            let model = SettingsModel(store: store)
            model.edit(field, value: "18")
            #expect(await model.saveAsync())
            #expect(model.restartRequired)
            let reopened = SettingsModel(store: store)
            #expect(reopened.restartRequired)
            reopened.edit(field, value: "17")
            #expect(await reopened.saveAsync())
            #expect(!reopened.restartRequired)
            model.reload()
            #expect(!model.restartRequired)
            #expect(model.savedValues == store.startupValues)
            #expect(model.runningValues == store.runningValues)
        }
    }

    @Test func oversizedSettingsAreRejectedBeforeDecoding() throws {
        try withStore { store, _ in
            _ = store.load(cli: false)
            let file = try FileHandle(forWritingTo: store.url)
            try file.truncate(atOffset: UInt64(SettingsStore.Disk.maximumRecordBytes + 1))
            try file.close()
            #expect(throws: SettingsStore.Failure.unreadable) { try store.read() }
        }
    }

    @Test func operationStatesRemainConsistentAndBusyReloadIsIgnored() async throws {
        try await withStoreAsync { store, _ in
            _ = store.load(cli: false)
            let model = SettingsModel(store: store)
            let title = try #require(SettingsField.byKey["title"])
            model.edit(title, value: "State transitions", deferred: true)
            #expect(model.validation == .pending && !model.canSave)
            var operations: [SettingsModel.Operation] = []
            model.stateChanged = {
                operations.append(model.operation)
                if model.operation == .saving { #expect(model.status == "Saving…" && !model.canSave) }
            }
            let saving = Task { await model.saveAsync() }
            try await NativeTestWait.until("save started", timeout: .seconds(1), polling: .milliseconds(1),
                                           diagnostics: { model.status }, { model.isBusy || !model.dirty })
            // The callback captures the transition even if a fast disk finishes first.
            #expect(await saving.value)
            #expect(operations == [.saving, .idle])
            #expect(model.validation == .valid && !model.dirty)
            #expect(model.status == "Saved. Restart to apply.")
            operations = []
            #expect(await model.reloadAsync())
            #expect(operations == [.loading, .idle])
        }
    }

    @Test func presentingSettingsCoalescesInitialLoad() async throws {
        try await withStoreAsync { store, _ in
            _ = store.load(cli: false)
            let controller = SettingsController(store: store)
            defer { controller.window?.close() }
            let update = controller.model.stateChanged
            var loads = 0
            controller.model.stateChanged = {
                if controller.model.operation == .loading { loads += 1 }
                update?()
            }
            defer { controller.model.stateChanged = update }
            controller.present()
            controller.present()
            try await NativeTestWait.until("initial load", timeout: .seconds(3), polling: .milliseconds(5),
                                           diagnostics: { controller.model.status }, { controller.model.record != nil && !controller.model.isBusy })
            #expect(loads == 1)
        }
    }

    @Test func lockedSettingsTimeOutAndCancellationPreservesDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SettingsStore(legacySource: root.appendingPathComponent("legacy"), directory: root)
        _ = store.load(cli: false)
        let original = try store.read().revision
        let model = SettingsModel(store: store)
        model.edit(try #require(SettingsField.byKey["title"]), value: "Keep this draft")
        let lock = open(root.appendingPathComponent("settings.lock").path, O_RDWR)
        #expect(lock >= 0)
        defer { close(lock) }
        #expect(flock(lock, LOCK_EX | LOCK_NB) == 0)
        defer { flock(lock, LOCK_UN) }
        let started = ContinuousClock.now
        #expect(await model.saveAsync() == false)
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(model.errors.contains { $0.contains("busy in another app instance") })
        #expect(!model.isBusy && model.dirty && model.canSave)
        let saving = Task { await model.saveAsync() }
        try await NativeTestWait.until("save waiting for lock", timeout: .seconds(1), polling: .milliseconds(5),
                                       diagnostics: { model.status }, { model.isBusy })
        #expect(await model.reloadAsync() == false)
        #expect(model.operation == .saving)
        saving.cancel()
        #expect(await saving.value == false)
        #expect(!model.isBusy && model.dirty && model.canSave)
        #expect(model.displayed["title"] == "Keep this draft")
        #expect(try store.read().revision == original)
        let reset = Task { try await store.restoreDefaultsAsync() }
        reset.cancel()
        do { _ = try await reset.value; Issue.record("Cancelled reset unexpectedly succeeded") } catch is CancellationError {}
        #expect(try store.read().revision == original)
        #expect(flock(lock, LOCK_UN) == 0)
        #expect(await model.saveAsync())
        #expect(try store.read().current.values["title"] == "Keep this draft")
    }

    @Test func asyncSaveKeepsMainActorAvailableAndRejectsStaleWriter() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SettingsStore(legacySource: root.appendingPathComponent("legacy"), directory: root)
        _ = store.load(cli: false)
        let model = SettingsModel(store: store)
        let title = try #require(SettingsField.byKey["title"])
        model.edit(title, value: "Draft")
        let lock = open(root.appendingPathComponent("settings.lock").path, O_RDWR)
        #expect(lock >= 0)
        defer { close(lock) }
        #expect(flock(lock, LOCK_EX | LOCK_NB) == 0)
        defer { flock(lock, LOCK_UN) }
        let saving = Task { await model.saveAsync() }
        try await NativeTestWait.until("async save started", timeout: .seconds(3), polling: .milliseconds(5),
                                       diagnostics: { model.status }, { model.isBusy })
        #expect(!model.canSave)
        model.edit(title, value: "Ignored while saving")
        #expect(model.displayed[title.key] == "Draft")
        // Simulate the competing writer that owns the lock, then release it.
        let competing = SettingsStore.Record(current: .init(values: ["title": "Other instance"]))
        try JSONEncoder().encode(competing).write(to: store.url, options: .atomic)
        #expect(flock(lock, LOCK_UN) == 0)
        #expect(await saving.value == false)
        #expect(!model.isBusy && model.dirty)
        #expect(model.displayed[title.key] == "Draft")
        #expect(try store.read().revision == competing.revision)
        await model.reloadAsync()
        model.edit(title, value: "Saved asynchronously")
        #expect(await model.saveAsync())
        #expect(try store.read().current.values[title.key] == "Saved asynchronously")
        await model.reloadAsync(reset: true)
        #expect(model.record?.current == SettingsStore.Input())
    }

    @Test func discardingBeforeCancelledQuitReloadsLatestRevisionAndVisibleFields() async throws {
        try await withStoreAsync("font-size = 17") { store, _ in
            _ = store.load(cli: false)
            let controller = SettingsController(store: store)
            defer { controller.window?.close() }
            let root = try #require(controller.window?.contentView)
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            try await NativeTestWait.until("settings loaded", timeout: .seconds(3), polling: .milliseconds(5),
                                           diagnostics: { controller.model.status }, { controller.model.record != nil && !controller.model.isBusy })
            let model = controller.model
            let original = try #require(model.record)
            let field = try #require(SettingsField.byKey["font-size"])
            let search = try #require(descendants(root).first { $0.accessibilityIdentifier() == "settings.search" } as? NSTextField)
            search.stringValue = field.key
            controller.controlTextDidChange(Notification(name: NSText.didChangeNotification, object: search))
            model.edit(field, value: "19", deferred: true)
            let competingStore = SettingsStore(legacySource: store.legacySource, directory: store.directory)
            var competingInput = original.current
            competingInput.values[field.key] = "23"
            let competing = try competingStore.save(competingInput, revision: original.revision)
            var continued = false
            let closed = controller.confirmClose(runModal: { _ in .alertSecondButtonReturn }, afterSave: {
                // The terminal confirmation cancels quit: keep this controller open.
                // Both the revision and visible editor must be current before it runs.
                #expect(model.record?.revision == competing.revision)
                #expect(model.displayed[field.key] == "23")
                let editor = descendants(root).first { $0.accessibilityIdentifier() == "settings.font-size" } as? NSTextField
                #expect(editor?.stringValue == "23")
                #expect(!model.isBusy && !model.dirty && !model.validationPending)
                #expect(controller.window?.isDocumentEdited == false)
                continued = true
            })
            #expect(!closed)
            #expect(!continued)
            try await NativeTestWait.until("discard continuation", timeout: .seconds(3), polling: .milliseconds(5),
                                           diagnostics: { model.status }, { continued })
            #expect(model.savedValues[field.key] == "23")
            model.edit(field, value: "25")
            #expect(await model.saveAsync())
            #expect(try store.read().current.values[field.key] == "25")
        }
    }

    @Test func unreadableDiscardStopsQuitAndShowsReadFailure() async throws {
        try await withStoreAsync { store, _ in
            _ = store.load(cli: false)
            let controller = SettingsController(store: store)
            defer { controller.window?.close() }
            try await NativeTestWait.until("settings loaded", timeout: .seconds(3), polling: .milliseconds(5),
                                           diagnostics: { controller.model.status }, { controller.model.record != nil && !controller.model.isBusy })
            let model = controller.model
            let original = try Data(contentsOf: store.url)
            model.edit(try #require(SettingsField.byKey["title"]), value: "Unsaved title")
            try Data("invalid settings".utf8).write(to: store.url, options: .atomic)
            var continued = false
            #expect(!controller.confirmClose(runModal: { _ in .alertSecondButtonReturn }, afterSave: { continued = true }))
            try await NativeTestWait.until("discard read failure", timeout: .seconds(3), polling: .milliseconds(5),
                                           diagnostics: { model.status }, { model.record == nil && !model.isBusy })
            #expect(!continued && !model.canSave)
            #expect(model.status == "Unable to read settings. Retry or restore defaults.")
            #expect(model.diagnostics.contains { $0.kind == .storage })
            let root = try #require(controller.window?.contentView)
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let errors = try #require(descendants(root).first { $0.accessibilityIdentifier() == "settings.errors" } as? NSTextField)
            #expect(!errors.isHidden && !errors.stringValue.isEmpty)
            // Retry recovers from the read error without retaining a stale revision.
            try original.write(to: store.url, options: .atomic)
            #expect(await model.discardDraft())
            #expect(model.record != nil && model.errors.isEmpty && !model.dirty)
        }
    }

    @Test func settingsInputsHaveNoFocusRingAndFooterSharesOneRow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SettingsStore(legacySource: root.appendingPathComponent("legacy"), directory: root)
        _ = store.load(cli: false)
        let controller = SettingsController(store: store)
        let window = try #require(controller.window)
        let content = try #require(window.contentView)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        try await NativeTestWait.until("settings loaded", timeout: .seconds(3), polling: .milliseconds(5),
                                       diagnostics: { controller.model.status }, { controller.model.record != nil && !controller.model.isBusy })
        window.setContentSize(NSSize(width: 840, height: 600))
        content.layoutSubtreeIfNeeded()
        let status = try #require(descendants(content).first { $0.accessibilityIdentifier() == "settings.status" })
        let save = try #require(descendants(content).first { $0.accessibilityIdentifier() == "settings.save" })
        #expect(status.superview === save.superview)
        #expect(abs(status.convert(status.bounds, to: content).midY - save.convert(save.bounds, to: content).midY) < 3)
        let search = try #require(descendants(content).first { $0.accessibilityIdentifier() == "settings.search" } as? NSTextField)
        search.stringValue = ""
        for category in ["General", "Appearance", "Windows", "Quick Terminal", "Input", "Terminal", "Security", "Advanced"] {
            let button = try #require(descendants(content).compactMap { $0 as? NSButton }.first { $0.title == category })
            button.performClick(nil)
            #expect(button.layer?.backgroundColor?.alpha == 0)
            let views = descendants(content)
            #expect(views.contains { ($0 as? NSBox)?.boxType == .separator })
            for input in views where input is NSTextView || (input as? NSTextField)?.isEditable == true {
                #expect(input.focusRingType == .none, "\(input.accessibilityIdentifier())")
            }
        }
    }

    @Test func measureSettingsEvaluationForLargeDraft() throws {
        try withStore { store, _ in
            _ = store.load(cli: false)
            let input = SettingsStore.Input(values: ["env": (0..<1000).map { "KEY\($0)=value" }.joined(separator: "\n")])
            var samples: [Double] = []
            for _ in 0..<10 {
                let start = ContinuousClock.now
                let evaluation = store.evaluate(input)
                _ = evaluation.values
                let duration = start.duration(to: .now).components
                samples.append(Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)
                #expect(evaluation.diagnostics.isEmpty)
            }
            print("SETTINGS_METRIC entries=1000 samples=10 median_ms=\(samples.sorted()[5]) max_ms=\(samples.max() ?? 0)")
        }
    }

}
