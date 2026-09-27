import AppKit
import Metal
import QuartzCore
import Testing
@testable import Ghostty

@Suite(.serialized)
@MainActor struct MetalDisplayLinkTests {
    @Test(arguments: ["iosurface", "metal-1", "metal-2"], [false, true])
    func drawablesContinueAfterIdleResizeAndReattachment(backend: String, motion: Bool) async throws {
        let latency = backend == "metal-2" ? 2 : 1
        let metal = backend != "iosurface"
        let traceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cghostty-displaylink-\(backend)-\(motion ? "motion" : "content")-\(UUID().uuidString)")
        print("Display link validation trace: \(traceDirectory.path)")
        print("Display link environment: \(ProcessInfo.processInfo.operatingSystemVersionString), " +
              "screen maximum FPS \(NSScreen.main?.maximumFramesPerSecond ?? 0), " +
              "scale \(NSScreen.main?.backingScaleFactor ?? 0)")
        let device = try #require(MTLCreateSystemDefaultDevice())
        try #require(device.supportsFamily(.metal4))
        _ = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
        let config = try TemporaryConfig("""
        render-presentation = \(metal ? "metal-display-link" : "iosurface")
        render-frame-latency = \(latency)
        cursor-style-blink = false
        cursor-effect = \(motion)
        shell-integration = none
        render-trace = true
        render-trace-directory = \(traceDirectory.path)
        """)
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        var base = Ghostty.SurfaceConfiguration()
        base.command = "/bin/sh -c '/bin/stty raw -echo && printf ready-metal && exec /bin/cat'"
        base.workingDirectory = FileManager.default.temporaryDirectory.path
        let view = Ghostty.SurfaceView(app, baseConfig: base)
        let surface = try #require(view.surfaceModel)
        let layer = view.layer as? CAMetalLayer
        #expect((layer != nil) == metal)
        if let layer { #expect(!layer.presentsWithTransaction) }
        let first = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
                             styleMask: .borderless, backing: .buffered, defer: false)
        let second = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 560, height: 280),
                              styleMask: .borderless, backing: .buffered, defer: false)
        first.isReleasedWhenClosed = false
        second.isReleasedWhenClosed = false
        defer { first.close(); second.close() }
        first.contentView = view
        first.orderFront(nil)
        view.sizeDidChange(first.contentView!.bounds.size)
        surface.setVisible(true)
        try await wait { surface.readContents(viewport: false).contains("ready-metal") && surface.renderRevision > 0 }
        // More than the drawable pool size. Each round needs a fresh drawable
        // after its predecessor completed, including the paused idle path.
        for round in 0..<220 {
            let revision = surface.renderRevision
            let marker = "frame-\(round);"
            #expect(surface.sendKeyEvent(.init(keyCode: 0, action: .press, text: marker)))
            try await wait { surface.readContents(viewport: false).contains(marker) && surface.renderRevision > revision }
        }
        surface.setVisible(false)
        first.contentView = nil
        second.contentView = view
        second.orderFront(nil)
        view.sizeDidChange(second.contentView!.bounds.size)
        surface.setVisible(true)
        let revision = surface.renderRevision
        #expect(surface.sendKeyEvent(.init(keyCode: 0, action: .press, text: "moved-metal")))
        try await wait { surface.readContents(viewport: false).contains("moved-metal") && surface.renderRevision > revision }
        #expect(view.healthy)
        if let layer { #expect(layer.drawableSize.width > 0 && layer.drawableSize.height > 0) }
    }

    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !predicate() {
            try #require(ContinuousClock.now < deadline, "Metal display link failed to produce a completed frame")
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    // A minimal control: no terminal, libxev, renderer semaphore or Metal 4
    // resource manager. Distinguishes application work from OS scheduling.
    @Test(arguments: [Float(1), Float(2)], [false, true])
    func clearOnlyReference(latency: Float, requestMaximumRate: Bool) async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.drawableSize = CGSize(width: 480, height: 240)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 240))
        view.wantsLayer = true
        view.layer = layer
        let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { window.close() }
        let probe = ClearProbe(queue: queue)
        let link = CAMetalDisplayLink(metalLayer: layer)
        link.delegate = probe
        link.preferredFrameLatency = latency
        let maximum = Float(window.screen?.maximumFramesPerSecond ?? 60)
        if requestMaximumRate {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: maximum, maximum: maximum, preferred: maximum)
        }
        link.add(to: .main, forMode: .default)
        defer { link.invalidate() }
        try await wait { probe.samples.count == ClearProbe.frameCount || probe.failed }
        #expect(!probe.failed)
        #expect(probe.samples.filter { $0["displayed"]! > 0 }.count >= 220)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cghostty-displaylink-reference-\(Int(latency))-\(requestMaximumRate ? "max" : "default")-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result: [String: Any] = ["latency": link.preferredFrameLatency,
                                     "requestedMaximum": requestMaximumRate,
                                     "screenMaximumFPS": maximum,
                                     "samples": probe.samples]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("samples.json"))
        print("Display link reference trace: \(directory.path)")
    }

    private final class ClearProbe: NSObject, CAMetalDisplayLinkDelegate {
        static let frameCount = 240
        let queue: any MTLCommandQueue
        var submitted = 0
        var samples: [[String: Double]] = []
        var failed = false

        init(queue: any MTLCommandQueue) { self.queue = queue }

        func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
            guard submitted < Self.frameCount else { link.isPaused = true; return }
            let callback = CACurrentMediaTime()
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = update.drawable.texture
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].storeAction = .store
            descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.1, 0.2, 0.3, 1)
            guard let buffer = queue.makeCommandBuffer(),
                  let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                failed = true
                link.isPaused = true
                return
            }
            encoder.endEncoding()
            let sequence = submitted
            submitted += 1
            let deadline = update.targetTimestamp
            let prediction = update.targetPresentationTimestamp
            let submit = CACurrentMediaTime()
            update.drawable.addPresentedHandler { [weak self] drawable in
                let displayed = drawable.presentedTime
                Task { @MainActor in
                    self?.samples.append(["sequence": Double(sequence), "callback": callback,
                                          "deadline": deadline, "prediction": prediction,
                                          "submit": submit, "displayed": displayed])
                }
            }
            buffer.present(update.drawable)
            buffer.commit()
        }
    }
}
