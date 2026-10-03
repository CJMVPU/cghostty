import AppKit
import Testing
@testable import Ghostty

@MainActor struct ControllerUndoStateTests {
    @Test func closeUndoPreservesTitleOpacityAndNonrestorableCommandWindow() throws {
        let config = try TemporaryConfig("confirm-close-surface = false\nundo-timeout = 30s\nbackground-opacity = 0.7")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        var surfaceConfig = Ghostty.SurfaceConfiguration()
        surfaceConfig.command = "/bin/zsh -f"
        surfaceConfig.workingDirectory = FileManager.default.temporaryDirectory.path
        let controller = TerminalController(app, withBaseConfig: surfaceConfig)
        let window = try #require(controller.window)
        let surface = try #require(controller.surfaceTree.first)
        controller.titleOverride = "Saved command tab"
        controller.isBackgroundOpaque = true
        controller.syncAppearance()
        #expect(!window.isRestorable)
        let undo = app.undoManager
        undo.groupsByEvent = false
        defer { undo.removeAllActions(); app.windowRegistry.all.forEach { $0.window?.close() } }
        undo.beginUndoGrouping()
        controller.closeWindowImmediately()
        undo.endUndoGrouping()
        for _ in 0..<2 {
            undo.undo()
            let restored = try #require(app.windowRegistry.owner(of: surface) as? TerminalController)
            let restoredWindow = try #require(restored.window)
            #expect(restored.titleOverride == "Saved command tab")
            #expect(restored.isBackgroundOpaque)
            #expect(restoredWindow.title == "Saved command tab")
            #expect(!restoredWindow.isRestorable)
            undo.redo()
        }
    }
}
