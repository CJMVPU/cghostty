import AppKit
import Testing
@testable import Ghostty

@MainActor struct MergedWindowRegistryTests {
    @Test(arguments: TerminalController.TabCloseScope.allCases)
    func partiallyMergedGroupsKeepRegistryIntegrityThroughCloseUndoAndRedo(
        scope: TerminalController.TabCloseScope
    ) async throws {
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
        // Retain the original controllers even after close, like pending AppKit work
        // or undo clients can. Closed controllers must still leave every index.
        let controllers = (0..<7).map { _ in TerminalController(app, withBaseConfig: base) }
        let undo = app.undoManager
        defer {
            undo.removeAllActions()
            app.windowRegistry.all.forEach { $0.window?.close() }
            controllers.forEach { $0.window?.close() }
        }
        let windows = try controllers.map { try #require($0.window as? TerminalWindow) }
        controllers.forEach { $0.showWindow(nil) }
        for index in 1..<4 { windows[index - 1].addTabbedWindow(windows[index], ordered: .above) }
        for index in 5..<7 { windows[index - 1].addTabbedWindow(windows[index], ordered: .above) }
        #expect(windows[0].tabGroup?.windows.count == 4)
        #expect(windows[4].tabGroup?.windows.count == 3)
        let surfaces = try controllers.map { try #require($0.surfaceTree.first) }
        let sessions = try surfaces.map { try #require($0.surfaceModel) }
        try expectRegistry(app, live: surfaces, closed: [])

        windows[0].mergeAllWindows(nil)
        await drainMainQueue()
        let merged = try #require(windows[0].tabGroup)
        #expect(merged.windows.count == 5)
        let overflow = windows.filter { candidate in
            !merged.windows.contains { $0 === candidate }
        }
        #expect(overflow.count == 2)
        let overflowWindow = try #require(overflow.first)
        let overflowGroup = try #require(overflowWindow.tabGroup)
        #expect(Set(overflowGroup.windows.map(ObjectIdentifier.init)) == Set(overflow.map(ObjectIdentifier.init)))
        let overflowOrder = try orderedSurfaces(in: overflowGroup).map(\.id)
        let mergedSurfaces = try orderedSurfaces(in: merged)
        try expectRegistry(app, live: surfaces, closed: [])

        // Exercise a non-edge tab, leaving inactive tabs in both groups.
        let anchorWindow = try #require(merged.windows[safe: 2])
        let anchor = try #require(anchorWindow.windowController as? TerminalController)
        merged.selectedWindow = anchorWindow
        anchorWindow.makeKeyAndOrderFront(nil)
        let closed = mergedSurfaces.enumerated().compactMap { index, surface in
            (scope == .others ? index != 2 : index > 2) ? surface : nil
        }
        let closedIDs = Set(closed.map(\.id))
        let remaining = surfaces.filter { !closedIDs.contains($0.id) }
        let closedControllers = try closed.map { try #require(app.windowRegistry.owner(of: $0)) }
        undo.removeAllActions()
        undo.groupsByEvent = false
        anchor.closeTabsImmediately(scope)
        try expectRegistry(app, live: remaining, closed: closed)

        for _ in 0..<2 {
            await drainMainQueue()
            try expectRegistry(app, live: remaining, closed: closed)
            #expect(undo.canUndo)
            undo.undo()
            await drainMainQueue()
            try expectRegistry(app, live: surfaces, closed: [])
            let restoredGroup = try #require(anchor.window?.tabGroup)
            #expect(try orderedSurfaces(in: restoredGroup).map(\.id) == mergedSurfaces.map(\.id))
            #expect(try orderedSurfaces(in: overflowGroup).map(\.id) == overflowOrder)
            for (surface, session) in zip(surfaces, sessions) {
                #expect(surface.surfaceModel === session)
            }
            // Undo creates replacement controllers around the original sessions.
            for controller in closedControllers {
                #expect(!app.windowRegistry.registeredControllers.contains { $0 === controller })
                #expect(!app.windowRegistry.windowControllers.contains { $0 === controller })
            }
            #expect(undo.canRedo)
            undo.redo()
            await drainMainQueue()
            try expectRegistry(app, live: remaining, closed: closed)
            #expect(try orderedSurfaces(in: overflowGroup).map(\.id) == overflowOrder)
        }
    }

    private func orderedSurfaces(in group: NSWindowTabGroup) throws -> [Ghostty.SurfaceView] {
        try group.windows.map {
            let controller = try #require($0.windowController as? TerminalController)
            return try #require(controller.surfaceTree.first)
        }
    }

    private func expectRegistry(
        _ app: Ghostty.App,
        live: [Ghostty.SurfaceView],
        closed: [Ghostty.SurfaceView]
    ) throws {
        let registry = app.windowRegistry
        let expectedIDs = Set(live.map(\.id))
        let enumerated = registry.all
        #expect(enumerated.count == live.count)
        #expect(Set(enumerated.map(ObjectIdentifier.init)).count == enumerated.count)
        #expect(Set(enumerated.flatMap { $0.surfaceTree.map(\.id) }) == expectedIDs)
        #expect(Set(registry.registeredControllers.map(ObjectIdentifier.init)) == Set(enumerated.map(ObjectIdentifier.init)))
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
        if let lastMain = registry.lastMain {
            #expect(enumerated.contains { $0 === lastMain })
        }
        let preferredParent = try #require(registry.preferredParent)
        #expect(enumerated.contains { $0 === preferredParent })
    }

    private func drainMainQueue() async {
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}
