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

    @Test func pointerChangesLeaveScrollAppearanceAndSizeUntouched() async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let view = view(app)
        let wrapper = SurfaceScrollView(contentSize: NSSize(width: 600, height: 400), surfaceView: view)
        defer { wrapper.dismantle() }
        wrapper.frame.size = NSSize(width: 600, height: 400)
        wrapper.layout()
        let scroll = try #require(wrapper.subviews.first as? NSScrollView)
        let appearanceUpdates = wrapper.appearanceUpdates
        let sizeRequests = view.sizeRequests
        for style: CursorStyle in [.link, .crosshair, .horizontalText, .default] {
            view.setCursorShape(style)
            let deadline = ContinuousClock.now + .seconds(2)
            while scroll.documentCursor != style.cursor {
                try #require(ContinuousClock.now < deadline, "Pointer observation did not update the cursor")
                await Task.yield()
            }
        }
        #expect(wrapper.appearanceUpdates == appearanceUpdates)
        #expect(view.sizeRequests == sizeRequests)
        // Font callbacks must refresh metrics even without a layout or pixel
        // size change, and without reapplying the scrollbar appearance.
        let core = try #require(view.surfaceModel)
        #expect(core.changeFontSize(by: 2))
        let deadline = ContinuousClock.now + .seconds(2)
        while view.surfaceSize != core.size {
            try #require(ContinuousClock.now < deadline, "Font metrics did not publish without a resize")
            await Task.yield()
        }
        #expect(wrapper.appearanceUpdates == appearanceUpdates)
        #expect(view.sizeRequests == sizeRequests)
        wrapper.updateTrackingAreas()
        let areas = wrapper.trackingAreas
        wrapper.updateTrackingAreas()
        #expect(wrapper.trackingAreas == areas)
    }

    @Test func repeatedPixelSizesCoalesceAndFontMetricsStillPublish() async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let view = view(app)
        let core = try #require(view.surfaceModel)
        let size = CGSize(width: 600, height: 400)
        view.sizeDidChange(size)
        let requests = view.sizeRequests
        for _ in 0..<100 { view.sizeDidChange(size) }
        #expect(view.sizeRequests == requests)
        view.sizeDidChange(CGSize(width: 610, height: 410))
        view.sizeDidChange(CGSize(width: 620, height: 420))
        await drainMainQueue()
        #expect(view.surfaceSize == core.size)
        let previous = core.size
        #expect(core.perform(action: "increase_font_size:2"))
        view.sizeDidChange(CGSize(width: 620, height: 420))
        await drainMainQueue()
        #expect(view.sizeRequests == requests + 2)
        #expect(view.surfaceSize == core.size)
        #expect(core.size != previous)
        view.viewDidChangeBackingProperties()
        #expect(view.sizeRequests == requests + 3)
        // A queued publication cannot restore presentation state after release.
        view.sizeDidChange(CGSize(width: 630, height: 430))
        view.lifecycle.release()
        let released = view.surfaceSize
        await drainMainQueue()
        #expect(view.surfaceSize == released)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
