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
}
