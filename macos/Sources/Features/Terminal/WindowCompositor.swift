import AppKit
import Metal
import QuartzCore
import Synchronization

/// Main-thread geometry and membership. The worker receives values, never NSViews.
/// Each window owns one layer, one display link and one Metal 4 submission queue.
final class WindowCompositor {
    private static let owners = NSMapTable<NSWindow, WindowCompositor>.weakToStrongObjects()
    private weak var window: NSWindow?
    private var views: [UUID: WeakView] = [:]
    let host: HostView
    let worker: WindowCompositorWorker
    private var closeObserver: NSObjectProtocol?
    private var geometryObservers: [NSObjectProtocol] = []

    private struct WeakView { weak var value: Ghostty.SurfaceView? }

    static func attach(_ view: Ghostty.SurfaceView) -> WindowCompositor? {
        guard let window = view.window, let surface = view.surfaceModel,
              let content = window.contentView else { return nil }
        do {
            let owner: WindowCompositor
            if let existing = owners.object(forKey: window) {
                owner = existing
            } else {
                owner = try WindowCompositor(window: window, content: content, latency: surface.compositorLatency)
                owners.setObject(owner, forKey: window)
            }
            owner.views[view.id] = WeakView(value: view)
            owner.worker.add(id: view.id, surface: surface)
            owner.updateGeometry()
            return owner
        } catch {
            view.healthy = false
            Ghostty.logger.error("Window compositor initialization failed: \(error)")
            return nil
        }
    }

    private init(window: NSWindow, content: NSView, latency: Float) throws {
        self.window = window
        worker = try WindowCompositorWorker(latency: latency)
        host = HostView(frame: content.bounds)
        host.layer = worker.layer
        host.wantsLayer = true
        host.autoresizingMask = [.width, .height]
        if let container = content as? TerminalViewContainer {
            container.installCompositorHost(host)
        } else {
            content.addSubview(host, positioned: .below, relativeTo: content.subviews.first)
        }
        host.owner = self
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification] {
            geometryObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateGeometry(forceRedraw: name == NSWindow.didChangeScreenNotification) }
            })
        }
        worker.start()
    }

    func detach(id: UUID) {
        views.removeValue(forKey: id)
        worker.remove(id: id)
        // SwiftUI can temporarily detach every pane while rebuilding its tree.
        // Keep the window clock/cache owner until the window actually closes.
        updateGeometry()
    }

    func updateGeometry(forceRedraw: Bool = false) {
        guard let window else { return }
        let scale = window.backingScaleFactor
        host.layer?.contentsScale = scale
        let size = CGSize(width: (host.bounds.width * scale).rounded(), height: (host.bounds.height * scale).rounded())
        var geometry: [UUID: WindowCompositorWorker.Geometry] = [:]
        for (id, reference) in views {
            guard let view = reference.value, view.window === window else { continue }
            // Host is flipped: both viewport and texture rows start at the top.
            let rect = host.convert(view.bounds, from: view)
            let clip = host.convert(view.visibleRect, from: view).intersection(host.bounds)
            geometry[id] = .init(rect: Self.pixels(rect, scale: scale), clip: Self.pixels(clip, scale: scale),
                                 visible: !view.isHiddenOrHasHiddenAncestor && window.occlusionState.contains(.visible))
        }
        worker.updateRefreshRate(Float(window.screen?.maximumFramesPerSecond ?? 60),
                                 screen: (window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0)
        worker.update(size: size, geometry: geometry, forceRedraw: forceRedraw)
    }

    private static func pixels(_ rect: CGRect, scale: CGFloat) -> CGRect {
        guard !rect.isNull, !rect.isInfinite else { return .zero }
        let origin = CGPoint(x: (rect.minX * scale).rounded(), y: (rect.minY * scale).rounded())
        return CGRect(x: origin.x, y: origin.y, width: (rect.maxX * scale).rounded() - origin.x,
                      height: (rect.maxY * scale).rounded() - origin.y)
    }

    isolated deinit {
        worker.stop()
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        geometryObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func close() {
        if let observer = closeObserver { NotificationCenter.default.removeObserver(observer); closeObserver = nil }
        geometryObservers.forEach { NotificationCenter.default.removeObserver($0) }
        geometryObservers.removeAll()
        worker.stop()
        host.removeFromSuperview()
        if let window { Self.owners.removeObject(forKey: window) }
        self.window = nil
        views.removeAll()
    }

    final class HostView: NSView {
        weak var owner: WindowCompositor?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() { super.layout(); owner?.updateGeometry() }
        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            owner?.updateGeometry(forceRedraw: true)
        }
    }
}

/// A retained Objective-C sink called by core update threads under draw_mutex.
/// It only schedules a coalesced run-loop wake, never takes the membership lock.
nonisolated final class WindowCompositorSignal: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var runLoop: CFRunLoop?
    private var action: (@Sendable () -> Void)?
    private var pending = false

    func install(runLoop: CFRunLoop?, action: (@Sendable () -> Void)?) {
        lock.lock()
        self.runLoop = runLoop
        self.action = action
        pending = false
        lock.unlock()
    }

    var hasPending: Bool { lock.withLock { pending } }

    @objc func requestFrame() {
        lock.lock()
        guard !pending, let runLoop else { lock.unlock(); return }
        pending = true
        lock.unlock()
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [self] in
            lock.lock()
            pending = false
            let callback = action
            lock.unlock()
            callback?()
        }
        CFRunLoopWakeUp(runLoop)
    }
}

/// Membership/geometry is a short-lock snapshot. Encoding and retirement stay
/// on the window worker; a per-surface gate serializes cross-window handoff.
nonisolated final class WindowCompositorWorker: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
    struct Geometry: Sendable, Equatable { var rect: CGRect; var clip: CGRect; var visible: Bool }
    struct Statistics: Sendable {
        var submitted = 0
        var completed = 0
        var displayed = 0
        var presentationCallbacks = 0
        var missedDeadlines = 0
        var failed = 0
        var paneDraws = 0
        var lastPresentedTime: Double = 0
    }
    /// Drawable callbacks may outlive a closed window. Never let them keep a
    /// PTY/session alive just to report a diagnostic timestamp.
    private final class TraceOwner: @unchecked Sendable {
        weak var surface: Ghostty.Surface?
        init(_ surface: Ghostty.Surface) { self.surface = surface }
    }
    private struct Pane {
        let token = UUID()
        let surface: Ghostty.Surface
        var geometry = Geometry(rect: .zero, clip: .zero, visible: false)
        #if CGHOSTTY_TESTING
        var initialized = false
        #endif
    }
    /// Encoding owns the slot until commit; completion clears its drawable
    /// reference before signalling availability. No concurrent field access.
    private final class Slot: @unchecked Sendable {
        let available = DispatchSemaphore(value: 1)
        let allocator: any MTL4CommandAllocator
        let buffer: any MTL4CommandBuffer
        let clearBuffer: any MTL4CommandBuffer
        let residency: any MTLResidencySet
        var drawableTexture: (any MTLTexture)?
        var surfaces: [Ghostty.Surface] = []
        let retirement: any MTLSharedEvent
        var retirementValue: UInt64 = 0
        init(device: any MTLDevice) throws {
            guard let allocator = device.makeCommandAllocator(), let buffer = device.makeCommandBuffer(),
                  let clearBuffer = device.makeCommandBuffer(), let retirement = device.makeSharedEvent() else {
                throw Failure.resource
            }
            self.allocator = allocator
            self.buffer = buffer
            self.clearBuffer = clearBuffer
            self.retirement = retirement
            residency = try device.makeResidencySet(descriptor: MTLResidencySetDescriptor())
        }
    }
    enum Failure: Error { case resource }
    let layer = CAMetalLayer()
    let signal = WindowCompositorSignal()
    private let device: any MTLDevice
    private let queue: any MTL4CommandQueue
    private let slots: [Slot]
    private let latency: Float
    private let lock = NSLock()
    private var panes: [UUID: Pane] = [:]
    private var retired: [Ghostty.Surface] = []
    #if CGHOSTTY_TESTING
    // Explicit test readback shares encoding state with the serial worker.
    private let encodingLock = NSLock()
    #endif
    private var paused = true
    private var size: CGSize = .zero
    private var stopping = false
    private var started = false
    private var loop: CFRunLoop?
    private var link: CAMetalDisplayLink?
    private var requestedRate: Float = 120
    private static let windowIDs = Mutex<UInt64>(0)
    private let windowID = windowIDs.withLock { $0 &+= 1; return $0 }

    private var requestedScreen: UInt32 = 0

    func updateRefreshRate(_ rate: Float, screen: UInt32) {
        let changed = lock.withLock {
            let changed = requestedRate != max(1, rate) || requestedScreen != screen
            requestedRate = max(1, rate)
            requestedScreen = screen
            return changed
        }
        if changed { signal.requestFrame() }
    }

    private func traceOwner() -> Ghostty.Surface? {
        lock.withLock { panes.keys.sorted { $0.uuidString < $1.uuidString }.first.flatMap { panes[$0]?.surface } }
    }
    private var index = 0
    private let inFlight = DispatchGroup()
    private static let sequences = Mutex<UInt64>(0)
    private let statsLock = NSLock()
    private var stats = Statistics()
    /// Transparent/covered layers may never produce a positive presentedTime.
    /// Retry transient startup drops, but never spin forever without new content.
    private var skippedRetryBudget = 4
    #if CGHOSTTY_TESTING
    private let completionCondition = NSCondition()
    private var testCompleted = 0
    private var testUpdatesPaused = false
    private var testBeforePrepare: (@Sendable () -> Void)?

    func beforeNextPrepareForTesting(_ action: @escaping @Sendable () -> Void) {
        lock.withLock { testBeforePrepare = action }
        signal.requestFrame()
    }

    /// Idle can precede the first drawable; tests must check each requested pane.
    func panesInitializedForTesting(_ ids: [UUID]) -> Bool {
        lock.withLock {
            !ids.isEmpty && ids.allSatisfy { id in
                guard let pane = panes[id] else { return false }
                return pane.initialized && pane.geometry.visible && !pane.geometry.clip.isEmpty
            }
        }
    }

    var stateForTesting: String {
        let snapshot = lock.withLock { (paused, testUpdatesPaused, size, panes) }
        let details = snapshot.3.keys.sorted { $0.uuidString < $1.uuidString }.map { id in
            let pane = snapshot.3[id]!
            return "pane=\(id), initialized=\(pane.initialized), visible=\(pane.geometry.visible), " +
                "rect=\(pane.geometry.rect), clip=\(pane.geometry.clip)"
        }.joined(separator: "\n")
        return "paused=\(snapshot.0), testUpdatesPaused=\(snapshot.1), pending=\(signal.hasPending), " +
            "size=\(snapshot.2)\n" + details
    }

    /// Simulates a delayed display clock while real PTY output keeps arriving.
    func pauseUpdatesForTesting(_ paused: Bool) {
        lock.withLock { testUpdatesPaused = paused }
        if !paused { signal.requestFrame() }
    }
    #endif

    var statistics: Statistics { statsLock.withLock { stats } }
    var paneCount: Int { lock.withLock { panes.count } }
    var isIdle: Bool {
        lock.withLock {
            let state = statistics
            return paused && !signal.hasPending && state.completed == state.submitted &&
                state.presentationCallbacks == state.submitted
        }
    }

    init(latency: Float) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeMTL4CommandQueue() else {
            throw Failure.resource
        }
        self.device = device
        self.queue = queue
        self.latency = latency
        slots = try (0..<3).map { _ in try Slot(device: device) }
        super.init()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        layer.isOpaque = false
        // Pane blending modes reinterpret the drawable as linear/sRGB views.
        // Metal forbids texture views of framebuffer-only drawables.
        layer.framebufferOnly = false
        #if CGHOSTTY_CLOCK_EXPERIMENT
        let count = Int(ProcessInfo.processInfo.environment["CGHOSTTY_CLOCK_DRAWABLES"] ?? "3") ?? 3
        layer.maximumDrawableCount = min(3, max(2, count))
        #endif
        layer.presentsWithTransaction = false
        queue.addResidencySet(layer.residencySet)
    }

    func add(id: UUID, surface: Ghostty.Surface) {
        surface.requestCompositor(signal)
        withMembership { panes[id] = Pane(surface: surface) }
        signal.requestFrame()
    }

    func remove(id: UUID) {
        withMembership {
            if let pane = panes.removeValue(forKey: id) {
                pane.surface.removeCompositor(signal)
                retired.append(pane.surface)
            }
        }
        signal.requestFrame()
    }

    func update(size: CGSize, geometry: [UUID: Geometry], forceRedraw: Bool = false) {
        let changed = withMembership {
            var changed = self.size != size
            self.size = size
            for id in panes.keys {
                let value = geometry[id] ?? .init(rect: .zero, clip: .zero, visible: false)
                if panes[id]?.geometry != value { changed = true }
                panes[id]?.geometry = value
            }
            return changed
        }
        if changed || forceRedraw {
            statsLock.withLock { skippedRetryBudget = 4 }
            signal.requestFrame()
        }
    }

    private func withMembership<T>(_ body: () -> T) -> T {
        let start = CACurrentMediaTime()
        lock.lock()
        let elapsed = CACurrentMediaTime() - start
        let owner = panes.values.first?.surface
        let result = body()
        lock.unlock()
        owner?.traceCompositor(stage: 5, sequence: 0, time: elapsed)
        return result
    }

    private func retirePending() {
        let removed = lock.withLock { let result = retired; retired.removeAll(); return result }
        for surface in removed { surface.retireCompositor(signal) }
    }

    func start() {
        lock.withLock { started = true }
        let thread = Thread { [self] in run() }
        thread.name = "cghostty.window-compositor"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        let runLoop: CFRunLoop? = lock.withLock {
            guard started, !stopping else { return nil }
            stopping = true
            for pane in panes.values {
                pane.surface.removeCompositor(signal)
                retired.append(pane.surface)
            }
            panes.removeAll()
            return loop
        }
        if let runLoop {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { CFRunLoopStop(runLoop) }
            CFRunLoopWakeUp(runLoop)
        }
        // The worker retains itself until all submitted GPU work is retired.
    }

    private func run() {
        autoreleasepool {
            let runLoop = CFRunLoopGetCurrent()!
            let displayLink = CAMetalDisplayLink(metalLayer: layer)
            displayLink.delegate = self
            displayLink.preferredFrameLatency = latency
            displayLink.isPaused = true
            displayLink.add(to: .current, forMode: .default)
            lock.withLock { link = displayLink }
            // A source keeps the run loop alive while the display link is paused.
            let port = Port()
            RunLoop.current.add(port, forMode: .default)
            lock.withLock { loop = runLoop }
            signal.install(runLoop: runLoop) { [weak self] in
                guard let self else { return }
                retirePending()
                traceOwner()?.traceCompositor(stage: 15, sequence: windowID, time: CACurrentMediaTime())
                #if CGHOSTTY_CLOCK_EXPERIMENT
                let rate = lock.withLock { requestedRate }
                if ProcessInfo.processInfo.environment["CGHOSTTY_CLOCK_RATE"] != "system" {
                    link?.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
                }
                #endif
                setPaused(false)
            }
            signal.requestFrame()
            while !lock.withLock({ stopping }) {
                autoreleasepool { _ = CFRunLoopRunInMode(.defaultMode, .greatestFiniteMagnitude, false) }
            }
            signal.install(runLoop: nil, action: nil)
            displayLink.invalidate()
            lock.withLock { link = nil; loop = nil }
            port.invalidate()
            inFlight.wait()
            retirePending()
            for slot in slots {
                slot.surfaces.removeAll()
            }
            queue.removeResidencySet(layer.residencySet)
        }
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        autoreleasepool {
            draw(drawable: update.drawable, deadline: update.targetTimestamp,
                 prediction: update.targetPresentationTimestamp, callbackTime: CACurrentMediaTime())
        }
    }

    private func draw(drawable: any CAMetalDrawable, deadline: Double, prediction: Double, callbackTime: Double) {
        let sequence = Self.sequences.withLock { $0 &+= 1; return $0 }
        let owner = traceOwner()
        owner?.traceCompositor(stage: 8, sequence: sequence, time: callbackTime, prediction: Double(windowID))
        owner?.traceCompositor(stage: 12, sequence: sequence, time: deadline,
                              prediction: 1 / Double(lock.withLock { requestedRate }))
        #if CGHOSTTY_TESTING
        encodingLock.lock()
        defer { encodingLock.unlock() }
        #endif
        let snapshot = lock.withLock { (panes, size, stopping) }
        var framePanes = snapshot.0
        let size = snapshot.1
        #if CGHOSTTY_TESTING
        if lock.withLock({ testUpdatesPaused }) { setPaused(true); return }
        #endif
        guard !snapshot.2, size.width > 0, size.height > 0 else { setPaused(true); return }
        if layer.drawableSize != size { layer.drawableSize = size; return }
        #if CGHOSTTY_TESTING
        let beforePrepare = lock.withLock { let value = testBeforePrepare; testBeforePrepare = nil; return value }
        beforePrepare?()
        #endif
        let slot = slots[index]
        guard slot.available.wait(timeout: .now()) == .success else {
            owner?.traceCompositor(stage: 11, sequence: sequence, time: CACurrentMediaTime(), prediction: 1)
            return
        }
        index = (index + 1) % slots.count
        // One trace owner per window frame avoids multiplying presentation
        // samples by pane count. Process-wide IDs survive owner/window changes.
        let participants = framePanes.keys.sorted(by: { $0.uuidString < $1.uuidString }).compactMap { id -> Ghostty.Surface? in
            guard let pane = framePanes[id], pane.geometry.visible, !pane.geometry.clip.isEmpty else { return nil }
            return pane.surface
        }.prefix(1)
        for surface in participants {
            surface.traceCompositor(stage: 0, sequence: sequence, time: deadline, prediction: prediction)
            surface.traceCompositor(stage: 1, sequence: sequence, time: callbackTime)
        }
        var transaction = WindowFrameTransaction()
        defer {
            switch transaction.abort() {
            case .none: break
            case .release: release(slot)
            case .drainAndRelease:
                // The clear and any submitted pane passes still own resources.
                drain(slot)
                release(slot)
            }
        }
        do {
            var more = false
            var draws = 0
            slot.surfaces = framePanes.values.map(\.surface)
            let traceOwners = participants.map(TraceOwner.init)
            let timelineEnabled = participants.first?.compositorTracing == true
            queue.waitForDrawable(drawable)
            try encodeBoundary(slot: slot, target: drawable.texture, clear: true)
            var clearOptions: MTL4CommitOptions?
            if timelineEnabled {
                let options = MTL4CommitOptions()
                options.addFeedbackHandler { feedback in
                    for owner in traceOwners {
                        owner.surface?.traceCompositor(stage: 17, sequence: sequence,
                            time: feedback.error == nil ? feedback.gpuStartTime : 0, prediction: feedback.gpuEndTime)
                    }
                }
                clearOptions = options
                // This precedes the first commit, unlike present_submit, which
                // is recorded after all commits. GPU work may start before present().
                let enqueueTime = CACurrentMediaTime()
                for owner in traceOwners {
                    owner.surface?.traceCompositor(stage: 19, sequence: sequence, time: enqueueTime)
                }
            }
            queue.commit([slot.clearBuffer], options: clearOptions)
            transaction.didSubmit()
            let prepareStart = CACurrentMediaTime()
            var slowestPane: Double = 0
            for id in framePanes.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard let pane = framePanes[id], pane.geometry.visible, !pane.geometry.clip.isEmpty else { continue }
                let paneStart = CACurrentMediaTime()
                let rendered = try pane.surface.withCompositor(signal) {
                    let info = pane.surface.compositorInfo
                    guard info.width > 0, info.height > 0 else { return CompositorResult(rawValue: 0) }
                    let rect = pane.geometry.rect
                    let clip = pane.geometry.clip.intersection(CGRect(x: 0, y: 0,
                        width: drawable.texture.width, height: drawable.texture.height))
                    guard !clip.isEmpty, !clip.isNull else { return CompositorResult(rawValue: 0) }
                    guard let format = MTLPixelFormat(rawValue: UInt(info.pixel_format)),
                          let target = drawable.texture.makeTextureView(pixelFormat: format) else { throw Failure.resource }
                    return pane.surface.renderCompositor(texture: target, queue: queue,
                        targetTime: prediction, rect: rect, clip: clip, sequence: sequence)
                }
                slowestPane = max(slowestPane, CACurrentMediaTime() - paneStart)
                guard let result = rendered else {
                    if pane.surface.ownsCompositor(signal) { more = true }
                    continue
                }
                if result.contains(.repaint) { draws += 1 }
                #if CGHOSTTY_TESTING
                if result.contains(.composed) { framePanes[id]?.initialized = true }
                #endif
                if result.contains(.needsFrame) { more = true }
                if result.contains(.failed) { statsLock.withLock { stats.failed += 1 } }
            }
            for surface in participants {
                surface.traceCompositor(stage: 4, sequence: sequence, time: CACurrentMediaTime() - prepareStart, prediction: slowestPane)
            }
            // Newer layout or membership wins; initialization is test-only.
            lock.withLock {
                #if CGHOSTTY_TESTING
                for (id, pane) in framePanes where panes[id]?.token == pane.token {
                    panes[id]?.initialized = pane.initialized
                }
                #endif
                framePanes = framePanes.filter { panes[$0.key]?.token == $0.value.token }
            }
            framePanes = framePanes.filter { $0.value.surface.ownsCompositor(signal) }
            try encodeBoundary(slot: slot, target: drawable.texture, clear: false)
            let options = MTL4CommitOptions()
            inFlight.enter()
            slot.drawableTexture = drawable.texture
            options.addFeedbackHandler { [self, slot] feedback in
                if timelineEnabled {
                    for owner in traceOwners {
                        owner.surface?.traceCompositor(stage: 18, sequence: sequence,
                            time: feedback.error == nil ? feedback.gpuStartTime : 0, prediction: feedback.gpuEndTime)
                    }
                }
                statsLock.withLock {
                    stats.completed += 1
                    if feedback.error != nil { stats.failed += 1 }
                }
                #if CGHOSTTY_TESTING
                completionCondition.lock()
                testCompleted += 1
                completionCondition.broadcast()
                completionCondition.unlock()
                #endif
                release(slot)
                inFlight.leave()
            }
            let retrySkipped = framePanes.values.contains { $0.geometry.visible && !$0.geometry.clip.isEmpty }
            drawable.addPresentedHandler { [weak self, traceOwners] drawable in
                for owner in traceOwners { owner.surface?.traceCompositor(stage: 3, sequence: sequence, time: drawable.presentedTime) }
                guard let self else { return }
                let retry = statsLock.withLock {
                    stats.presentationCallbacks += 1
                    if drawable.presentedTime > 0 { stats.displayed += 1; skippedRetryBudget = 4 }
                    stats.lastPresentedTime = drawable.presentedTime
                    guard retrySkipped, drawable.presentedTime == 0, skippedRetryBudget > 0 else { return false }
                    skippedRetryBudget -= 1
                    return true
                }
                if retry { signal.requestFrame() }
            }
            transaction.handoffToCompletion()
            queue.commit([slot.buffer], options: options)
            queue.signalDrawable(drawable)
            let submittedTime = CACurrentMediaTime()
            for surface in participants { surface.traceCompositor(stage: 2, sequence: sequence, time: submittedTime) }
            drawable.present()
            statsLock.withLock {
                stats.submitted += 1
                stats.paneDraws += draws
                if draws > 0 { skippedRetryBudget = 4 }
            }
            if CACurrentMediaTime() >= deadline {
                statsLock.withLock { stats.missedDeadlines += 1 }
                // Missing a prediction is a metric, not new visual work.
            }
            setPaused(!more)
        } catch {
            Ghostty.logger.error("Window composition failed: \(error)")
            statsLock.withLock { stats.failed += 1 }
            setPaused(true)
        }
    }

    private func setPaused(_ value: Bool) {
        link?.isPaused = value
        let changed = lock.withLock { let changed = paused != value; paused = value; return changed }
        if changed {
            traceOwner()?.traceCompositor(stage: 9, sequence: windowID, time: CACurrentMediaTime(), prediction: value ? 1 : 0)
        }
    }

    /// Shared final retirement path for abort and successful GPU feedback.
    private func release(_ slot: Slot) {
        slot.drawableTexture = nil
        slot.surfaces.removeAll()
        slot.available.signal()
    }

    private func drain(_ slot: Slot) {
        slot.retirementValue += 1
        queue.signalEvent(slot.retirement, value: slot.retirementValue)
        while !slot.retirement.wait(untilSignaledValue: slot.retirementValue, timeoutMS: 1000) {}
    }

    /// Clear before pane composition, then fence all pane writes before presenting.
    /// Both command buffers use the same slot allocator until final completion.
    private func encodeBoundary(slot: Slot, target: any MTLTexture, clear: Bool) throws {
        if clear {
            slot.allocator.reset()
            slot.residency.removeAllAllocations()
            slot.residency.addAllocation(target)
            slot.residency.commit()
        }
        let buffer = clear ? slot.clearBuffer : slot.buffer
        buffer.beginCommandBuffer(allocator: slot.allocator)
        defer { buffer.endCommandBuffer() }
        let descriptor = MTL4RenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = clear ? .clear : .load
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else { throw Failure.resource }
        encoder.barrier(afterQueueStages: .all, beforeStages: [.vertex, .fragment], visibilityOptions: .device)
        encoder.endEncoding()
        buffer.useResidencySet(slot.residency)
    }

    #if CGHOSTTY_TESTING
    /// Semantic wait used to verify that rendering progresses while main is blocked.
    func waitForCompletion(after previous: Int, timeout: TimeInterval = 2) -> Bool {
        completionCondition.lock()
        defer { completionCondition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while testCompleted <= previous {
            if !completionCondition.wait(until: deadline) { return false }
        }
        return true
    }

    /// Read back the same composition pass into an independent shared texture.
    /// This runs only on explicit test requests and never retains a drawable.
    func readback() throws -> (width: Int, height: Int, pixels: [UInt8]) {
        encodingLock.lock()
        defer { encodingLock.unlock() }
        let (panes, size) = lock.withLock { (self.panes, self.size) }
        guard size.width > 0, size.height > 0 else { throw Failure.resource }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: Int(size.width), height: Int(size.height), mipmapped: false)
        desc.storageMode = .shared
        desc.usage = [.renderTarget, .pixelFormatView]
        guard let texture = device.makeTexture(descriptor: desc) else { throw Failure.resource }
        let slot = try Slot(device: device)
        try encodeBoundary(slot: slot, target: texture, clear: true)
        queue.commit([slot.clearBuffer])
        var completedGPU = false
        defer { if !completedGPU { drain(slot) } }
        for pane in panes.values where pane.initialized && pane.geometry.visible {
            let rect = pane.geometry.rect
            let clip = pane.geometry.clip.intersection(CGRect(x: 0, y: 0, width: texture.width, height: texture.height))
            guard !clip.isEmpty, !clip.isNull else { continue }
            _ = try pane.surface.withCompositor(signal) {
                let info = pane.surface.compositorInfo
                guard let target = texture.makeTextureView(pixelFormat: MTLPixelFormat(rawValue: UInt(info.pixel_format))!) else { throw Failure.resource }
                return pane.surface.renderCompositor(texture: target, queue: queue, targetTime: CACurrentMediaTime(), rect: rect, clip: clip, sequence: 0, snapshot: true)
            }
        }
        try encodeBoundary(slot: slot, target: texture, clear: false)
        let completed = DispatchSemaphore(value: 0)
        let options = MTL4CommitOptions()
        let healthy = Mutex(false)
        options.addFeedbackHandler { feedback in
            healthy.withLock { $0 = feedback.error == nil }
            completed.signal()
        }
        queue.commit([slot.buffer], options: options)
        completed.wait()
        completedGPU = true
        guard healthy.withLock({ $0 }) else { throw Failure.resource }
        var pixels = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            texture.getBytes(buffer.baseAddress!, bytesPerRow: texture.width * 4,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return (texture.width, texture.height, pixels)
    }
    #endif

}
