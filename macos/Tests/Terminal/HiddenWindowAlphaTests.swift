import AppKit
import Testing
@testable import Ghostty

@MainActor struct HiddenWindowAlphaTests {
    private class TrackingWindow: HiddenTitlebarTerminalWindow {
        var recording = false
        var opacityWrites: [Bool] = []
        var backgroundAlphaWrites: [CGFloat?] = []

        override var isOpaque: Bool {
            get { super.isOpaque }
            set {
                if recording { opacityWrites.append(newValue) }
                super.isOpaque = newValue
            }
        }

        override var backgroundColor: NSColor? {
            get { super.backgroundColor }
            set {
                if recording { backgroundAlphaWrites.append(newValue?.alphaComponent) }
                super.backgroundColor = newValue
            }
        }
    }

    private class TrackingController: TerminalController {
        override func loadWindow() {
            let tracked = TrackingWindow(
                contentRect: NSRect(x: 200, y: 200, width: 400, height: 250),
                styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false
            )
            tracked.isReleasedWhenClosed = false
            window = tracked
            tracked.delegate = self
            tracked.configure(for: ghostty)
        }
    }

    @Test(arguments: [1.0, 0.7], [false, true])
    func hiddenAppearanceNeverPublishesRectangularOpaqueBackground(opacity: Double, forceOpaque: Bool) throws {
        let config = try TemporaryConfig("""
        macos-titlebar-style = hidden
        macos-window-shadow = true
        background-opacity = \(opacity)
        initial-window = false
        """)
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        var base = Ghostty.SurfaceConfiguration()
        base.command = "/bin/cat"
        base.workingDirectory = FileManager.default.temporaryDirectory.path
        let controller = TrackingController(app, withBaseConfig: base)
        let window = try #require(controller.window as? TrackingWindow)
        let surface = try #require(controller.surfaceTree.first)
        defer { window.close() }
        controller.isBackgroundOpaque = forceOpaque
        window.orderFront(nil)
        #expect(window.isVisible)
        window.recording = true
        window.syncAppearance(surface.derivedConfig)
        window.recording = false
        print("Hidden appearance writes: opacity=\(opacity), forceOpaque=\(forceOpaque), isOpaque=\(window.opacityWrites), backgroundAlpha=\(window.backgroundAlphaWrites)")
        #expect(!window.opacityWrites.isEmpty)
        #expect(!window.backgroundAlphaWrites.isEmpty)
        #expect(window.opacityWrites.allSatisfy { !$0 })
        #expect(window.backgroundAlphaWrites.allSatisfy { $0 == 0 })
        #expect(!window.isOpaque)
        #expect(window.backgroundColor?.alphaComponent == 0)
        #expect(!window.hasShadow)
    }
}
