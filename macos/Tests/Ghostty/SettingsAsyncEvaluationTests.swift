import AppKit
import Foundation
import Synchronization
import Testing
@testable import Ghostty

@Suite(.serialized)
@MainActor struct SettingsAsyncEvaluationTests {
    private func withStore(_ body: (SettingsStore, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SettingsStore(legacySource: root.appendingPathComponent("legacy"), directory: root)
        _ = try #require(store.load(cli: false))
        try await body(store, root)
    }

    @Test func backgroundProjectionMatchesSynchronousThemesAndDiagnostics() async throws {
        try await withStore { store, root in
            let light = root.appendingPathComponent("light")
            let dark = root.appendingPathComponent("dark")
            try "background = #123456\n".write(to: light, atomically: true, encoding: .utf8)
            try "background = #654321\n".write(to: dark, atomically: true, encoding: .utf8)
            for input in [
                SettingsStore.Input(values: ["theme": "light:\(light.path),dark:\(dark.path)"]),
                SettingsStore.Input(values: ["font-size": "nan", "unknown-setting": "true"]),
                SettingsStore.Input(layers: [.init(text: "background = invalid\n", source: light)])
            ] {
                let expected = store.evaluate(input)
                let actual = try await store.evaluateAsync(input)
                #expect(actual.values == expected.values)
                #expect(actual.darkValues == expected.darkValues)
                #expect(actual.diagnostics == expected.diagnostics)
            }
        }
    }

    @Test func workerOwnsAllCoreParsingAndCancellationCannotCommit() async throws {
        try await withStore { store, _ in
            let input = SettingsStore.Input(values: ["env": (0..<1000).map { "KEY\($0)=value" }.joined(separator: "\n")])
            Ghostty.ConfigHandle.settingsLoadCallsForTesting = 0
            Ghostty.ConfigHandle.formattedEntryCallsForTesting = 0
            store.beforeEvaluationForTesting = { #expect(!Thread.isMainThread) }
            let projection = try await store.evaluateAsync(input)
            #expect(projection.values["env"]?.components(separatedBy: "\n").count == 1000)
            #expect(projection.diagnostics.isEmpty)
            #expect(Ghostty.ConfigHandle.settingsLoadCallsForTesting == 0)
            #expect(Ghostty.ConfigHandle.formattedEntryCallsForTesting == 0)
            let record = try store.read()
            let bytes = try Data(contentsOf: store.url)
            let cancelled = Task { try await store.saveEvaluatedAsync(input, revision: record.revision) }
            cancelled.cancel()
            do { _ = try await cancelled.value; Issue.record("Cancelled preparation unexpectedly committed") } catch is CancellationError {}
            #expect(try Data(contentsOf: store.url) == bytes)
        }
    }

    @Test func preparedSaveRechecksRevisionAndPreservesLastValidInput() async throws {
        try await withStore { store, _ in
            let original = try store.read()
            let first = try await store.prepareSaveAsync(.init(values: ["title": "prepared"]), revision: original.revision)
            #expect(first.record.previous == original.current)
            _ = try store.save(.init(values: ["title": "competing"]), revision: original.revision)
            do { try await store.commitPreparedAsync(first); Issue.record("Stale prepared save committed") } catch SettingsStore.Failure.changed {}
            #expect(try store.read().current.values["title"] == "competing")
            let old = try store.read()
            let broken = SettingsStore.Record(current: .init(values: ["font-size": "nan"]), previous: old.current)
            try SettingsStore.Disk(directory: store.directory).write(broken)
            let recovered = try await store.saveEvaluatedAsync(.init(values: ["title": "fixed"]), revision: broken.revision)
            #expect(recovered.record.previous == old.current)
            #expect(recovered.evaluation.values["title"] == "fixed")
        }
    }

    @Test func blockedParserKeepsMainActorAvailableAndAcceptsCancellation() async throws {
        try await withStore { store, _ in
            let entered = Mutex(false)
            let release = DispatchSemaphore(value: 0)
            store.beforeEvaluationForTesting = {
                #expect(!Thread.isMainThread)
                entered.withLock { $0 = true }
                #expect(release.wait(timeout: .now() + 5) == .success)
            }
            defer { release.signal() }
            let parsing = Task { try await store.evaluateAsync(.init(values: ["title": "cancelled"])) }
            try await NativeTestWait.until("background parser entered", timeout: .seconds(3), polling: .milliseconds(1),
                                          diagnostics: { "workerEntered=\(entered.withLock { $0 })" }, { entered.withLock { $0 } })
            // This MainActor continuation executes while the worker is blocked.
            parsing.cancel()
            release.signal()
            do { _ = try await parsing.value; Issue.record("Cancelled projection was published") } catch is CancellationError {}
        }
    }

    @Test func olderDraftCannotPublishAfterNewEditOrReload() async throws {
        try await withStore { store, _ in
            let model = SettingsModel(store: store)
            let title = try #require(SettingsField.byKey["title"])
            for reload in [false, true] {
                let entered = Mutex(false)
                let release = DispatchSemaphore(value: 0)
                store.beforeEvaluationForTesting = {
                    entered.withLock { $0 = true }
                    #expect(release.wait(timeout: .now() + 5) == .success)
                }
                defer { release.signal() }
                model.edit(title, value: "Old draft", deferred: true)
                let old = Task { await model.flushValidationAsync() }
                try await NativeTestWait.until("old draft parser entered", timeout: .seconds(3), polling: .milliseconds(1),
                                              diagnostics: { model.status }, { entered.withLock { $0 } })
                store.beforeEvaluationForTesting = nil
                if reload {
                    #expect(await model.reloadAsync())
                } else {
                    model.edit(title, value: "New draft", deferred: true)
                    #expect(await model.flushValidationAsync())
                }
                let expected = model.displayed
                let expectedInput = model.input
                release.signal()
                // This task was superseded but never cancelled: the revision
                // check itself must prevent it from replacing the newer state.
                #expect(await old.value == false)
                #expect(model.input == expectedInput)
                #expect(model.displayed == expected)
                #expect(model.validation == .valid)
            }
        }
    }

    @Test func asyncEditsRestoreInheritanceAndKeepExplicitDependentValues() async throws {
        try await withStore { store, root in
            let model = SettingsModel(store: store)
            let size = try #require(SettingsField.byKey["font-size"])
            let originalSize = try #require(model.displayed[size.key])
            Ghostty.ConfigHandle.settingsLoadCallsForTesting = 0
            model.edit(size, value: "19", deferred: true)
            model.edit(size, value: originalSize, deferred: true)
            #expect(await model.flushValidationAsync())
            #expect(!model.dirty && model.input.values[size.key] == nil)
            model.edit(size, value: "19", deferred: true)
            model.edit(size, value: originalSize, deferred: true)
            // Saving directly during debounce must normalize inheritance too.
            #expect(await model.saveAsync())
            #expect(try store.read().current.values[size.key] == nil)
            let foreground = try #require(SettingsField.byKey["foreground"])
            let originalForeground = try #require(model.displayed[foreground.key])
            let theme = root.appendingPathComponent("theme")
            try "foreground = #123456\n".write(to: theme, atomically: true, encoding: .utf8)
            model.edit(try #require(SettingsField.byKey["theme"]), value: theme.path, deferred: true)
            model.edit(foreground, value: originalForeground, deferred: true)
            #expect(await model.flushValidationAsync())
            #expect(model.input.values[foreground.key] == originalForeground)
            #expect(model.effectiveValues[foreground.key] == originalForeground)
            #expect(Ghostty.ConfigHandle.settingsLoadCallsForTesting == 0)
        }
    }

    @Test func pendingCloseCoalescesAndWaitsForCurrentValidation() async throws {
        try await withStore { store, _ in
            let controller = SettingsController(store: store)
            defer { controller.window?.close() }
            let model = controller.model
            try await NativeTestWait.until("settings loaded", timeout: .seconds(3), polling: .milliseconds(1),
                                          diagnostics: { model.status }, { model.record != nil && !model.isBusy })
            let entered = Mutex(false)
            let release = DispatchSemaphore(value: 0)
            store.beforeEvaluationForTesting = {
                entered.withLock { $0 = true }
                #expect(release.wait(timeout: .now() + 5) == .success)
            }
            defer { release.signal() }
            model.edit(try #require(SettingsField.byKey["title"]), value: "Pending close", deferred: true)
            var prompts = 0
            let respond: (NSAlert) -> NSApplication.ModalResponse = { alert in
                #expect(alert.buttons[0].isEnabled)
                prompts += 1
                return .alertThirdButtonReturn
            }
            #expect(!controller.confirmClose(runModal: respond, afterSave: { Issue.record("Keep Editing closed the window") }))
            try await NativeTestWait.until("close parser entered", timeout: .seconds(3), polling: .milliseconds(1),
                                          diagnostics: { model.status }, { entered.withLock { $0 } })
            #expect(prompts == 0)
            #expect(!controller.confirmClose(runModal: respond, afterSave: { Issue.record("Duplicate close continued") }))
            release.signal()
            try await NativeTestWait.until("close prompt", timeout: .seconds(3), polling: .milliseconds(1),
                                          diagnostics: { model.status }, { prompts == 1 })
            #expect(model.dirty && model.canSave)
        }
    }

    @Test func measureBackgroundLargeDraftProjection() async throws {
        try await withStore { store, _ in
            let input = SettingsStore.Input(values: ["env": (0..<1000).map { "KEY\($0)=value" }.joined(separator: "\n")])
            var samples: [Double] = []
            for _ in 0..<10 {
                let start = ContinuousClock.now
                let projection = try await store.evaluateAsync(input)
                let duration = start.duration(to: .now).components
                samples.append(Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)
                #expect(projection.diagnostics.isEmpty)
            }
            print("SETTINGS_BACKGROUND_METRIC entries=1000 samples=10 median_ms=\(samples.sorted()[5]) max_ms=\(samples.max() ?? 0)")
        }
    }
}
