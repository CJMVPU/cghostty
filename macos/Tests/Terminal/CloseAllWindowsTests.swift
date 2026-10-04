import AppKit
import Testing
@testable import Ghostty

@MainActor struct CloseAllWindowsTests {
    private final class ConfirmationController: TerminalController {
        var onConfirmation: (@MainActor (NSAlert) async -> NSApplication.ModalResponse)?

        override func presentCloseConfirmation(_ alert: NSAlert, for window: NSWindow) async -> NSApplication.ModalResponse {
            guard let onConfirmation else { return .alertSecondButtonReturn }
            return await onConfirmation(alert)
        }
    }

    private func terminal(_ app: Ghostty.App) -> TerminalController {
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/cat"
        config.workingDirectory = FileManager.default.temporaryDirectory.path
        return TerminalController(app, withBaseConfig: config)
    }

    private func isOpen(_ controller: BaseTerminalController) -> Bool {
        controller.ghostty.windowRegistry.registeredControllers.contains { $0 === controller }
    }

    @Test func approvalKeepsNewWindowsAndTabsAndIncludesOriginalIdleTabs() async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let first = terminal(app)
        let idle = terminal(app)
        let firstWindow = try #require(first.window)
        firstWindow.addTabbedWindow(try #require(idle.window), ordered: .above)
        var newcomers: [TerminalController] = []
        defer {
            (newcomers + [first, idle]).forEach { $0.window?.close() }
            app.undoManager.removeAllActions()
        }
        let task = try #require(TerminalController.startCloseAllWindows(
            app,
            needsConfirmation: { $0 === first },
            confirm: { controller in
                #expect(controller === first)
                let newTab = terminal(app)
                let newWindow = terminal(app)
                newcomers = [newTab, newWindow]
                guard let tabWindow = newTab.window else {
                    Issue.record("New tab must have a window")
                    return .cancelled
                }
                firstWindow.addTabbedWindow(tabWindow, ordered: .above)
                return .allowed
            }
        ))
        await task.value
        #expect(!isOpen(first) && !isOpen(idle))
        #expect(newcomers.allSatisfy(isOpen))
    }

    @Test func movedAndExternallyClosedTargetsDoNotExpandApproval() async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let first = terminal(app)
        let moving = terminal(app)
        let closing = terminal(app)
        let firstWindow = try #require(first.window)
        let movingWindow = try #require(moving.window)
        let closingWindow = try #require(closing.window)
        firstWindow.addTabbedWindow(movingWindow, ordered: .above)
        var destination: TerminalController?
        defer {
            [first, moving, closing, destination].compactMap { $0 }.forEach { $0.window?.close() }
            app.undoManager.removeAllActions()
        }
        let task = try #require(TerminalController.startCloseAllWindows(
            app,
            needsConfirmation: { $0 === first },
            confirm: { _ in
                let newcomer = terminal(app)
                destination = newcomer
                firstWindow.tabGroup?.removeWindow(movingWindow)
                newcomer.window!.addTabbedWindow(movingWindow, ordered: .above)
                closingWindow.close()
                return .allowed
            }
        ))
        await task.value
        #expect(!isOpen(first) && !isOpen(moving) && !isOpen(closing))
        #expect(isOpen(try #require(destination)))
    }

    @Test(arguments: [BaseTerminalController.CloseConfirmationResult.cancelled, .inFlight])
    func deniedApprovalKeepsWindowsAndUndoHistory(result: BaseTerminalController.CloseConfirmationResult) async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let first = terminal(app)
        let second = terminal(app)
        defer { first.window?.close(); second.window?.close(); app.undoManager.removeAllActions() }
        let undo = app.undoManager
        undo.removeAllActions()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: first) { _ in }
        undo.setActionName("Existing Action")
        undo.endUndoGrouping()
        let task = try #require(TerminalController.startCloseAllWindows(
            app, needsConfirmation: { _ in true }, confirm: { _ in result }
        ))
        await task.value
        #expect(isOpen(first) && isOpen(second))
        #expect(undo.canUndo && !undo.canRedo)
        #expect(undo.undoActionName == "Existing Action")
        let retry = try #require(TerminalController.startCloseAllWindows(
            app, needsConfirmation: { _ in true }, confirm: { _ in .cancelled }
        ))
        await retry.value
        #expect(isOpen(first) && isOpen(second))
    }

    @Test func cancelledTaskCannotCommitApproval() async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let controller = terminal(app)
        defer { controller.window?.close(); app.undoManager.removeAllActions() }
        let task = try #require(TerminalController.startCloseAllWindows(
            app, needsConfirmation: { _ in true }, confirm: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return .allowed
            }
        ))
        await task.value
        #expect(isOpen(controller))
    }

    @Test func overlappingAllAndWindowRequestsCannotBypassReview() async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let first = terminal(app)
        let idle = terminal(app)
        let window = try #require(first.window)
        window.addTabbedWindow(try #require(idle.window), ordered: .above)
        defer { first.window?.close(); idle.window?.close(); app.undoManager.removeAllActions() }
        let task = try #require(TerminalController.startCloseAllWindows(
            app, needsConfirmation: { $0 === first }, confirm: { _ in
                #expect(TerminalController.startCloseAllWindows(app, needsConfirmation: { _ in false }) == nil)
                #expect(idle.startCloseWindow(needsConfirmation: { _ in false }) == nil)
                #expect(isOpen(first) && isOpen(idle))
                return .cancelled
            }
        ))
        await task.value
        #expect(isOpen(first) && isOpen(idle))
    }

    @Test func existingWindowReviewBlocksCloseAll() async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let controller = terminal(app)
        defer { controller.window?.close(); app.undoManager.removeAllActions() }
        let task = try #require(controller.startCloseWindow(
            needsConfirmation: { _ in true }, confirm: { _ in
                #expect(TerminalController.startCloseAllWindows(app, needsConfirmation: { _ in false }) == nil)
                #expect(isOpen(controller))
                return .cancelled
            }
        ))
        await task.value
        #expect(isOpen(controller))
    }

    @Test func defaultConfirmationUsesExistingArbitration() async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let controller = ConfirmationController(app)
        defer { controller.window?.close(); app.undoManager.removeAllActions() }
        var presentations = 0
        controller.onConfirmation = { alert in
            presentations += 1
            #expect(alert.messageText == "Close All Windows?")
            #expect(alert.buttons.first?.title == "Close All Windows")
            let overlapping = await controller.confirmCloseAsync(messageText: "Other close", informativeText: "")
            #expect(overlapping == .inFlight)
            #expect(TerminalController.startCloseAllWindows(app, needsConfirmation: { _ in false }) == nil)
            #expect(isOpen(controller))
            return .alertSecondButtonReturn
        }
        let request = TerminalController.startCloseAllWindows(app, needsConfirmation: { _ in true })
        let task = try #require(request)
        await task.value
        #expect(presentations == 1)
        #expect(isOpen(controller))
        controller.onConfirmation = nil
    }

    @Test func closeAllExcludesReusableQuickTerminal() async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let quick = QuickTerminalController(app)
        let quickWindow = try #require(quick.window)
        let content = try #require(quickWindow.contentView)
        let normal = terminal(app)
        defer { quickWindow.close(); normal.window?.close(); app.undoManager.removeAllActions() }
        #expect(TerminalController.startCloseAllWindows(app, needsConfirmation: { _ in false }) == nil)
        #expect(!isOpen(normal))
        #expect(isOpen(quick))
        #expect(quick.window === quickWindow && quickWindow.contentView === content)
    }

    @Test func multipleGroupsUndoInOrderAndRedoKeepsLaterSiblings() async throws {
        let config = try TemporaryConfig("""
        macos-titlebar-style = hidden
        initial-window = false
        confirm-close-surface = false
        undo-timeout = 30s
        """)
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let originals = (0..<5).map { _ in terminal(app) }
        let windows = try originals.map { try #require($0.window) }
        originals.forEach { $0.showWindow(nil) }
        windows[0].addTabbedWindow(windows[1], ordered: .above)
        windows[1].addTabbedWindow(windows[2], ordered: .above)
        windows[3].addTabbedWindow(windows[4], ordered: .above)
        let surfaces = try originals.map { try #require($0.surfaceTree.first) }
        let undo = app.undoManager
        var newcomer: TerminalController?
        defer {
            undo.removeAllActions()
            app.windowRegistry.all.forEach { $0.window?.close() }
            windows.forEach { $0.close() }
            newcomer?.window?.close()
        }
        undo.removeAllActions()
        undo.groupsByEvent = false
        #expect(TerminalController.startCloseAllWindows(app, needsConfirmation: { _ in false }) == nil)
        #expect(originals.allSatisfy { !isOpen($0) })
        for iteration in 0..<2 {
            #expect(undo.undoActionName == "Close All Windows")
            undo.undo()
            await drainMainQueue()
            for indices in [[0, 1, 2], [3, 4]] {
                let restored = try indices.map { try #require(app.windowRegistry.owner(of: surfaces[$0])) }
                let tabWindows = try #require(restored[0].window?.tabGroup?.windows)
                let orderedIDs = tabWindows.compactMap { ($0.windowController as? TerminalController)?.surfaceTree.first?.id }
                #expect(orderedIDs.filter { surfaces.map(\.id).contains($0) } == indices.map { surfaces[$0].id })
            }
            if iteration == 0 {
                let later = terminal(app)
                newcomer = later
                let owner = try #require(app.windowRegistry.owner(of: surfaces[0]))
                owner.window!.addTabbedWindow(try #require(later.window), ordered: .above)
            }
            #expect(undo.canRedo)
            undo.redo()
            await drainMainQueue()
            #expect(surfaces.allSatisfy { app.windowRegistry.owner(of: $0) == nil })
            #expect(isOpen(try #require(newcomer)))
        }
    }

    private func drainMainQueue() async {
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}
