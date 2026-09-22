import Foundation
import SwiftUI
import Testing
@testable import Ghostty

@MainActor struct ConfigStoreTests {
    private func withStore(_ body: (Ghostty.ConfigStore, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("config.ghostty")
        try body(Ghostty.ConfigStore(source: source, build: "test-build"), source)
    }

    @Test func editingGuidePreservesSettingsAndThemeInheritance() throws {
        try withStore { _, source in
            let theme = source.deletingLastPathComponent().appendingPathComponent("local.theme")
            try "background = #123456".write(to: theme, atomically: true, encoding: .utf8)
            let original = "# Existing settings\ntheme = \(theme.path)\nbackground-opacity = 0.6\nfont-family = Menlo\nfont-family = Monaco\n"
            try original.write(to: source, atomically: true, encoding: .utf8)
            #expect(Ghostty.ConfigHandle.prepareForEditing(at: source.path) == source.path)
            let guided = try String(contentsOf: source, encoding: .utf8)
            #expect(guided.hasPrefix(original))
            #expect(guided.contains("8 高级 / Advanced"))
            #expect(guided.contains("# font-size = 14"))
            let config = Ghostty.Config(at: source.path)
            #expect(config.errors.isEmpty)
            #expect(config.backgroundOpacity == 0.6)
            #expect(config.snapshot.backgroundColor == Color(red: 0x12 / 255.0, green: 0x34 / 255.0, blue: 0x56 / 255.0))
            #expect(Ghostty.ConfigHandle.prepareForEditing(at: source.path) == source.path)
            #expect(try String(contentsOf: source, encoding: .utf8) == guided)
        }
    }

    @Test func editingGuidePreservesSymbolicLinkAndItsTarget() throws {
        try withStore { _, source in
            let target = source.deletingLastPathComponent().appendingPathComponent("shared.ghostty")
            try "font-size = 19\n".write(to: target, atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(at: source, withDestinationURL: target)
            #expect(Ghostty.ConfigHandle.prepareForEditing(at: source.path) == source.path)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: source.path) == target.path)
            #expect(try String(contentsOf: target, encoding: .utf8).hasPrefix("font-size = 19\n"))
            #expect(try String(contentsOf: target, encoding: .utf8).contains("# cghostty configuration guide v1"))
        }
    }

    @Test func startupReusesUnchangedInputAndAcceptsChangedInput() throws {
        try withStore { store, source in
            try "title = First".write(to: source, atomically: true, encoding: .utf8)
            #expect(Ghostty.Config(handle: store.load(cli: false)).title == "First")
            #expect(!store.usedSavedInput)
            #expect(Ghostty.Config(handle: store.load(cli: false)).title == "First")
            #expect(store.usedSavedInput)
            try "title = Second".write(to: source, atomically: true, encoding: .utf8)
            #expect(Ghostty.Config(handle: store.load(cli: false)).title == "Second")
            #expect(!store.usedSavedInput)
        }
    }

    @Test func invalidStartupRestoresWholeSuccessfulFileWithoutOverwritingUserFile() throws {
        try withStore { store, source in
            try "title = Good\nbackground-opacity = 0.4".write(to: source, atomically: true, encoding: .utf8)
            _ = store.load(cli: false)
            let invalid = "title = Partial\nbackground-opacity = invalid"
            try invalid.write(to: source, atomically: true, encoding: .utf8)
            let restarted = Ghostty.ConfigStore(source: source, build: "next-build")
            let config = Ghostty.Config(handle: restarted.load(cli: false))
            #expect(config.title == "Good")
            #expect(config.backgroundOpacity == 0.4)
            #expect(config.errors.contains { $0.contains("background-opacity") })
            #expect(config.errors.contains { $0.contains("last successful") })
            #expect(try String(contentsOf: source, encoding: .utf8) == invalid)
        }
    }

    @Test func absentAndEmptyFilesUseDefaultsWithoutCreatingUserFile() throws {
        try withStore { store, source in
            let initial = Ghostty.Config(handle: store.load(cli: false))
            #expect(initial.loaded && initial.errors.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: source.path))
            try Data().write(to: source)
            #expect(Ghostty.Config(handle: store.load(cli: false)).errors.isEmpty)
            try "background-opacity = invalid".write(to: source, atomically: true, encoding: .utf8)
            #expect(Ghostty.Config(handle: store.load(cli: false)).backgroundOpacity == 1)
        }
    }

    @Test func corruptSnapshotCannotApplyPartialInvalidConfiguration() throws {
        try withStore { store, source in
            try "title = Good".write(to: source, atomically: true, encoding: .utf8)
            _ = store.load(cli: false)
            try Data("broken snapshot".utf8).write(to: store.directory.appendingPathComponent("last-success.json"))
            try "title = Partial\nbackground-opacity = invalid".write(to: source, atomically: true, encoding: .utf8)
            let fallback = Ghostty.Config(handle: store.load(cli: false))
            #expect(fallback.title == nil)
            #expect(fallback.backgroundOpacity == 1)
            #expect(!fallback.errors.isEmpty)
        }
    }

    @Test func resetBacksUpAndPreventsOldSnapshotReturning() throws {
        try withStore { store, source in
            let original = "title = Custom\nbackground-opacity = 0.5"
            try original.write(to: source, atomically: true, encoding: .utf8)
            let current = Ghostty.Config(handle: store.load(cli: false))
            let restoredBackup = try store.restoreDefaults()
            let backup = try #require(restoredBackup)
            #expect(try String(contentsOf: backup, encoding: .utf8) == original)
            #expect(try String(contentsOf: source, encoding: .utf8).contains("# cghostty configuration guide v1"))
            #expect(current.title == "Custom")
            #expect(Ghostty.Config(handle: store.load(cli: false)).title == nil)
            try "title = Partial\nbackground-opacity = invalid".write(to: source, atomically: true, encoding: .utf8)
            #expect(Ghostty.Config(handle: store.load(cli: false)).title == nil)
        }
    }

    @Test func cachedInputKeepsOriginalRelativeReferenceBase() throws {
        try withStore { store, source in
            let included = source.deletingLastPathComponent().appendingPathComponent("included.conf")
            try "title = Included".write(to: included, atomically: true, encoding: .utf8)
            try "config-file = included.conf".write(to: source, atomically: true, encoding: .utf8)
            #expect(Ghostty.Config(handle: store.load(cli: false)).title == "Included")
            #expect(Ghostty.Config(handle: store.load(cli: false)).title == "Included")
            #expect(store.usedSavedInput)
            try "title = Changed reference".write(to: included, atomically: true, encoding: .utf8)
            #expect(Ghostty.Config(handle: store.load(cli: false)).title == "Changed reference")
        }
    }

    @Test func failedResetCommitRestoresOriginalUserFile() throws {
        try withStore { store, source in
            let original = "title = Keep Me"
            try original.write(to: source, atomically: true, encoding: .utf8)
            let blockedRecord = store.directory.appendingPathComponent("last-success.json")
            try FileManager.default.createDirectory(at: blockedRecord, withIntermediateDirectories: true)
            #expect(throws: (any Error).self) { try store.restoreDefaults() }
            #expect(try String(contentsOf: source, encoding: .utf8) == original)
        }
    }

    @Test func directoryAtUserPathRestoresSuccessfulFile() throws {
        try withStore { store, source in
            try "title = Good".write(to: source, atomically: true, encoding: .utf8)
            _ = store.load(cli: false)
            try FileManager.default.removeItem(at: source)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            let config = Ghostty.Config(handle: store.load(cli: false))
            #expect(config.title == "Good")
            #expect(!config.errors.isEmpty)
        }
    }
}
