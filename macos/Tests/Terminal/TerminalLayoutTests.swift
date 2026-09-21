import AppKit
import Testing
@testable import Ghostty

@MainActor struct TerminalLayoutTests {
    private let firstID = UUID(uuidString: "A582E508-5958-4A30-A217-1DDE607393BE")!
    private let secondID = UUID(uuidString: "B582E508-5958-4A30-A217-1DDE607393BE")!

    /// Match the old SurfaceView / SplitTree wire format, not the new encoder.
    private func legacyLayout() throws -> TerminalLayout<SurfaceSnapshot> {
        let json = """
        {"version":1,"root":{"split":{
          "direction":{"vertical":{}},"ratio":0.35,
          "left":{"view":{"uuid":"\(firstID)","pwd":"/tmp"}},
          "right":{"view":{"uuid":"\(secondID)","pwd":"/tmp",
            "title":"Saved terminal","isUserSetTitle":true}}
        }},"zoomed":{"path":[{"right":{}}]}}
        """
        return try JSONDecoder().decode(TerminalLayout<SurfaceSnapshot>.self, from: Data(json.utf8))
    }

    @Test func legacyLayoutDecodesWithoutCreatingWindowsOrSessions() throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let windowCount = NSApp.windows.count
        let state = try legacyLayout()
        #expect(state.leaves.map(\.id) == [firstID, secondID])
        #expect(state.leaves[0].title == nil)
        #expect(!state.leaves[0].isUserSetTitle)
        #expect(state.leaves[1].isUserSetTitle)
        #expect(app.windowRegistry.registeredControllers.isEmpty)
        #expect(NSApp.windows.count == windowCount)
        let encoded = try JSONEncoder().encode(state)
        let again = try JSONDecoder().decode(TerminalLayout<SurfaceSnapshot>.self, from: encoded)
        #expect(again.leaves.map(\.id) == [firstID, secondID])
    }

    @Test func restorationUsesExplicitAppAndPreservesLayoutAndTitle() throws {
        let app = Ghostty.App(configPath: "/dev/null")
        var base = Ghostty.SurfaceConfiguration()
        base.command = "/bin/zsh -f"
        let state = try legacyLayout()
        let tree = state.restore { $0.makeView(in: app, baseConfig: base) }
        #expect(tree.count == 2)
        #expect(tree.allSatisfy { $0.windowRegistry === app.windowRegistry })
        #expect(tree.allSatisfy { $0.surfaceModel != nil })
        guard case .split(let split) = tree.root else { Issue.record("Missing restored split"); return }
        #expect(split.direction == .vertical)
        #expect(split.ratio == 0.35)
        guard case .leaf(let focused) = tree.zoomed else { Issue.record("Missing zoomed leaf"); return }
        #expect(focused.id == secondID)
        #expect(focused.title == "Saved terminal")
        #expect(focused.titleFromTerminal == "Saved terminal")
    }

    @Test func savedSnapshotDoesNotRetainNativeView() async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        var base = Ghostty.SurfaceConfiguration()
        base.command = "/bin/zsh -f"
        base.workingDirectory = FileManager.default.temporaryDirectory.path
        var view: Ghostty.SurfaceView? = Ghostty.SurfaceView(app, baseConfig: base)
        weak let original = view
        let snapshot = SurfaceSnapshot(try #require(view))
        let id = try #require(view?.id)
        view = nil
        // Let the view finish initialization work already queued on the main loop.
        let deadline = ContinuousClock.now + .seconds(2)
        while original != nil && ContinuousClock.now < deadline {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        #expect(original == nil)
        #expect(snapshot.id == id)
    }

    @Test func quickTerminalBaseEnvironmentReachesRestoredProcess() async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let state = try legacyLayout()
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/usr/bin/printenv GHOSTTY_QUICK_TERMINAL"
        config.environmentVariables["GHOSTTY_QUICK_TERMINAL"] = "restored-quick-terminal"
        let view = state.leaves[0].makeView(in: app, baseConfig: config)
        let surface = try #require(view.surfaceModel)
        let deadline = ContinuousClock.now + .seconds(5)
        while !surface.readContents(viewport: false).contains("restored-quick-terminal") {
            try #require(ContinuousClock.now < deadline, "Restored process did not receive its environment")
            await Task.yield()
        }
    }

    @Test func actualWindowArchivesRoundTripAsValuesOnly() throws {
        let layout = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacyLayout()))
        let normalData = try JSONSerialization.data(withJSONObject: [
            "focusedSurface": secondID.uuidString, "surfaceTree": layout, "titleOverride": "Saved tab"
        ])
        let normal = try JSONDecoder().decode(TerminalRestorableState.self, from: normalData)
        #expect(normal.focusedSurface == secondID.uuidString)
        #expect(normal.titleOverride == "Saved tab")
        let normalArchive = try NSKeyedArchiver.archivedData(withRootObject: CodableBridge(normal), requiringSecureCoding: true)
        let normalAgain = try #require(try NSKeyedUnarchiver.unarchivedObject(
            ofClass: CodableBridge<TerminalRestorableState>.self, from: normalArchive)).value
        #expect(normalAgain.surfaceTree.leaves.map(\.id) == [firstID, secondID])

        let quickData = try JSONSerialization.data(withJSONObject: ["internalState": [
            "focusedSurface": firstID.uuidString, "surfaceTree": layout, "screenStateEntries": []
        ]])
        let quick = try JSONDecoder().decode(QuickTerminalRestorableState.self, from: quickData)
        let quickArchive = try NSKeyedArchiver.archivedData(withRootObject: CodableBridge(quick), requiringSecureCoding: true)
        let quickAgain = try #require(try NSKeyedUnarchiver.unarchivedObject(
            ofClass: CodableBridge<QuickTerminalRestorableState>.self, from: quickArchive)).value
        #expect(quickAgain.focusedSurface == firstID.uuidString)
        #expect(quickAgain.surfaceTree.leaves.map(\.id) == [firstID, secondID])
        #expect(quickAgain.baseConfig?.environmentVariables["GHOSTTY_QUICK_TERMINAL"] == "1")
    }

    @Test func unsupportedLayoutVersionFailsBeforeMaterialization() {
        let data = Data(#"{"version":999}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TerminalLayout<SurfaceSnapshot>.self, from: data)
        }
    }
}
