import AppKit
import GhosttyKit
import Testing
@testable import Ghostty

@MainActor struct SurfaceLifecycleTests {
    private func view(_ app: Ghostty.App) -> Ghostty.SurfaceView {
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/cat"
        config.workingDirectory = FileManager.default.temporaryDirectory.path
        return Ghostty.SurfaceView(app, baseConfig: config)
    }

    private func window() -> NSWindow {
        let result = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        result.isReleasedWhenClosed = false
        return result
    }

    @Test func attachmentMovesKeepSessionAndScopeEventMonitoring() throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let view = view(app)
        let core = try #require(view.surfaceModel)
        let first = window()
        let second = window()
        defer { first.close(); second.close() }
        #expect(view.lifecycle.phase == .ready)
        #expect(!view.lifecycle.isMonitoringEvents)
        first.contentView = view
        #expect(view.lifecycle.window === first)
        #expect(view.lifecycle.isMonitoringEvents)
        view.removeFromSuperview()
        #expect(view.lifecycle.window == nil)
        #expect(!view.lifecycle.isMonitoringEvents)
        #expect(!view.focused)
        #expect(!view.isWindowVisible)
        #expect(view.surfaceModel === core)
        second.contentView = view
        #expect(view.lifecycle.window === second)
        #expect(view.lifecycle.isMonitoringEvents)
        #expect(view.surfaceModel === core)
        second.contentView = nil
        #expect(!view.lifecycle.isMonitoringEvents)
    }

    @Test func staleScrollWrapperCannotResizeOrDetachMovedSurface() throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let view = view(app)
        let core = try #require(view.surfaceModel)
        let source = SurfaceScrollView(contentSize: NSSize(width: 300, height: 200), surfaceView: view)
        source.frame.size = NSSize(width: 300, height: 200)
        source.layout()
        let destination = SurfaceScrollView(contentSize: NSSize(width: 650, height: 450), surfaceView: view)
        destination.frame.size = NSSize(width: 650, height: 450)
        destination.layout()
        let parent = view.superview
        let frame = view.frame
        let size = core.size
        source.frame.size = NSSize(width: 100, height: 100)
        source.layout()
        source.dismantle()
        source.dismantle()
        #expect(view.superview === parent)
        #expect(view.frame == frame)
        #expect(core.size == size)
        #expect(view.surfaceModel === core)
        destination.dismantle()
        #expect(view.superview == nil)
        #expect(view.surfaceModel === core)
        let restored = SurfaceScrollView(contentSize: frame.size, surfaceView: view)
        #expect(view.superview != nil)
        #expect(view.surfaceModel === core)
        restored.dismantle()
    }

    @Test func callbackContextOutlivesReleasedViewWithoutRetainingIt() async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        var view: Ghostty.SurfaceView? = view(app)
        weak let weakView = view
        var core: Ghostty.Surface? = try #require(view?.surfaceModel)
        weak let context = core?.callbackContext
        let userdata = ghostty_surface_userdata(try #require(core).unsafeCValue)
        view = nil
        await drainMainQueue()
        #expect(weakView == nil)
        #expect(context != nil)
        #expect(context?.view == nil)
        // A late core callback sees an empty context, never a deallocated NSView.
        Ghostty.App.closeSurface(userdata, processAlive: false)
        #expect(Ghostty.App.readClipboard(userdata, location: GHOSTTY_CLIPBOARD_STANDARD,
                                        state: nil, mimes: nil, mimesLen: 0, list: false) == GHOSTTY_CLIPBOARD_READ_UNSUPPORTED)
        let target = ghostty_target_s(tag: GHOSTTY_TARGET_SURFACE,
                                     target: ghostty_target_u(surface: try #require(core).unsafeCValue))
        "late title".withCString { title in
            _ = Ghostty.App.action(app.app!, target: target,
                                   action: .init(tag: GHOSTTY_ACTION_SET_TITLE,
                                                 action: .init(set_title: .init(title: title))))
        }
        core = nil
        await drainMainQueue()
        #expect(context == nil)
    }

    @Test func releaseIsIdempotentAndCannotReattach() throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let view = view(app)
        let core = try #require(view.surfaceModel)
        let window = window()
        defer { window.close() }
        window.contentView = view
        view.lifecycle.release()
        view.lifecycle.release()
        view.lifecycle.attach(to: window) { $0 }
        #expect(view.lifecycle.phase == .released)
        #expect(view.surfaceModel == nil)
        #expect(core.callbackContext.view == nil)
        #expect(!view.lifecycle.isMonitoringEvents)
    }

    @Test func creationUsesOwningAppConfiguration() throws {
        let config = try TemporaryConfig("background-opacity = 0.43\nwindow-title-font-family = Session Font")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let view = view(app)
        #expect(view.derivedConfig.backgroundOpacity == 0.43)
        #expect(view.derivedConfig.windowTitleFontFamily == "Session Font")
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
