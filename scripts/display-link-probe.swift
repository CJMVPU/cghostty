// Standalone frontmost AppKit probe. Build with swiftc -O -parse-as-library.
// Arguments: output.json metal|view opaque|transparent glass|plain 2|3 1|2
import AppKit
import Metal
import QuartzCore

@main @MainActor final class DisplayLinkProbe: NSObject, NSApplicationDelegate, @MainActor CAMetalDisplayLinkDelegate {
    private var window: NSWindow!
    private var view: NSView!
    private let layer = CAMetalLayer()
    private var queue: (any MTLCommandQueue)!
    private var metalLink: CAMetalDisplayLink?
    private var viewLink: CADisplayLink?
    private var callbacks = 0
    private var submitted = 0
    private var samples: [[String: Any]] = []
    private var output = ""
    private var mode = "metal"
    private var timeout: Timer?
    private var finished = false
    private var started = CACurrentMediaTime()
    private let count = 240

    static func main() {
        let app = NSApplication.shared
        let delegate = DisplayLinkProbe()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        guard args.count == 7, ["metal", "view"].contains(args[2]),
              ["opaque", "transparent"].contains(args[3]), ["glass", "plain"].contains(args[4]),
              let drawables = Int(args[5]), [2, 3].contains(drawables),
              let latency = Float(args[6]), [1, 2].contains(latency),
              let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fputs("Usage: probe output.json metal|view opaque|transparent glass|plain 2|3 1|2\n", stderr)
            exit(2)
        }
        output = args[1]
        mode = args[2]
        self.queue = queue
        window = NSWindow(contentRect: CGRect(x: 180, y: 180, width: 480, height: 240),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "cghostty display timing probe"
        window.isReleasedWhenClosed = false
        window.isOpaque = args[3] == "opaque"
        window.backgroundColor = .clear
        let content = window.contentView!
        if args[4] == "glass" {
            let glass = NSGlassEffectView(frame: content.bounds)
            glass.autoresizingMask = [.width, .height]
            content.addSubview(glass)
        }
        view = NSView(frame: content.bounds)
        view.wantsLayer = true
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.isOpaque = args[3] == "opaque"
        layer.maximumDrawableCount = drawables
        layer.presentsWithTransaction = false
        view.layer = layer
        content.addSubview(view)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        let scale = window.backingScaleFactor
        layer.contentsScale = scale
        layer.drawableSize = CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
        if mode == "metal" {
            let link = CAMetalDisplayLink(metalLayer: layer)
            link.preferredFrameLatency = latency
            link.delegate = self
            link.add(to: .main, forMode: .common)
            metalLink = link
        } else {
            let link = view.displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            viewLink = link
        }
        started = CACurrentMediaTime()
        timeout = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finish(error: "Timed out before all presentation callbacks") }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        window?.makeKeyAndOrderFront(nil)
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        callbacks += 1
        draw(update.drawable, callback: CACurrentMediaTime(), deadline: update.targetTimestamp,
             prediction: update.targetPresentationTimestamp, acquire: 0)
    }

    @objc private func tick(_ link: CADisplayLink) {
        callbacks += 1
        guard submitted < count else { link.isPaused = true; return }
        let callback = CACurrentMediaTime()
        guard let drawable = layer.nextDrawable() else { finish(error: "nextDrawable returned nil"); return }
        draw(drawable, callback: callback, deadline: link.targetTimestamp,
             prediction: 0, acquire: CACurrentMediaTime() - callback)
    }

    private func draw(_ drawable: any CAMetalDrawable, callback: Double, deadline: Double, prediction: Double, acquire: Double) {
        guard submitted < count else { metalLink?.isPaused = true; viewLink?.isPaused = true; return }
        // Wait for actual activation, not an arbitrary delay. Record focus per sample.
        guard NSApp.isActive, window.isKeyWindow else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(Double(submitted % 2), 0.2, 0.3, layer.isOpaque ? 1 : 0.8)
        guard let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else {
            finish(error: "Command buffer or encoder creation failed"); return
        }
        encoder.endEncoding()
        let sequence = submitted
        submitted += 1
        let submit = CACurrentMediaTime()
        let active = NSApp.isActive
        let key = window.isKeyWindow
        drawable.addPresentedHandler { [weak self] drawable in
            let time = drawable.presentedTime
            Task { @MainActor in
                guard let self else { return }
                self.samples.append(["sequence": sequence, "callback": callback, "deadline": deadline,
                                "prediction": prediction, "submit": submit, "displayed": time,
                                "acquire": acquire, "active": active, "key": key])
                if self.samples.count == self.count { self.finish(error: nil) }
            }
        }
        buffer.present(drawable)
        buffer.commit()
    }

    private func finish(error: String?) {
        guard !finished else { return }
        finished = true
        metalLink?.invalidate()
        viewLink?.invalidate()
        timeout?.invalidate()
        let screen = window.screen
        let data: [String: Any] = ["arguments": Array(CommandLine.arguments.dropFirst(2)),
            "os": ProcessInfo.processInfo.operatingSystemVersionString, "device": layer.device?.name ?? "none",
            "screen": screen?.localizedName ?? "none", "screenMaximumFPS": screen?.maximumFramesPerSecond ?? 0,
            "backingScale": window.backingScaleFactor, "elapsed": CACurrentMediaTime() - started,
            "submitted": submitted, "callbacks": callbacks, "activeAtEnd": NSApp.isActive, "keyAtEnd": window.isKeyWindow, "error": error ?? "", "warmupFrames": 20, "samples": samples]
        do {
            try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: output))
        } catch { fputs("Failed to write probe results: \(error)\n", stderr); exit(1) }
        NSApp.terminate(nil)
    }
}
