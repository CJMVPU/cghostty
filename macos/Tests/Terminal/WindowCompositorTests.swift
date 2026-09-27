import AppKit
import Metal
import QuartzCore
import Testing
@testable import Ghostty

@Suite(.serialized)
@MainActor struct WindowCompositorTests {
    @Test(arguments: ["native", "linear", "linear-corrected"])
    func panesShareClockCacheAndMoveWithoutLosingSession(blending: String) async throws {
        let traceDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("cghostty-window-\(blending)-\(UUID().uuidString)")
        print("Window compositor trace: \(traceDirectory.path)")
        let config = try TemporaryConfig("""
        render-presentation = window-compositor
        cursor-style-blink = false
        cursor-effect = false
        shell-integration = none
        alpha-blending = \(blending)
        render-trace = true
        render-trace-directory = \(traceDirectory.path)
        """)
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let left = makeView(app: app, color: "255;0;0", marker: "ready-red")
        let right = makeView(app: app, color: "0;255;0", marker: "ready-green")
        let leftSurface = try #require(left.surfaceModel)
        let rightSurface = try #require(right.surfaceModel)
        let first = makeWindow()
        let second = makeWindow()
        defer { first.close(); second.close() }
        let content = try #require(first.contentView)
        left.frame = CGRect(x: 0, y: 0, width: 240, height: 240)
        right.frame = CGRect(x: 240, y: 0, width: 240, height: 240)
        content.addSubview(left)
        content.addSubview(right)
        first.orderFront(nil)
        left.sizeDidChange(left.bounds.size)
        right.sizeDidChange(right.bounds.size)
        leftSurface.setVisible(true)
        rightSurface.setVisible(true)
        let owner = try #require(left.windowCompositor)
        owner.updateGeometry()
        defer {
            print("Window compositor final statistics: \(owner.worker.statistics)")
        }
        #expect(right.windowCompositor === owner)
        #expect(owner.worker.paneCount == 2)
        #expect(!(left.layer is CAMetalLayer))
        #expect(!(right.layer is CAMetalLayer))
        #expect(owner.host.layer is CAMetalLayer)
        try await wait {
            leftSurface.readContents(viewport: false).contains("ready-red") &&
            rightSurface.readContents(viewport: false).contains("ready-green") &&
            owner.worker.statistics.displayed > 0 && owner.worker.statistics.paneDraws >= 2
        }
        // Verify both cached panes pass through the actual final Metal shader.
        try assertColors(owner.worker, split: 0.5)
        try await wait { owner.worker.isIdle }
        let completedBeforeInput = owner.worker.statistics.completed
        #expect(leftSurface.sendKeyEvent(.init(keyCode: 0, action: .press, text: "main-blocked")))
        // This synchronous wait deliberately holds the main actor. It can only
        // complete if the window render thread submits and completes independently.
        #expect(owner.worker.waitForCompletion(after: completedBeforeInput))
        try await wait { leftSurface.readContents(viewport: false).contains("main-blocked") && owner.worker.isIdle }
        let originalDraws = owner.worker.statistics.paneDraws
        let originalFrames = owner.worker.statistics.submitted
        // Layout-only frames must compose cached panes without redrawing content.
        for _ in 0..<6 { owner.updateGeometry(); await Task.yield() }
        try await wait { owner.worker.statistics.submitted > originalFrames }
        #expect(owner.worker.statistics.paneDraws == originalDraws)

        let beforeResize = owner.worker.statistics.paneDraws
        left.frame.size.width = 160
        right.frame = CGRect(x: 160, y: 0, width: 320, height: 240)
        left.sizeDidChange(left.bounds.size)
        right.sizeDidChange(right.bounds.size)
        owner.updateGeometry()
        try await wait { owner.worker.statistics.paneDraws >= beforeResize + 2 }
        try assertColors(owner.worker, split: 1.0 / 3)

        right.removeFromSuperview()
        second.contentView?.addSubview(right)
        right.frame = second.contentView!.bounds
        second.orderFront(nil)
        right.sizeDidChange(right.bounds.size)
        rightSurface.setVisible(true)
        let destination = try #require(right.windowCompositor)
        destination.updateGeometry()
        #expect(destination !== owner)
        #expect(right.surfaceModel === rightSurface)
        #expect(owner.worker.paneCount == 1)
        #expect(destination.worker.paneCount == 1)
        #expect(rightSurface.sendKeyEvent(.init(keyCode: 0, action: .press, text: "after-move")))
        try await wait {
            rightSurface.readContents(viewport: false).contains("after-move") &&
            destination.worker.statistics.displayed > 0
        }
        // A temporary empty hierarchy during a SwiftUI rebuild retains the
        // window's compositor while preserving the detached terminal session.
        left.removeFromSuperview()
        #expect(owner.worker.paneCount == 0)
        content.addSubview(left)
        #expect(left.windowCompositor === owner)
        #expect(left.surfaceModel === leftSurface)
        leftSurface.setVisible(true)
        left.sizeDidChange(left.bounds.size)
        // Closing one window must not invalidate the surviving queue or session.
        second.close()
        let before = owner.worker.statistics.submitted
        #expect(leftSurface.sendKeyEvent(.init(keyCode: 0, action: .press, text: "after-close")))
        try await wait { leftSurface.readContents(viewport: false).contains("after-close") && owner.worker.statistics.submitted > before }
        #expect(owner.worker.statistics.failed == 0)
        #expect(destination.worker.statistics.failed == 0)
    }

    @Test func closeReleasesSessionEvenWhileLayerRemainsRetained() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cghostty-window-close-\(UUID().uuidString)")
        let config = try TemporaryConfig("""
        render-presentation = window-compositor
        cursor-style-blink = false
        cursor-effect = false
        render-trace = true
        render-trace-directory = \(directory.path)
        """)
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        var view: Ghostty.SurfaceView? = makeView(app: app, color: "255;0;0", marker: "close-ready")
        weak let weakSurface = view?.surfaceModel
        let window = makeWindow()
        defer { window.close() }
        window.contentView = view
        window.orderFront(nil)
        view?.sizeDidChange(window.contentView!.bounds.size)
        view?.surfaceModel?.setVisible(true)
        let owner = try #require(view?.windowCompositor)
        owner.updateGeometry()
        try await wait { owner.worker.statistics.displayed > 0 && owner.worker.isIdle }
        window.close()
        window.contentView = nil
        view = nil
        try await wait { weakSurface == nil }
        #expect(owner.worker.paneCount == 0)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.contains { (try? String(contentsOf: $0, encoding: .utf8).contains("displayed,")) == true })
    }

    private func assertColors(_ worker: WindowCompositorWorker, split: Double) throws {
        let image = try worker.readback()
        let y = image.height / 2
        let left = (y * image.width + Int(Double(image.width) * split / 2)) * 4
        let right = (y * image.width + Int(Double(image.width) * (1 + split) / 2)) * 4
        func color(_ offset: Int) throws -> NSColor {
            try #require(NSColor(displayP3Red: CGFloat(image.pixels[offset + 2]) / 255,
                green: CGFloat(image.pixels[offset + 1]) / 255, blue: CGFloat(image.pixels[offset]) / 255,
                alpha: CGFloat(image.pixels[offset + 3]) / 255).usingColorSpace(.sRGB))
        }
        let red = try color(left)
        let green = try color(right)
        #expect(red.redComponent > 0.95 && red.greenComponent < 0.05 && red.blueComponent < 0.05)
        #expect(green.greenComponent > 0.95 && green.redComponent < 0.05 && green.blueComponent < 0.05)
    }

    private func makeView(app: Ghostty.App, color: String, marker: String) -> Ghostty.SurfaceView {
        var config = Ghostty.SurfaceConfiguration()
        let output = "\u{1b}[48;2;\(color)m\u{1b}[2J\(marker)"
        let encoded = Data(output.utf8).base64EncodedString()
        config.command = "/bin/sh -c '/bin/stty raw -echo; printf %s \(encoded) | /usr/bin/base64 -D; exec /bin/cat'"
        config.workingDirectory = FileManager.default.temporaryDirectory.path
        return Ghostty.SurfaceView(app, baseConfig: config)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 480, height: 240),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !predicate() {
            try #require(ContinuousClock.now < deadline, "Window compositor made no progress")
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
