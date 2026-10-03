import AppKit
import Testing
@testable import Ghostty

@MainActor struct ControllerCloseTransactionTests {
    private func terminal(_ app: Ghostty.App) -> TerminalController {
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/zsh -f"
        config.workingDirectory = FileManager.default.temporaryDirectory.path
        return TerminalController(app, withBaseConfig: config)
    }

    @Test func wholeWindowRestoresFourTabsInOrderAndRedoPreservesNewSibling() throws {
        let config = try TemporaryConfig("confirm-close-surface = false\nundo-timeout = 30s")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let controllers = (0..<4).map { _ in terminal(app) }
        let windows = try controllers.map { try #require($0.window) }
        for index in 1..<windows.count { windows[index - 1].addTabbedWindow(windows[index], ordered: .above) }
        let ids = try #require(windows[0].tabGroup).windows.compactMap {
            ($0.windowController as? TerminalController)?.surfaceTree.first?.id
        }
        let undo = app.undoManager
        undo.removeAllActions()
        undo.groupsByEvent = false
        defer { undo.removeAllActions(); app.windowRegistry.all.forEach { $0.window?.close() } }
        undo.beginUndoGrouping()
        controllers[0].closeWindowImmediately()
        undo.endUndoGrouping()
        #expect(app.windowRegistry.all.isEmpty)
        undo.undo()
        let firstID = try #require(ids.first)
        let restoredSurface = try #require(app.windowRegistry.surface(id: firstID))
        let restored = try #require(app.windowRegistry.owner(of: restoredSurface) as? TerminalController)
        let restoredWindow = try #require(restored.window)
        let restoredIDs = try #require(restoredWindow.tabGroup).windows.compactMap {
            ($0.windowController as? TerminalController)?.surfaceTree.first?.id
        }
        #expect(restoredIDs == ids)
        let newcomer = terminal(app)
        let newcomerSurface = try #require(newcomer.surfaceTree.first)
        restoredWindow.addTabbedWindow(try #require(newcomer.window), ordered: .above)
        undo.redo()
        #expect(app.windowRegistry.all.count == 1)
        #expect(app.windowRegistry.surface(id: newcomerSurface.id) === newcomerSurface)
        for id in ids { #expect(app.windowRegistry.surface(id: id) == nil) }
        undo.undo()
        #expect(app.windowRegistry.all.count == 5)
        for id in ids { #expect(app.windowRegistry.surface(id: id) != nil) }
        undo.redo()
        #expect(app.windowRegistry.all.count == 1)
        #expect(app.windowRegistry.surface(id: newcomerSurface.id) === newcomerSurface)
    }

    @Test(arguments: TerminalController.TabCloseScope.allCases)
    func batchRedoClosesRestoredIdentitiesAfterOriginalTabsMove(scope: TerminalController.TabCloseScope) throws {
        let config = try TemporaryConfig("confirm-close-surface = false\nundo-timeout = 30s")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let controllers = (0..<4).map { _ in terminal(app) }
        let windows = try controllers.map { try #require($0.window) }
        for index in 1..<windows.count { windows[index - 1].addTabbedWindow(windows[index], ordered: .above) }
        let group = try #require(windows[0].tabGroup)
        let ordered = try group.windows.map { try #require($0.windowController as? TerminalController) }
        let anchor = ordered[1]
        let anchorSurface = try #require(anchor.surfaceTree.first)
        let closing = scope == .others ? [ordered[0], ordered[2], ordered[3]] : [ordered[2], ordered[3]]
        let closingIDs = try closing.map { try #require($0.surfaceTree.first?.id) }
        let undo = app.undoManager
        undo.removeAllActions()
        undo.groupsByEvent = false
        defer { undo.removeAllActions(); app.windowRegistry.all.forEach { $0.window?.close() } }
        undo.beginUndoGrouping()
        anchor.closeTabsImmediately(scope)
        undo.endUndoGrouping()
        undo.undo()
        let newcomer = terminal(app)
        let newcomerSurface = try #require(newcomer.surfaceTree.first)
        let newcomerWindow = try #require(newcomer.window)
        let anchorWindow = try #require(anchor.window)
        anchorWindow.addTabbedWindow(newcomerWindow, ordered: .above)
        let movedID = try #require(closingIDs.first)
        let movedSurface = try #require(app.windowRegistry.surface(id: movedID))
        let moved = try #require(app.windowRegistry.owner(of: movedSurface) as? TerminalController)
        let movedWindow = try #require(moved.window)
        movedWindow.tabGroup?.removeWindow(movedWindow)
        undo.redo()
        #expect(app.windowRegistry.surface(id: anchorSurface.id) === anchorSurface)
        #expect(app.windowRegistry.surface(id: newcomerSurface.id) === newcomerSurface)
        for id in closingIDs { #expect(app.windowRegistry.surface(id: id) == nil) }
    }
}
