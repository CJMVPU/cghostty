import AppKit
import Testing
@testable import Ghostty

@MainActor struct WindowShadowTests {
    private func terminal(_ app: Ghostty.App) -> TerminalController {
        var base = Ghostty.SurfaceConfiguration()
        base.command = "/bin/cat"
        base.workingDirectory = FileManager.default.temporaryDirectory.path
        return TerminalController(app, withBaseConfig: base)
    }

    @Test(arguments: ["native", "hidden", "transparent", "tabs"])
    func terminalLifecycleCannotRestoreSystemShadow(style: String) async throws {
        let config = try TemporaryConfig("""
        macos-titlebar-style = \(style)
        macos-window-shadow = true
        initial-window = false
        window-width = 50
        window-height = 12
        confirm-close-surface = false
        undo-timeout = 30s
        """)
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        #expect(app.config.macosWindowShadow)
        let controllers = [terminal(app), terminal(app)]
        defer {
            app.undoManager.removeAllActions()
            app.windowRegistry.all.forEach { $0.window?.close() }
            controllers.forEach { $0.window?.close() }
        }
        let windows = try controllers.map { try #require($0.window as? TerminalWindow) }
        for (controller, window) in zip(controllers, windows) {
            #expect(!window.hasShadow)
            controller.showWindow(nil)
            let surface = try #require(controller.surfaceTree.first)
            #expect(surface.derivedConfig.macosWindowShadow)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                window.hasShadow = true
                window.syncAppearance(surface.derivedConfig)
                window.invalidateShadow()
                #expect(!window.hasShadow)
            }
            window.orderOut(nil)
            window.makeKeyAndOrderFront(nil)
            #expect(!window.hasShadow)
        }
        windows[0].addTabbedWindow(windows[1], ordered: .above)
        let group = try #require(windows[0].tabGroup)
        #expect(group.windows.count == 2)
        for window in windows {
            group.selectedWindow = window
            window.makeKeyAndOrderFront(nil)
            #expect(!window.hasShadow)
        }
        app.undoManager.removeAllActions()
        app.undoManager.groupsByEvent = false
        controllers[0].closeWindowImmediately()
        #expect(app.windowRegistry.all.isEmpty)
        app.undoManager.undo()
        try await NativeTestWait.until("restored shadow-free tabs", timeout: .seconds(3), polling: .milliseconds(5),
                                       diagnostics: { "\(app.windowRegistry.all.count) controllers" },
                                       { app.windowRegistry.all.count == 2 && app.windowRegistry.all.allSatisfy {
                                           $0.window?.tabGroup?.windows.count == 2
                                       } })
        for restored in app.windowRegistry.all {
            let window = try #require(restored.window as? TerminalWindow)
            window.hasShadow = true
            window.makeKeyAndOrderFront(nil)
            restored.syncAppearance()
            #expect(!window.hasShadow)
        }
    }

    @Test func quickTerminalKeepsShadowOffWhileAuxiliaryWindowsKeepTheirPolicy() {
        let frame = NSRect(x: 100, y: 100, width: 400, height: 250)
        let quick = QuickTerminalWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let auxiliary = NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        quick.isReleasedWhenClosed = false
        auxiliary.isReleasedWhenClosed = false
        defer { quick.close(); auxiliary.close() }
        #expect(!quick.hasShadow)
        quick.configure()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            quick.appearance = NSAppearance(named: appearance)
            quick.hasShadow = true
            quick.orderFront(nil)
            quick.invalidateShadow()
            #expect(!quick.hasShadow)
            quick.orderOut(nil)
        }
        auxiliary.hasShadow = true
        #expect(auxiliary.hasShadow)
    }
}
