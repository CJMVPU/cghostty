import AppKit
import Testing
@testable import Ghostty

@MainActor struct FixedWindowSizeTests {
    private func terminal(_ app: Ghostty.App) -> TerminalController {
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/cat"
        config.workingDirectory = FileManager.default.temporaryDirectory.path
        return TerminalController(app, withBaseConfig: config)
    }

    @Test(arguments: ["native", "hidden", "transparent", "tabs"])
    func savedFramesAndWindowActionsCannotResize(style: String) throws {
        let config = try TemporaryConfig("""
        macos-titlebar-style = \(style)
        window-width = 50
        window-height = 12
        maximize = true
        fullscreen = true
        """)
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let controller = terminal(app)
        let window = try #require(controller.window as? TerminalWindow)
        defer { window.close() }
        #expect(!window.styleMask.contains(.resizable))
        #expect(window.collectionBehavior.contains(.fullScreenNone))
        #expect(window.collectionBehavior.contains(.fullScreenDisallowsTiling))
        let original = window.frame.size
        let size = try #require(window.fixedContentSize)
        #expect(size == app.initialWindowContentSize)

        // AppKit restoration and external window managers can set frames directly.
        let requested = NSRect(x: 60, y: 80, width: 250, height: 150)
        window.setFrame(requested, display: false)
        #expect(window.frame.size == original)
        #expect(window.frame.origin == requested.origin)
        window.setFrame(requested, display: false, animate: true)
        #expect(window.frame.size == original)
        window.setContentSize(NSSize(width: 200, height: 100))
        #expect(window.frame.size == original)
        window.zoom(nil)
        window.toggleFullScreen(nil)
        let surface = try #require(controller.focusedSurface?.surfaceModel)
        #expect(!surface.perform(.toggleFullscreen))
        #expect(window.frame.size == original)
        #expect(!window.styleMask.contains(.fullScreen))
    }

    @Test func editedConfigurationOnlyChangesSizeInNewApp() throws {
        let config = try TemporaryConfig("window-width = 50\nwindow-height = 12")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let first = terminal(app)
        let one = try #require(first.window as? TerminalWindow)
        defer { one.close() }
        let original = try #require(one.fixedContentSize)
        try "window-width = 80\nwindow-height = 20".write(
            to: config.temporaryFile, atomically: true, encoding: .utf8)
        let second = terminal(app)
        let two = try #require(second.window as? TerminalWindow)
        defer { two.close() }
        #expect(two.fixedContentSize == original)

        let restarted = Ghostty.App(configPath: config.temporaryFile.path)
        let third = terminal(restarted)
        let three = try #require(third.window as? TerminalWindow)
        defer { three.close() }
        let updated = try #require(three.fixedContentSize)
        #expect(updated.width > original.width)
        #expect(updated.height > original.height)
    }

    @Test func existingSplitTreeUsesStartupSizeInsteadOfItsBounds() throws {
        let config = try TemporaryConfig("window-width = 50\nwindow-height = 12")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let first = terminal(app)
        let one = try #require(first.window as? TerminalWindow)
        defer { one.close() }
        var base = Ghostty.SurfaceConfiguration()
        base.command = "/bin/cat"
        base.workingDirectory = FileManager.default.temporaryDirectory.path
        let left = Ghostty.SurfaceView(app, baseConfig: base)
        let right = Ghostty.SurfaceView(app, baseConfig: base)
        left.frame.size = NSSize(width: 100, height: 80)
        right.frame.size = left.frame.size
        let tree = try SplitTree(view: left).inserting(view: right, at: left, direction: .right)
        let restored = TerminalController(app, withSurfaceTree: tree)
        let window = try #require(restored.window as? TerminalWindow)
        defer { window.close() }
        #expect(window.fixedContentSize == one.fixedContentSize)
        #expect(restored.surfaceTree.count == 2)
    }

    @Test func quickTerminalIgnoresSavedManualSize() throws {
        let screen = try #require(NSScreen.main)
        let window = QuickTerminalWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                                         styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.configure()
        let size = QuickTerminalSize()
        let expected = QuickTerminalPosition.top.configuredFrameSize(on: screen, terminalSize: size)
        QuickTerminalPosition.top.setInitial(in: window, on: screen, terminalSize: size,
                                             closedFrame: NSRect(x: 0, y: 0, width: 100, height: 100))
        #expect(window.frame.size == expected)
        #expect(!window.styleMask.contains(.resizable))
        window.setContentSize(NSSize(width: 100, height: 100))
        #expect(window.frame.size == expected)
    }
}
