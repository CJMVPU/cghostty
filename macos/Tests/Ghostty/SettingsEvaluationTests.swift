import Foundation
import Testing
@testable import Ghostty

@MainActor struct SettingsEvaluationTests {
    @Test func evaluationKeepsBothDecodedThemeBranches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let light = root.appendingPathComponent("light")
        let dark = root.appendingPathComponent("dark")
        try "background = #123456\n".write(to: light, atomically: true, encoding: .utf8)
        try "background = #654321\n".write(to: dark, atomically: true, encoding: .utf8)
        let store = SettingsStore(legacySource: root.appendingPathComponent("legacy"), directory: root)
        let input = SettingsStore.Input(values: ["theme": "light:\(light.path),dark:\(dark.path)"])
        Ghostty.ConfigHandle.formattedEntryCallsForTesting = 0
        let evaluation = store.evaluate(input)
        #expect(evaluation.diagnostics.isEmpty)
        #expect(evaluation.values["background"] == "#123456")
        #expect(evaluation.darkValues["background"] == "#654321")
        #expect(Ghostty.ConfigHandle.formattedEntryCallsForTesting == 2 * SettingsField.catalog.count)
    }

    @Test func measureValidatedLargeDraftDecoding() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SettingsStore(legacySource: root.appendingPathComponent("legacy"), directory: root)
        let input = SettingsStore.Input(values: ["env": (0..<1000).map { "KEY\($0)=value" }.joined(separator: "\n")])
        var samples: [Double] = []
        var calls: [Int] = []
        for _ in 0..<10 {
            Ghostty.ConfigHandle.formattedEntryCallsForTesting = 0
            let start = ContinuousClock.now
            let evaluation = store.evaluate(input)
            #expect(evaluation.values["env"]?.components(separatedBy: "\n").count == 1000)
            let duration = start.duration(to: .now).components
            samples.append(Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)
            calls.append(Ghostty.ConfigHandle.formattedEntryCallsForTesting)
            #expect(evaluation.diagnostics.isEmpty)
        }
        print("SETTINGS_EVALUATION_METRIC entries=1000 samples=10 calls=\(calls) median_ms=\(samples.sorted()[5]) max_ms=\(samples.max() ?? 0)")
    }

    @Test func modelDecodesEachValidatedBranchOnlyOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SettingsStore(legacySource: root.appendingPathComponent("legacy"), directory: root)
        _ = try #require(store.load(cli: false))
        let model = SettingsModel(store: store)
        let field = try #require(SettingsField.byKey["font-size"])
        Ghostty.ConfigHandle.formattedEntryCallsForTesting = 0
        model.edit(field, value: "19")
        #expect(model.diagnostics.isEmpty)
        #expect(model.effectiveValues["font-size"] == "19")
        #expect(Ghostty.ConfigHandle.formattedEntryCallsForTesting == 2 * SettingsField.catalog.count)
        Ghostty.ConfigHandle.formattedEntryCallsForTesting = 0
        model.edit(field, value: model.savedValues[field.key]!)
        #expect(!model.dirty)
        #expect(Ghostty.ConfigHandle.formattedEntryCallsForTesting == 4 * SettingsField.catalog.count)
    }
}
