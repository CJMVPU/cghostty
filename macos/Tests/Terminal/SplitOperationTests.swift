import AppKit
import Testing
@testable import Ghostty

@MainActor struct SplitOperationTests {
    private func terminal(_ app: Ghostty.App) -> TerminalController {
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/zsh -f"
        config.workingDirectory = FileManager.default.temporaryDirectory.path
        return TerminalController(app, withBaseConfig: config)
    }

    @Test func movingLastSplitAcrossWindowsCanUndoAndRedoWithoutReplacingTheSession() async throws {
        let config = try TemporaryConfig("confirm-close-surface = false\nundo-timeout = 30s")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let source = terminal(app)
        let destination = terminal(app)
        _ = try #require(source.window)
        _ = try #require(destination.window)
        defer {
            app.undoManager.removeAllActions()
            app.windowRegistry.all.forEach { $0.window?.close() }
        }
        let moved = try #require(source.surfaceTree.first)
        let target = try #require(destination.surfaceTree.first)
        let session = try #require(moved.surfaceModel)
        let undo = app.undoManager
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        destination.performSplitAction(.drop(.init(payload: moved, destination: target, zone: .right)))
        undo.endUndoGrouping()
        #expect(app.windowRegistry.owner(of: moved) === destination)
        #expect(app.windowRegistry.all.count == 1)
        #expect(undo.canUndo)
        undo.undo()
        let restored = try #require(app.windowRegistry.owner(of: moved))
        #expect(restored !== destination)
        #expect(app.windowRegistry.all.count == 2)
        #expect(!destination.surfaceTree.contains(moved))
        #expect(moved.surfaceModel === session)
        #expect(undo.canRedo)
        undo.redo()
        #expect(app.windowRegistry.owner(of: moved) === destination)
        #expect(app.windowRegistry.all.count == 1)
        #expect(moved.surfaceModel === session)
        await drainMainQueue()
        #expect(app.windowRegistry.owner(of: moved) === destination)
    }

    @Test func dropCannotMoveASurfaceFromAnotherApp() throws {
        let first = Ghostty.App(configPath: "/dev/null")
        let second = Ghostty.App(configPath: "/dev/null")
        let source = terminal(first)
        let destination = terminal(second)
        defer { source.window?.close(); destination.window?.close() }
        let moved = try #require(source.surfaceTree.first)
        let target = try #require(destination.surfaceTree.first)
        destination.performSplitAction(.drop(.init(payload: moved, destination: target, zone: .left)))
        #expect(first.windowRegistry.owner(of: moved) === source)
        #expect(!destination.surfaceTree.contains(moved))
        #expect(!second.undoManager.canUndo)
    }

    @Test func closeUndoAndRedoKeepTheSameSurface() throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let controller = terminal(app)
        let first = try #require(controller.surfaceTree.first)
        app.undoManager.disableUndoRegistration()
        let second = try #require(controller.newSplit(at: first, direction: .right))
        app.undoManager.enableUndoRegistration()
        let core = second.surfaceModel
        defer { app.undoManager.removeAllActions(); controller.window?.close() }
        app.undoManager.groupsByEvent = false
        app.undoManager.beginUndoGrouping()
        controller.closeSurface(second, withConfirmation: false)
        app.undoManager.endUndoGrouping()
        #expect(!controller.surfaceTree.contains(second))
        app.undoManager.undo()
        #expect(controller.surfaceTree.contains(second))
        #expect(second.surfaceModel === core)
        app.undoManager.redo()
        #expect(!controller.surfaceTree.contains(second))
    }

    private func drainMainQueue() async {
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}
