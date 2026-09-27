import AppKit
import GhosttyKit
import Metal
import QuartzCore
import Testing
import Synchronization
@testable import Ghostty

@Suite(.serialized, .enabled(if: try MetalTestSupport.metal4Available(), "Requires a Metal 4 GPU"))
@MainActor struct WindowCompositorTests {
    @Test(arguments: ["native", "linear", "linear-corrected"], [1, 2])
    func panesShareClockCacheAndMoveWithoutLosingSession(blending: String, latency: Int) async throws {
        let traceDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("cghostty-window-\(blending)-\(UUID().uuidString)")
        print("Window compositor trace: \(traceDirectory.path)")
        let config = try TemporaryConfig("""
        cursor-style-blink = false
        cursor-effect = false
        shell-integration = none
        alpha-blending = \(blending)
        render-frame-latency = \(latency)
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
        #expect(leftSurface.compositorInfo.latency == Float(latency))
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
        // Shared-texture snapshots preserve P3 color in every blending mode.
        for (view, red) in [(left, true), (right, false)] {
            let png = try #require(view.thumbnailPNG())
            let bitmap = try #require(NSBitmapImageRep(data: png))
            #expect(bitmap.colorSpace == .sRGB)
            // colorAt returns device RGB and can apply the display profile a
            // second time. Check decoded samples in the PNG's declared space.
            var pixel = [UInt](repeating: 0, count: 4)
            bitmap.getPixel(&pixel, atX: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)
            #expect(pixel[3] > 252)
            #expect(pixel[red ? 0 : 1] > 242)
            #expect(pixel[red ? 1 : 0] < 13)
        }
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

    @Test func contentUpdatesCoalesceUntilWindowClockResumes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cghostty-frame-clock-\(UUID().uuidString)")
        print("Window frame clock trace: \(directory.path)")
        let config = try TemporaryConfig("""
        cursor-style-blink = false
        cursor-effect = false
        shell-integration = none
        render-trace = true
        render-trace-directory = \(directory.path)
        """)
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        var view: Ghostty.SurfaceView? = makeView(app: app, color: "255;0;0", marker: "clock-ready")
        weak let surface = view?.surfaceModel
        let window = makeWindow()
        defer { window.close() }
        window.contentView = view
        window.orderFront(nil)
        view?.sizeDidChange(window.contentView!.bounds.size)
        surface?.setVisible(true)
        let owner = try #require(view?.windowCompositor)
        owner.updateGeometry()
        try await wait { surface?.readContents(viewport: false).contains("clock-ready") == true && owner.worker.isIdle }
        owner.worker.pauseUpdatesForTesting(true)
        let before = owner.worker.statistics.paneDraws
        // Each round waits for real PTY output. The producer can run hundreds of
        // times while the window clock is held, without rebuilding cells.
        for index in 0..<200 {
            if index == 50 { #expect(surface?.changeFontSize(by: 1) == true) }
            if index == 100 { #expect(surface?.search("burst") == true) }
            if index == 150 {
                #expect(surface?.perform(.resetFontSize) == true)
                #expect(surface?.endSearch() == true)
            }
            let marker = "burst-\(index) "
            #expect(surface?.sendKeyEvent(.init(keyCode: 0, action: .press, text: marker)) == true)
            try await wait { surface?.readContents(viewport: false).contains(marker) == true }
        }
        #expect(owner.worker.statistics.paneDraws == before)
        owner.worker.pauseUpdatesForTesting(false)
        try await wait { owner.worker.statistics.paneDraws > before && owner.worker.isIdle }
        // Hidden content catches up when it becomes visible again.
        surface?.setVisible(false)
        #expect(surface?.sendKeyEvent(.init(keyCode: 0, action: .press, text: "hidden-output")) == true)
        try await wait { surface?.readContents(viewport: false).contains("hidden-output") == true }
        surface?.setVisible(true)
        let resumed = owner.worker.statistics.submitted
        owner.updateGeometry()
        try await wait { owner.worker.statistics.submitted > resumed && owner.worker.isIdle }
        #expect(owner.worker.statistics.failed == 0)
        window.close()
        window.contentView = nil
        view = nil
        try await wait { surface == nil }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let lines = try files.flatMap { try String(contentsOf: $0, encoding: .utf8).split(separator: "\n").map(String.init) }
        let updates = lines.filter { $0.hasPrefix("compositor_update,") }.map { $0.split(separator: ",") }
        #expect(updates.count > 0)
        #expect(updates.contains { UInt64($0[2])! > 1 })
        // Frame sequence is global; a pane must never rebuild twice in one tick.
        #expect(Set(updates.map { $0[3] }).count == updates.count)
        print("Frame-clock trace complete: \(!lines.contains { $0.hasPrefix("trace_drop,") })")
        let ticks = Set(lines.filter { $0.hasPrefix("metal_tick,") }.map { $0.split(separator: ",")[4] })
        #expect(updates.allSatisfy { ticks.contains($0[3]) })
        print("Window clock updates: \(updates.count), merged requests: \(updates.map { UInt64($0[2])! }.max() ?? 0)")
    }

    @Test(arguments: ["cursor", "kitty"])
    func animationDeadlinesKeepWorkingWithoutNewOutput(animation: String) async throws {
        let config = try TemporaryConfig("""
        cursor-style-blink = \(animation == "cursor")
        cursor-effect = false
        shell-integration = none
        """)
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        // Two frames, 150 ms each, two complete loops, then stop. Image timers
        // must wake an idle window without relying on fresh terminal output.
        let kitty = "\u{1b}[H\u{1b}_Ga=T,f=32,s=1,v=1,i=1,q=2,c=4,r=2;/wAA/w==\u{1b}\\" +
            "\u{1b}_Ga=f,i=1,f=32,s=1,v=1,z=150,q=2;AP8A/w==\u{1b}\\" +
            "\u{1b}_Ga=a,i=1,r=1,z=150,s=3,v=3,q=2\u{1b}\\"
        let view = makeView(app: app, color: "0;0;0", marker: "animation-ready" + (animation == "kitty" ? kitty : ""))
        let surface = try #require(view.surfaceModel)
        let window = makeWindow()
        defer { window.close() }
        window.contentView = view
        window.orderFront(nil)
        view.sizeDidChange(window.contentView!.bounds.size)
        surface.setVisible(true)
        surface.setFocus(true)
        let owner = try #require(view.windowCompositor)
        owner.updateGeometry()
        try await wait {
            surface.readContents(viewport: false).contains("animation-ready") &&
            owner.worker.statistics.paneDraws > 0 && owner.worker.isIdle
        }
        // Frame counters alone could pass on duplicate startup submissions.
        // Require the composed pixels to change and return with no new output.
        let initialPixels = try owner.worker.readback().pixels
        try await wait { try owner.worker.readback().pixels != initialPixels }
        try await wait { try owner.worker.readback().pixels == initialPixels }
        if animation == "cursor" { surface.setFocus(false) }
        try await wait { owner.worker.isIdle }
        #expect(owner.worker.statistics.failed == 0)
    }

    @Test func sharedTextureSnapshotPreservesAlphaAndOutlivesSession() async throws {
        let config = try TemporaryConfig("""
        background = #123456
        background-opacity = 0.5
        background-blur = false
        cursor-style-blink = false
        cursor-effect = false
        shell-integration = none
        """)
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        var base = Ghostty.SurfaceConfiguration()
        base.command = "/bin/sh -c 'printf snapshot-ready; exec /bin/cat'"
        var view: Ghostty.SurfaceView? = Ghostty.SurfaceView(app, baseConfig: base)
        weak let surface = view?.surfaceModel
        let window = makeWindow()
        defer { window.close() }
        window.contentView = view
        window.orderFront(nil)
        view?.sizeDidChange(window.contentView!.bounds.size)
        surface?.setVisible(true)
        let owner = try #require(view?.windowCompositor)
        owner.updateGeometry()
        try await wait {
            surface?.readContents(viewport: false).contains("snapshot-ready") == true &&
            owner.worker.statistics.paneDraws > 0 && owner.worker.isIdle
        }
        let snapshot = try #require(surface?.copySnapshot())
        window.close()
        window.contentView = nil
        view = nil
        try await wait { surface == nil }
        let bitmap = NSBitmapImageRep(cgImage: snapshot)
        let color = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
        #expect(abs(color.alphaComponent - 0.5) < 0.02)
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
    }

    @Test func membershipAndCloseDoNotWaitForFramePreparation() async throws {
        let config = try TemporaryConfig("cursor-style-blink = false\ncursor-effect = false")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let view = makeView(app: app, color: "255;0;0", marker: "lock-ready")
        let window = makeWindow()
        let destination = makeWindow()
        defer { window.close(); destination.close() }
        view.frame = window.contentView!.bounds
        window.contentView?.addSubview(view)
        window.orderFront(nil)
        view.sizeDidChange(window.contentView!.bounds.size)
        view.surfaceModel?.setVisible(true)
        let owner = try #require(view.windowCompositor)
        owner.updateGeometry()
        try await wait {
            guard view.surfaceModel?.readContents(viewport: false).contains("lock-ready") == true,
                  owner.worker.statistics.displayed > 0, owner.worker.isIdle else { return false }
            return try centerIsRed(owner.worker)
        }
        let entered = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        owner.worker.beforeNextPrepareForTesting {
            entered.withLock { $0 = true }
            // Timeout is only a deadlock guard; readiness and release are explicit.
            _ = release.wait(timeout: .now() + 3)
        }
        try await wait { entered.withLock { $0 } }
        let start = CACurrentMediaTime()
        owner.updateGeometry()
        view.removeFromSuperview()
        destination.contentView?.addSubview(view)
        destination.orderFront(nil)
        view.surfaceModel?.setVisible(true)
        let moved = try #require(view.windowCompositor)
        moved.updateGeometry()
        window.close()
        let elapsed = CACurrentMediaTime() - start
        print("Membership/update/remove/stop while worker held: \(elapsed * 1000) ms")
        #expect(elapsed < 0.5, "Main must return before the blocked frame's 3 second guard")
        #expect(owner.worker.paneCount == 0)
        release.signal()
        try await wait { moved.worker.statistics.displayed > 0 && moved.worker.isIdle }
        #expect(moved !== owner)
        #expect(try centerIsRed(moved.worker))
        #expect(view.surfaceModel?.sendKeyEvent(.init(keyCode: 0, action: .press, text: "after-blocked-move")) == true)
        try await wait { view.surfaceModel?.readContents(viewport: false).contains("after-blocked-move") == true }
        #expect(moved.worker.statistics.failed == 0)
    }

    @Test(arguments: [false, true])
    func controlledEchoPresentationProbes(animated: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cghostty-probe-\(animated ? "active" : "idle")-\(UUID().uuidString)")
        print("Input probe trace: \(directory.path)")
        let config = try TemporaryConfig("""
        cursor-style-blink = false
        cursor-effect = \(animated)
        shell-integration = none
        render-trace = true
        render-trace-directory = \(directory.path)
        """)
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        var view: Ghostty.SurfaceView? = makeView(app: app, color: "0;0;0", marker: "probe-ready")
        weak let surface = view?.surfaceModel
        let window = makeWindow()
        defer { window.close() }
        window.contentView = view
        window.orderFront(nil)
        view?.sizeDidChange(window.contentView!.bounds.size)
        surface?.setVisible(true)
        surface?.setFocus(true)
        let owner = try #require(view?.windowCompositor)
        owner.updateGeometry()
        try await wait { surface?.readContents(viewport: false).contains("probe-ready") == true && owner.worker.isIdle }
        if animated {
            #expect(surface?.sendKeyEvent(.init(keyCode: 0, action: .press, text: "animation-warmup ")) == true)
            try await wait { surface?.readContents(viewport: false).contains("animation-warmup") == true }
        }
        for index in 1...200 {
            if !animated { try await wait { owner.worker.isIdle } }
            let marker = "probe-\(index)-end "
            surface?.traceCompositor(stage: 6, sequence: UInt64(index), time: CACurrentMediaTime())
            #expect(surface?.sendKeyEvent(.init(keyCode: 0, action: .press, text: marker)) == true)
            try await wait { surface?.readContents(viewport: false).contains(marker) == true }
            surface?.traceCompositor(stage: 7, sequence: UInt64(index), time: 0)
        }
        try await wait { owner.worker.isIdle }
        window.close()
        window.contentView = nil
        view = nil
        try await wait { surface == nil }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let text = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        // Telemetry is deliberately nonblocking and may drop records. The
        // summarizer reports completeness; correctness never depends on logging.
        #expect(text.contains("input_probe,"))
        #expect(text.contains("input_ready,"))
        #expect(text.contains("pane_content,"))
        print("Input probe records: \(text.components(separatedBy: "input_probe,").count - 1)/200; trace complete: \(!text.contains("trace_drop,"))")
    }

    @Test(arguments: [1, 4])
    func multilingualPreparationWorkload(paneCount: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cghostty-prepare-\(paneCount)-\(UUID().uuidString)")
        print("Preparation workload trace: \(directory.path)")
        let config = try TemporaryConfig("""
        cursor-style-blink = false
        cursor-effect = false
        shell-integration = none
        render-trace = true
        render-trace-directory = \(directory.path)
        """)
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let window = makeWindow()
        defer { window.close() }
        var views = (0..<paneCount).map { makeView(app: app, color: "0;0;0", marker: "prepare-ready-\($0)") }
        weak let first = views.first?.surfaceModel
        let content = try #require(window.contentView)
        for (index, view) in views.enumerated() {
            view.frame = CGRect(x: 0, y: index * 240 / paneCount, width: 480, height: 240 / paneCount)
            content.addSubview(view)
            view.sizeDidChange(view.bounds.size)
            view.surfaceModel?.setVisible(true)
        }
        window.orderFront(nil)
        let owner = try #require(views.first?.windowCompositor)
        owner.updateGeometry()
        try await wait { owner.worker.statistics.paneDraws >= paneCount }
        for round in 0..<100 {
            for (index, view) in views.enumerated() {
                // Separate glyph streams prevent four panes from merely sharing
                // the first pane's cold rasterization work in this workload.
                let chinese = String(String.UnicodeScalarView((0..<60).compactMap {
                    UnicodeScalar(0x4e00 + (round * 60 + index * 1500 + $0) % 6000)
                }))
                let marker = "round-\(round)-pane-\(index)-end"
                #expect(view.surfaceModel?.sendKeyEvent(.init(keyCode: 0, action: .press, text: "\r\n\(chinese)\r\n\(marker)")) == true)
            }
            try await wait {
                views.enumerated().allSatisfy { index, view in
                    view.surfaceModel?.readContents(viewport: false).contains("round-\(round)-pane-\(index)-end") == true
                }
            }
        }
        try await wait { owner.worker.isIdle }
        #expect(owner.worker.statistics.failed == 0)
        window.close()
        views.forEach { $0.removeFromSuperview() }
        views.removeAll()
        try await wait { first == nil }
    }

    @Test(arguments: ["cursor", "scroll"], ["native", "linear", "linear-corrected"])
    func finalCompositionAnimatesWithoutRepaintingContent(animation: String, blending: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cghostty-final-\(animation)-\(blending)-\(UUID().uuidString)")
        print("Final composition trace: \(directory.path)")
        let config = try TemporaryConfig("""
        cursor-style-blink = false
        cursor-effect = true
        smooth-scroll = true
        alpha-blending = \(blending)
        shell-integration = none
        render-trace = true
        render-trace-directory = \(directory.path)
        """)
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let left = makeView(app: app, color: "0;255;0", marker: "left-static")
        let right = makeView(app: app, color: "255;0;0", marker: "right-ready")
        let surface = try #require(right.surfaceModel)
        let window = makeWindow()
        defer { window.close() }
        let content = try #require(window.contentView)
        left.frame = CGRect(x: 0, y: 0, width: 240, height: 240)
        right.frame = CGRect(x: 240, y: 0, width: 240, height: 240)
        content.addSubview(left)
        content.addSubview(right)
        window.orderFront(nil)
        for view in [left, right] {
            view.sizeDidChange(view.bounds.size)
            view.surfaceModel?.setVisible(true)
        }
        surface.setFocus(animation == "cursor")
        let owner = try #require(right.windowCompositor)
        owner.updateGeometry()
        try await wait { surface.readContents(viewport: false).contains("right-ready") && owner.worker.isIdle }
        // Distinct rows make scroll motion visible; the neighboring pane must
        // remain pixel-identical throughout final-pass viewport/scissor changes.
        #expect(surface.sendKeyEvent(.init(keyCode: 0, action: .press,
            text: "\u{1b}[?1049h\u{1b}[2J\u{1b}[Hone\r\ntwo\r\nthree\r\nfour\r\nfive\r\nsix")))
        try await wait { surface.readContents(viewport: false).contains("six") && owner.worker.isIdle }
        let baseline = try owner.worker.readback()
        let before = owner.worker.statistics.submitted
        let initialContent = owner.worker.statistics.paneDraws
        let command = animation == "cursor" ? "\u{1b}[2;12H" : "\u{1b}[2;6r\u{1b}[6;1H\n"
        #expect(surface.sendKeyEvent(.init(keyCode: 0, action: .press, text: command)))
        if animation == "scroll" {
            try await wait { owner.worker.statistics.paneDraws > initialContent }
            owner.worker.pauseUpdatesForTesting(true)
            try await wait { owner.worker.isIdle }
        } else {
            try await wait { owner.worker.statistics.submitted >= before + 3 }
        }
        let during = try owner.worker.readback()
        #expect(during.pixels != baseline.pixels)
        for y in 0..<baseline.height {
            let offset = y * baseline.width * 4
            #expect(during.pixels[offset..<(offset + baseline.width * 2)] == baseline.pixels[offset..<(offset + baseline.width * 2)])
        }
        if animation == "scroll" {
            // Reverse while in flight: freeze the preceding composed contents
            // only at this interruption, never on each animation tick.
            #expect(surface.sendKeyEvent(.init(keyCode: 0, action: .press, text: "\u{1b}[1T\u{1b}[6;1Hreversed")))
            try await wait { surface.readContents(viewport: false).contains("reversed") }
            owner.worker.pauseUpdatesForTesting(false)
            let reversed = owner.worker.statistics.submitted
            try await wait { owner.worker.statistics.submitted >= reversed + 3 }
        }
        let contentDraws = owner.worker.statistics.paneDraws
        let frames = owner.worker.statistics.submitted
        try await wait { owner.worker.isIdle }
        #expect(owner.worker.statistics.submitted > frames)
        #expect(owner.worker.statistics.paneDraws == contentDraws)
        #expect(owner.worker.statistics.failed == 0)
    }

    private func centerIsRed(_ worker: WindowCompositorWorker) throws -> Bool {
        let image = try worker.readback()
        let pixel = (image.height / 2 * image.width + image.width / 2) * 4
        // The window texture is Display P3; compare in sRGB like assertColors.
        let color = try #require(NSColor(displayP3Red: CGFloat(image.pixels[pixel + 2]) / 255,
            green: CGFloat(image.pixels[pixel + 1]) / 255, blue: CGFloat(image.pixels[pixel]) / 255,
            alpha: CGFloat(image.pixels[pixel + 3]) / 255).usingColorSpace(.sRGB))
        return color.redComponent > 0.95 && color.greenComponent < 0.05 && color.blueComponent < 0.05
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

    private func wait(_ predicate: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while try !predicate() {
            try #require(ContinuousClock.now < deadline, "Window compositor made no progress")
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
