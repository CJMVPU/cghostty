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

    @Test func diagnosticsMatchExactKeysAndPreserveValues() throws {
        let error = SettingsDiagnostic(coreMessage: "font-family-bold: cannot open /tmp/font-family-test")
        #expect(error.key == "font-family-bold")
        #expect(error.message == "cannot open /tmp/font-family-test")
        #expect(error.displayMessage.hasSuffix("/tmp/font-family-test"))
        let global = SettingsDiagnostic(coreMessage: "Unable to read /tmp/font-family-bold")
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

    @Test func deferredValidationUsesLatestDraftAndSaveChecksIt() throws {
        try withStore { store, _ in
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
            #expect(!model.save())
            model.reload()
            #expect(!model.validationPending)
            #expect(!model.dirty)
        }
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

    @Test func damagedCurrentRecordUsesPreviousAndCanBeRepairedInUI() throws {
        try withStore("title = Good") { store, _ in
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
            #expect(model.save())
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
            let legacy = Ghostty.ConfigStore(source: source)
            _ = legacy.load(cli: false)
            try "font-size = invalid".write(to: source, atomically: true, encoding: .utf8)
            let migrated = try #require(store.load(cli: false))
            #expect(migrated.formattedEntry("title") == "title = Previous\n")
            #expect(!migrated.errors.isEmpty)
            #expect(store.load(cli: false)?.errors.isEmpty == true)
            #expect(try String(contentsOf: source, encoding: .utf8) == "font-size = invalid")
        }
    }

    @Test func failedWritePreservesRecordAndDraft() throws {
        try withStore("title = Original") { store, _ in
            _ = store.load(cli: false)
            let data = try Data(contentsOf: store.url)
            let model = SettingsModel(store: store)
            let title = try #require(SettingsField.catalog.first { $0.key == "title" })
            model.edit(title, value: "Draft")
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: store.directory.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.directory.path) }
            #expect(!model.save())
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

    @Test func bundledFontPresetPreservesFallbacksAndPersistsAllParameters() throws {
        try withStore("font-family = Menlo\nfont-family = Unavailable Custom Font\nfont-style = Regular\nfont-thicken = false\nfont-thicken-strength = 100") { store, _ in
            _ = store.load(cli: false)
            let model = SettingsModel(store: store)
            #expect(!model.usesBundledFontPreset)
            model.applyBundledFontPreset(families: "LXGW WenKai Mono\nUnavailable Custom Font")
            #expect(model.usesBundledFontPreset)
            #expect(model.canSave)
            #expect(model.save())
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

    @Test func flagControlsPersistExactCoreOptions() throws {
        try withStore("shell-integration-features = cursor,no-sudo,title,no-ssh-env,no-ssh-terminfo,path") { store, _ in
            _ = store.load(cli: false)
            let model = SettingsModel(store: store)
            let field = try #require(SettingsField.catalog.first { $0.key == "shell-integration-features" })
            #expect(field.flags.contains("ssh-terminfo"))
            let editor = SettingsFlagsEditor(field: field, value: model.displayed[field.key] ?? "") { model.edit(field, value: $0) }
            let sudo = try #require(editor.controls.first { $0.accessibilityIdentifier() == "settings.shell-integration-features.sudo" } as? NSButton)
            sudo.performClick(nil)
            #expect(model.canSave && model.save())
            let parsed = try #require(store.load(cli: false))
            #expect(parsed.errors.isEmpty)
            let value = SettingsField.values(from: parsed.formattedEntry(field.key)).joined(separator: "\n")
            #expect(value.contains("sudo") && !value.contains("no-sudo"))
            #expect(value.contains("no-ssh-env") && value.contains("no-ssh-terminfo"))
        }
    }

    @Test func rowEditorPreservesEqualsInsideEnvironmentValues() throws {
        try withStore("env = TOKEN=a=b=c\nenv = MODE=before") { store, _ in
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
            #expect(model.canSave && model.save())
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

    @Test func savedRestartNoticeSurvivesReopeningAndDiscardingDraft() throws {
        try withStore("font-size = 17") { store, _ in
            _ = store.load(cli: false)
            let model = SettingsModel(store: store)
            let field = try #require(SettingsField.catalog.first { $0.key == "font-size" })
            model.edit(field, value: "18")
            #expect(model.save())
            model.reload()
            #expect(model.status.contains("Restart"))
            model.edit(field, value: "19")
            model.edit(field, value: "18")
            #expect(!model.dirty && model.status.contains("Restart"))
            try store.restoreDefaults()
            model.reload(afterReset: true)
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

}
