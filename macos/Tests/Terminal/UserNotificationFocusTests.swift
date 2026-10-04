import AppKit
import Testing
@testable import Ghostty

@MainActor struct UserNotificationFocusTests {
    private var surfaceConfiguration: Ghostty.SurfaceConfiguration {
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/cat"
        config.workingDirectory = FileManager.default.temporaryDirectory.path
        return config
    }

    @Test(arguments: [false, true])
    func notificationClickPresentsHiddenQuickTerminal(hideCompleted: Bool) async throws {
        let config = try TemporaryConfig("quick-terminal-animation-duration = 0\nquick-terminal-autohide = false")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let view = Ghostty.SurfaceView(app, baseConfig: surfaceConfiguration)
        let quick = QuickTerminalController(app)
        let window = try #require(quick.window)
        defer { quick.animateOut(); window.close() }
        quick.surfaceTree = .init(view: view)
        quick.focusedSurface = view
        quick.animateIn()
        try await NativeTestWait.until("quick terminal entrance", timeout: .seconds(5),
            polling: .milliseconds(10), diagnostics: { "visible=\(quick.visible), alpha=\(window.alphaValue)" }, {
                window.isVisible && window.alphaValue == 1 && view.window === window
            })
        quick.animateOut()
        if hideCompleted {
            try await NativeTestWait.until("quick terminal hide", timeout: .seconds(5),
                polling: .milliseconds(10), diagnostics: { "visible=\(quick.visible), alpha=\(window.alphaValue)" }, {
                    !window.isVisible
                })
        }
        #expect(!quick.visible)
        view.notificationIdentifiers.insert("wake-quick")
        view.handleUserNotification(identifier: "wake-quick", focus: true)
        #expect(quick.visible)
        try await NativeTestWait.until("notification quick terminal presentation", timeout: .seconds(2),
            polling: .milliseconds(10), diagnostics: { "visible=\(quick.visible), alpha=\(window.alphaValue), frame=\(window.frame)" }, {
                quick.visible && window.isVisible && window.alphaValue == 1
            })
        let screen = try #require(window.screen)
        #expect(window.frame.intersects(screen.visibleFrame))
        #expect(!view.notificationIdentifiers.contains("wake-quick"))
    }

    @Test func notificationClickUsesOwnerPresentationOnceAndHonorsNoFocus() {
        let app = Ghostty.App(configPath: "/dev/null")
        let view = Ghostty.SurfaceView(app, baseConfig: surfaceConfiguration)
        let owner = NotificationFocusController(app, surfaceTree: .init(view: view))
        #expect(app.windowRegistry.owner(of: view) === owner)
        view.notificationIdentifiers = ["focus", "no-focus"]
        view.handleUserNotification(identifier: "unknown", focus: true)
        view.handleUserNotification(identifier: "no-focus", focus: false)
        #expect(owner.focusRequests == 0)
        view.handleUserNotification(identifier: "focus", focus: true)
        #expect(owner.focusRequests == 1)
        #expect(owner.requestedSurface === view)
        view.handleUserNotification(identifier: "focus", focus: true)
        #expect(owner.focusRequests == 1)
        #expect(view.notificationIdentifiers.isEmpty)
    }

    @Test func removedSurfaceNotificationDoesNotPresentFormerOwner() {
        let app = Ghostty.App(configPath: "/dev/null")
        let view = Ghostty.SurfaceView(app, baseConfig: surfaceConfiguration)
        let owner = NotificationFocusController(app, surfaceTree: .init(view: view))
        owner.surfaceTree = .init()
        #expect(app.windowRegistry.owner(of: view) == nil)
        view.notificationIdentifiers.insert("removed")
        view.handleUserNotification(identifier: "removed", focus: true)
        #expect(owner.focusRequests == 0)
        #expect(view.notificationIdentifiers.isEmpty)
    }
}

private class NotificationFocusController: BaseTerminalController {
    var focusRequests = 0
    weak var requestedSurface: Ghostty.SurfaceView?

    override func focusSurface(_ view: Ghostty.SurfaceView) {
        focusRequests += 1
        requestedSurface = view
    }
}
