import AppKit
import Testing
@testable import Ghostty

@MainActor struct WindowCloseSnapshotTests {
    private func terminal(_ app: Ghostty.App) -> TerminalController {
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/zsh -f"
        config.workingDirectory = FileManager.default.temporaryDirectory.path
        return TerminalController(app, withBaseConfig: config)
    }

    private func isOpen(_ controller: TerminalController) -> Bool {
        controller.ghostty.windowRegistry.windowControllers.contains { $0 === controller }
    }

    @Test func reviewWaitsForEveryApprovalAndIncludesIdleTabs() async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let first = terminal(app)
        let second = terminal(app)
        let idle = terminal(app)
        let window = try #require(first.window)
        window.addTabbedWindow(try #require(second.window), ordered: .above)
        window.addTabbedWindow(try #require(idle.window), ordered: .above)
        defer { first.window?.close(); second.window?.close(); idle.window?.close() }
        var reviewed: [TerminalController] = []
        let task = try #require(first.startCloseWindow(
            needsConfirmation: { $0 !== idle },
            review: { _, count in
                #expect(count == 2)
                return .alertFirstButtonReturn
            },
            confirm: { controller in
                #expect(isOpen(first) && isOpen(second) && isOpen(idle))
                reviewed.append(controller)
                return .allowed
            }
        ))
        await task.value
        #expect(reviewed.count == 2)
        #expect(!reviewed.contains { $0 === idle })
        #expect(!isOpen(first) && !isOpen(second) && !isOpen(idle))
    }

    @Test(arguments: [BaseTerminalController.CloseConfirmationResult.cancelled, .inFlight])
    func unapprovedLaterReviewClosesNothingAndReleasesTransaction(
        result: BaseTerminalController.CloseConfirmationResult
    ) async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let first = terminal(app)
        let second = terminal(app)
        let idle = terminal(app)
        let window = try #require(first.window)
        window.addTabbedWindow(try #require(second.window), ordered: .above)
        window.addTabbedWindow(try #require(idle.window), ordered: .above)
        defer { first.window?.close(); second.window?.close(); idle.window?.close() }
        var count = 0
        let task = try #require(first.startCloseWindow(
            needsConfirmation: { $0 !== idle },
            review: { _, _ in .alertFirstButtonReturn },
            confirm: { _ in
                count += 1
                return count == 1 ? .allowed : result
            }
        ))
        await task.value
        #expect(count == 2)
        #expect(isOpen(first) && isOpen(second) && isOpen(idle))
        let retry = try #require(idle.startCloseWindow(
            needsConfirmation: { $0 !== idle },
            review: { _, _ in .alertThirdButtonReturn },
            confirm: { _ in Issue.record("Cancelled review must not confirm"); return .cancelled }
        ))
        await retry.value
        #expect(isOpen(first) && isOpen(second) && isOpen(idle))
    }

    @Test func movedOriginalTabsCloseButNewSiblingsSurvive() async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let first = terminal(app)
        let second = terminal(app)
        let idle = terminal(app)
        let newcomer = terminal(app)
        let destination = terminal(app)
        let window = try #require(first.window)
        let movingWindow = try #require(second.window)
        let destinationWindow = try #require(destination.window)
        let newWindow = try #require(newcomer.window)
        window.addTabbedWindow(movingWindow, ordered: .above)
        window.addTabbedWindow(try #require(idle.window), ordered: .above)
        let controllers = [first, second, idle, newcomer, destination]
        defer { controllers.forEach { $0.window?.close() } }
        var reviewed = 0
        let task = try #require(first.startCloseWindow(
            needsConfirmation: { $0 !== idle },
            review: { _, _ in .alertFirstButtonReturn },
            confirm: { _ in
                if reviewed == 0 {
                    window.addTabbedWindow(newWindow, ordered: .above)
                    window.tabGroup?.removeWindow(movingWindow)
                    destinationWindow.addTabbedWindow(movingWindow, ordered: .above)
                }
                reviewed += 1
                #expect(isOpen(first) && isOpen(second) && isOpen(idle))
                return .allowed
            }
        ))
        await task.value
        #expect(reviewed == 2)
        #expect(!isOpen(first) && !isOpen(second) && !isOpen(idle))
        #expect(isOpen(newcomer) && isOpen(destination))
    }

    @Test func externallyClosedOriginalIsSkipped() async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let first = terminal(app)
        let second = terminal(app)
        let window = try #require(first.window)
        let secondWindow = try #require(second.window)
        window.addTabbedWindow(secondWindow, ordered: .above)
        defer { window.close(); secondWindow.close() }
        var reviewed: [TerminalController] = []
        let task = try #require(first.startCloseWindow(
            needsConfirmation: { _ in true },
            review: { _, _ in
                secondWindow.close()
                return .alertFirstButtonReturn
            },
            confirm: { controller in reviewed.append(controller); return .allowed }
        ))
        await task.value
        #expect(reviewed.count == 1)
        #expect(reviewed.first === first)
        #expect(!isOpen(first) && !isOpen(second))
    }

    @Test(arguments: [false, true])
    func singleConfirmationAndCloseWithoutReviewKeepSnapshot(multipleBusy: Bool) async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let first = terminal(app)
        let second = terminal(app)
        let newcomer = terminal(app)
        let window = try #require(first.window)
        window.addTabbedWindow(try #require(second.window), ordered: .above)
        let newWindow = try #require(newcomer.window)
        defer { first.window?.close(); second.window?.close(); newcomer.window?.close() }
        let task = try #require(first.startCloseWindow(
            needsConfirmation: { multipleBusy || $0 === first },
            review: { _, _ in
                #expect(multipleBusy)
                window.addTabbedWindow(newWindow, ordered: .above)
                return .alertSecondButtonReturn
            },
            confirm: { _ in
                #expect(!multipleBusy)
                window.addTabbedWindow(newWindow, ordered: .above)
                return .allowed
            }
        ))
        await task.value
        #expect(!isOpen(first) && !isOpen(second))
        #expect(isOpen(newcomer))
    }

    @Test(arguments: [false, true])
    func cancelledTaskCannotCommitApproval(multipleBusy: Bool) async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let first = terminal(app)
        let second = terminal(app)
        let window = try #require(first.window)
        window.addTabbedWindow(try #require(second.window), ordered: .above)
        defer { first.window?.close(); second.window?.close() }
        let task = try #require(first.startCloseWindow(
            needsConfirmation: { multipleBusy || $0 === first },
            review: { _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return .alertSecondButtonReturn
            },
            confirm: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return .allowed
            }
        ))
        await task.value
        #expect(isOpen(first) && isOpen(second))
    }

    @Test func changedMembershipUndoAndRedoRestoreOnlyOriginalSessions() async throws {
        let config = try TemporaryConfig("""
        macos-titlebar-style = hidden
        initial-window = false
        confirm-close-surface = false
        undo-timeout = 30s
        """)
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        var base = Ghostty.SurfaceConfiguration()
        base.command = "/bin/cat"
        base.workingDirectory = FileManager.default.temporaryDirectory.path
        let originals = (0..<3).map { _ in TerminalController(app, withBaseConfig: base) }
        let newcomer = TerminalController(app, withBaseConfig: base)
        let controllers = originals + [newcomer]
        let windows = try controllers.map { try #require($0.window) }
        controllers.forEach { $0.showWindow(nil) }
        windows[0].addTabbedWindow(windows[1], ordered: .above)
        windows[1].addTabbedWindow(windows[2], ordered: .above)
        let surfaces = try controllers.map { try #require($0.surfaceTree.first) }
        let sessions = try surfaces.map { try #require($0.surfaceModel) }
        let originalSurfaces = Array(surfaces.prefix(3))
        let newcomerSurface = surfaces[3]
        let undo = app.undoManager
        defer {
            undo.removeAllActions()
            app.windowRegistry.all.forEach { $0.window?.close() }
            windows.forEach { $0.close() }
        }
        undo.removeAllActions()
        undo.groupsByEvent = false
        let task = try #require(originals[0].startCloseWindow(
            needsConfirmation: { $0 !== originals[2] },
            review: { _, count in
                #expect(count == 2)
                windows[0].addTabbedWindow(windows[3], ordered: .above)
                return .alertFirstButtonReturn
            },
            confirm: { _ in .allowed }
        ))
        await task.value
        try expectRegistry(app, live: [newcomerSurface], closed: originalSurfaces)

        for _ in 0..<2 {
            #expect(undo.canUndo)
            undo.undo()
            await drainMainQueue()
            try expectRegistry(app, live: surfaces, closed: [])
            // A single undo restores every original session with fresh owners.
            for surface in originalSurfaces {
                let owner = try #require(app.windowRegistry.owner(of: surface))
                #expect(!originals.contains { $0 === owner })
            }
            for (surface, session) in zip(surfaces, sessions) {
                #expect(surface.surfaceModel === session)
            }
            #expect(app.windowRegistry.owner(of: newcomerSurface) === newcomer)
            #expect(newcomer.window === windows[3])
            #expect(undo.canRedo)
            undo.redo()
            await drainMainQueue()
            try expectRegistry(app, live: [newcomerSurface], closed: originalSurfaces)
            #expect(app.windowRegistry.owner(of: newcomerSurface) === newcomer)
            #expect(newcomer.window === windows[3])
            #expect(newcomerSurface.surfaceModel === sessions[3])
            for controller in originals {
                #expect(!app.windowRegistry.registeredControllers.contains { $0 === controller })
            }
        }
    }

    private func expectRegistry(
        _ app: Ghostty.App,
        live: [Ghostty.SurfaceView],
        closed: [Ghostty.SurfaceView]
    ) throws {
        let registry = app.windowRegistry
        let enumerated = registry.all
        let identifiers = Set(enumerated.map(ObjectIdentifier.init))
        #expect(enumerated.count == live.count)
        #expect(identifiers.count == enumerated.count)
        #expect(Set(enumerated.flatMap { $0.surfaceTree.map(\.id) }) == Set(live.map(\.id)))
        #expect(Set(registry.registeredControllers.map(ObjectIdentifier.init)) == identifiers)
        #expect(Set(registry.windowControllers.map(ObjectIdentifier.init)) == identifiers)
        for surface in live {
            #expect(registry.surface(id: surface.id) === surface)
            let owner = try #require(registry.owner(of: surface))
            #expect(owner.surfaceTree.contains(surface))
            #expect(enumerated.contains { $0 === owner })
        }
        for surface in closed {
            #expect(registry.surface(id: surface.id) == nil)
            #expect(registry.owner(of: surface) == nil)
        }
    }

    private func drainMainQueue() async {
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    @Test func overlappingRequestsCannotStartAnotherReview() async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let first = terminal(app)
        let second = terminal(app)
        let idle = terminal(app)
        let window = try #require(first.window)
        window.addTabbedWindow(try #require(second.window), ordered: .above)
        window.addTabbedWindow(try #require(idle.window), ordered: .above)
        defer { first.window?.close(); second.window?.close(); idle.window?.close() }
        let task = try #require(first.startCloseWindow(
            needsConfirmation: { $0 !== idle },
            review: { _, _ in
                #expect(idle.startCloseWindow(needsConfirmation: { _ in false }) == nil)
                #expect(isOpen(first) && isOpen(second) && isOpen(idle))
                return .alertFirstButtonReturn
            },
            confirm: { _ in
                #expect(idle.startCloseWindow(needsConfirmation: { _ in false }) == nil)
                #expect(isOpen(first) && isOpen(idle))
                return .allowed
            }
        ))
        #expect(first.startCloseWindow(needsConfirmation: { _ in false }) == nil)
        await task.value
        #expect(!isOpen(first) && !isOpen(second) && !isOpen(idle))
    }
}
