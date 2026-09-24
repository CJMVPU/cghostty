import Synchronization

/// Coalesces pending dispatches without holding a lock while running callbacks.
nonisolated final class AppWakeupGate: Sendable {
    private let pending = Mutex(false)

    func request() -> Bool {
        pending.withLock { value in
            guard !value else { return false }
            value = true
            return true
        }
    }

    func beginTick() {
        pending.withLock { $0 = false }
    }
}
