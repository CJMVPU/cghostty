import AppKit
import Testing
@testable import Ghostty

@MainActor struct WindowRegistryTests {
    private func terminal(_ app: Ghostty.App) -> TerminalController {
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/zsh -f"
        config.workingDirectory = FileManager.default.temporaryDirectory.path
        return TerminalController(app, withBaseConfig: config)
    }

    @Test func enumerationAndPreferredParentAreAppScoped() throws {
        let first = Ghostty.App(configPath: "/dev/null")
        let second = Ghostty.App(configPath: "/dev/null")
        let one = terminal(first)
        let two = terminal(second)
        let firstWindow = try #require(one.window)
        let secondWindow = try #require(two.window)
        defer { firstWindow.close(); secondWindow.close() }
        first.windowRegistry.didBecomeMain(one)
        second.windowRegistry.didBecomeMain(two)
        #expect(first.windowRegistry.all.count == 1)
        #expect(first.windowRegistry.all.first === one)
        #expect(second.windowRegistry.all.first === two)
        #expect(first.windowRegistry.preferredParent === one)
        #expect(second.windowRegistry.preferredParent === two)
        first.windowRegistry.didBecomeMain(two)
        #expect(first.windowRegistry.lastMain === one)
    }

    @Test func closingRetainedLastMainCannotRemainAParent() throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let one = terminal(app)
        let two = terminal(app)
        let firstWindow = try #require(one.window)
        let secondWindow = try #require(two.window)
        defer { firstWindow.close(); secondWindow.close() }
        app.windowRegistry.didBecomeMain(two)
        #expect(app.windowRegistry.preferredParent === two)
        secondWindow.close()
        #expect(app.windowRegistry.lastMain == nil)
        #expect(app.windowRegistry.all.count == 1)
        #expect(app.windowRegistry.preferredParent === one)
        app.windowRegistry.didBecomeMain(two)
        #expect(app.windowRegistry.lastMain == nil)
        firstWindow.close()
        #expect(app.windowRegistry.all.isEmpty)
        #expect(app.windowRegistry.preferredParent == nil)
    }

    @Test func cascadeIgnoresOtherAppsFixedPositionsAndClosedWindows() throws {
        let first = Ghostty.App(configPath: "/dev/null")
        let second = Ghostty.App(configPath: "/dev/null")
        let one = terminal(first)
        let two = terminal(second)
        let firstWindow = try #require(one.window)
        let secondWindow = try #require(two.window)
        defer { firstWindow.close(); secondWindow.close() }
        let frame = firstWindow.frame
        first.windowRegistry.applyCascade(to: firstWindow, hasFixedPos: true)
        #expect(firstWindow.frame == frame)
        #expect(first.windowRegistry.lastCascadePoint == .zero)
        first.windowRegistry.applyCascade(to: secondWindow, hasFixedPos: false)
        #expect(first.windowRegistry.lastCascadePoint == .zero)
        first.windowRegistry.applyCascade(to: firstWindow, hasFixedPos: false)
        #expect(first.windowRegistry.lastCascadePoint != .zero)
        #expect(second.windowRegistry.lastCascadePoint == .zero)
        firstWindow.close()
        #expect(first.windowRegistry.lastCascadePoint == .zero)
        let closedFrame = firstWindow.frame
        first.windowRegistry.applyCascade(to: firstWindow, hasFixedPos: false)
        #expect(firstWindow.frame == closedFrame)
        #expect(first.windowRegistry.lastCascadePoint == .zero)
    }

    @Test func closingWithForeignKeyWindowDoesNotChangeCascade() throws {
        let first = Ghostty.App(configPath: "/dev/null")
        let second = Ghostty.App(configPath: "/dev/null")
        let remaining = terminal(first)
        let closing = terminal(first)
        let foreign = terminal(second)
        let remainingWindow = try #require(remaining.window)
        let closingWindow = try #require(closing.window)
        let foreignWindow = try #require(foreign.window)
        defer { remainingWindow.close(); closingWindow.close(); foreignWindow.close() }
        first.windowRegistry.applyCascade(to: remainingWindow, hasFixedPos: false)
        let point = first.windowRegistry.lastCascadePoint
        let frame = foreignWindow.frame
        first.windowRegistry.windowWillClose(closing, keyWindow: foreignWindow)
        #expect(first.windowRegistry.lastCascadePoint == point)
        #expect(foreignWindow.frame == frame)
        #expect(first.windowRegistry.all.first === remaining)
    }

    @Test func coreCloseAllWindowsOnlyClosesItsOwnApp() throws {
        let config = try TemporaryConfig("confirm-close-surface = false")
        let first = Ghostty.App(configPath: config.temporaryFile.path)
        let second = Ghostty.App(configPath: config.temporaryFile.path)
        let one = terminal(first)
        let two = terminal(second)
        let firstWindow = try #require(one.window)
        let secondWindow = try #require(two.window)
        defer { firstWindow.close(); secondWindow.close() }
        let surface = try #require(one.surfaceTree.first?.surfaceModel)
        #expect(surface.perform(action: "close_all_windows"))
        #expect(first.windowRegistry.all.isEmpty)
        #expect(second.windowRegistry.all.count == 1)
        #expect(second.windowRegistry.all.first === two)
    }

    @Test func registryAndLastMainDoNotRetainClosedControllerOrApp() async throws {
        var app: Ghostty.App? = Ghostty.App(configPath: "/dev/null")
        let registry = try #require(app?.windowRegistry)
        weak let weakApp = app
        var controller: TerminalController? = terminal(try #require(app))
        weak let weakController = controller
        let window = try #require(controller?.window)
        registry.didBecomeMain(try #require(controller))
        controller = nil
        app = nil
        #expect(weakController != nil)
        #expect(weakApp != nil)
        window.close()
        // Deliver queued AppKit / observation work, without a fixed delay.
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        #expect(weakController == nil)
        #expect(weakApp == nil)
        #expect(registry.lastMain == nil)
        #expect(registry.all.isEmpty)
    }
}
