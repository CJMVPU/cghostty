import AppKit

extension Ghostty {
    /// Session ownership is independent of temporary AppKit attachment. Moves
    /// and undo keep the same session; only final view teardown releases it.
    @MainActor final class SurfaceLifecycle {
        enum Phase {
            case uninitialized
            case ready
            case failed
            case released
        }

        private(set) var phase: Phase = .uninitialized
        private(set) var surface: Surface?
        private(set) weak var window: NSWindow?
        private var eventMonitor: Any?
        var isMonitoringEvents: Bool { eventMonitor != nil }

        func start(owner: App, view: SurfaceView, configuration: SurfaceConfiguration) {
            precondition(phase == .uninitialized)
            surface = owner.makeSurface(view: view, configuration: configuration)
            phase = surface == nil ? .failed : .ready
        }

        func attach(to window: NSWindow?, handler: @escaping (NSEvent) -> NSEvent?) {
            guard phase == .ready else { return }
            if self.window === window, eventMonitor != nil { return }
            detach()
            guard let window else { return }
            self.window = window
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyUp, .leftMouseDown]) { [weak self] event in
                guard let self, let current = self.window, event.window === current else { return event }
                return handler(event)
            }
        }

        func detach() {
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            eventMonitor = nil
            window = nil
        }

        func release() {
            guard phase != .released else { return }
            detach()
            surface?.detachView()
            surface = nil
            phase = .released
        }

        isolated deinit {
            release()
        }
    }
}
