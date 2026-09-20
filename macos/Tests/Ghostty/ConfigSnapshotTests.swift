import AppKit
import Observation
import SwiftUI
import Synchronization
import Testing
@testable import Ghostty

@MainActor struct ConfigSnapshotTests {
    @Test(arguments: [UInt32(0), 1, 250, 2_500, UInt32.max])
    func abnormalExitRuntimeUsesIntegerStorage(_ milliseconds: UInt32) throws {
        let config = try TemporaryConfig("abnormal-command-exit-runtime = \(milliseconds)")
        #expect(config.errors.isEmpty)
        #expect(config.snapshot.abnormalCommandExitRuntime == .milliseconds(milliseconds))
        try config.reload("abnormal-command-exit-runtime = 0")
        #expect(config.snapshot.abnormalCommandExitRuntime == .zero)
    }

    @Test func snapshotOwnsStringsCommandsAndDiagnosticsAfterReloadAndRelease() async throws {
        var config: TemporaryConfig? = try TemporaryConfig("""
        title = 配置第一代
        window-title-font-family = Snapshot Font
        background = #123456
        background-opacity = 0.4
        quick-terminal-size = 45%,70%
        command-palette-entry = clear
        command-palette-entry = title:测试命令,description:独立字符串,action:goto_split:right
        nonexistent-snapshot-key = true
        """)
        let before = config!.snapshot
        try config!.reload("title = Second generation\nbackground-opacity = 0.8")
        let after = config!.snapshot
        config = nil

        // Crossing actors verifies that the value contains no live core/UI resource.
        let detached = await Task.detached { before }.value
        #expect(detached.title == "配置第一代")
        #expect(detached.window.titleFontFamily == "Snapshot Font")
        #expect(detached.backgroundColor == Color(red: 0x12 / 255.0, green: 0x34 / 255.0, blue: 0x56 / 255.0))
        #expect(detached.backgroundOpacity == 0.4)
        #expect(detached.commandPaletteEntries.count == 1)
        let command = try #require(detached.commandPaletteEntries.first)
        #expect(command.title == "测试命令")
        #expect(command.description == "独立字符串")
        #expect(command.action == "goto_split:right")
        #expect(detached.errors.contains { $0.contains("nonexistent-snapshot-key") })
        #expect(detached.quickTerminalSize.calculate(position: .top,
                                                    screenDimensions: CGSize(width: 1000, height: 1000)) ==
                CGSize(width: 700, height: 450))
        #expect(after.title == "Second generation")
        #expect(after.backgroundOpacity == 0.8)
        #expect(after.errors.isEmpty)
    }

    @Test func replacingConfigReleasesOldHandleEvenWhileSnapshotLives() throws {
        var handle = Ghostty.ConfigHandle.load(at: "/dev/null", finalize: true)
        try #require(handle != nil)
        weak let oldHandle = handle
        let config = Ghostty.Config(handle: handle)
        let snapshot = config.snapshot
        handle = nil
        #expect(oldHandle != nil)
        config.replace(with: try #require(Ghostty.ConfigHandle.load(at: "/dev/null", finalize: true)))
        #expect(oldHandle == nil)
        #expect(snapshot.loaded)
        #expect(!snapshot.commandPaletteEntries.isEmpty)
    }

    @Test func clonedConfigKeepsItsOwnHandleAndBindings() throws {
        var source: TemporaryConfig? = try TemporaryConfig("title = Original\nkeybind = clear\nkeybind = cmd+k=new_window")
        let clone = Ghostty.Config(clone: try #require(source?.config))
        #expect(clone.config != source?.config)
        try source?.reload("title = Replacement\nkeybind = clear\nkeybind = cmd+j=new_window")
        source = nil
        #expect(clone.snapshot.title == "Original")
        #expect(clone.keyboardShortcut(for: "new_window") == .init("k", modifiers: .command))
    }

    @Test func unloadedSnapshotPreservesFallbacks() {
        let config = Ghostty.Config(handle: nil)
        let snapshot = config.snapshot
        #expect(!snapshot.loaded)
        #expect(snapshot.errors.isEmpty)
        #expect(snapshot.title == nil)
        #expect(snapshot.commandPaletteEntries.isEmpty)
        #expect(snapshot.backgroundOpacity == 1)
        #expect(snapshot.window.stepResize)
        #expect(snapshot.window.maximize)
        #expect(config.keyboardShortcut(for: "new_window") == nil)
    }

    @Test func replacementInvalidatesObservationOnceForTheWholeGeneration() throws {
        let config = try TemporaryConfig("title = Before\nbackground-opacity = 0.3")
        let changes = Mutex(0)
        withObservationTracking {
            _ = config.snapshot.title
            _ = config.backgroundOpacity
            _ = config.window.titleFontFamily
        } onChange: {
            changes.withLock { $0 += 1 }
        }
        try config.reload("title = After\nbackground-opacity = 0.7\nwindow-title-font-family = After Font")
        #expect(changes.withLock { $0 } == 1)
        #expect(config.snapshot.title == "After")
        #expect(config.backgroundOpacity == 0.7)
        #expect(config.window.titleFontFamily == "After Font")
    }

    @Test func appPublishesConfigBeforeSynchronousNotification() throws {
        let file = try TemporaryConfig("title = Before")
        let app = Ghostty.App(configPath: file.temporaryFile.path)
        let observed = Mutex<[Bool]>([])
        let configKey = Notification.Name.GhosttyConfigChangeKey
        let token = NotificationCenter.default.addObserver(forName: .ghosttyConfigDidChange, object: nil, queue: nil) { notification in
            guard notification.object == nil,
                  let delivered = notification.userInfo?[configKey] as? Ghostty.Config else { return }
            MainActor.assumeIsolated {
                observed.withLock { $0.append(app.config === delivered && app.config.snapshot.title == "After") }
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        try file.reload("title = After")
        app.reloadConfig()
        #expect(!observed.withLock { $0 }.isEmpty)
        #expect(observed.withLock { $0 }.allSatisfy { $0 })
        #expect(app.config.snapshot.title == "After")
    }
}
