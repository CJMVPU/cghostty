import AppKit
import Testing
@testable import Ghostty

@MainActor struct DetachUndoTests {
    @Test func repeatedDetachUndoKeepsOneOwnerWithoutAsynchronousConfirmation() async throws {
        let config = try TemporaryConfig("confirm-close-surface = true\nundo-timeout = 30s")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        var surfaceConfig = Ghostty.SurfaceConfiguration()
        surfaceConfig.command = "/bin/sleep 30"
        surfaceConfig.workingDirectory = FileManager.default.temporaryDirectory.path
        let source = TerminalController(app, withBaseConfig: surfaceConfig)
        _ = try #require(source.window)
        let first = try #require(source.surfaceTree.first)
        app.undoManager.disableUndoRegistration()
        let moved = try #require(source.newSplit(at: first, direction: .right, baseConfig: surfaceConfig))
        app.undoManager.enableUndoRegistration()
        let session = try #require(moved.surfaceModel)
        let manager = app.undoManager
        manager.removeAllActions()
        manager.groupsByEvent = false
        defer { manager.removeAllActions(); app.windowRegistry.all.forEach { $0.window?.close() } }
        try await NativeTestWait.until("sleep requires close confirmation", timeout: .seconds(3), polling: .milliseconds(5),
                                       diagnostics: { "confirm=\(moved.needsConfirmQuit)" }, { moved.needsConfirmQuit })
        source.detachSplit(moved, at: .init(x: 200, y: 200))
        for _ in 0..<3 {
            manager.undo()
            #expect(manager.pendingApproval == nil)
            #expect(app.windowRegistry.owner(of: moved) === source)
            #expect(app.windowRegistry.all.count == 1)
            #expect(source.surfaceTree.contains(moved))
            #expect(moved.surfaceModel === session)
            manager.redo()
            let detached = try #require(app.windowRegistry.owner(of: moved))
            #expect(detached !== source)
            #expect(!source.surfaceTree.contains(moved))
            #expect(app.windowRegistry.all.count == 2)
            #expect(moved.surfaceModel === session)
        }
    }
}
