import Foundation

/// Wait for one presentation generation; hiding or replacing it cancels its waiters.
@MainActor
final class PresentationGate {
    private var generation: UUID?
    private var ready = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    var pendingCount: Int { waiters.count }

    func begin() -> UUID {
        cancel()
        let id = UUID()
        generation = id
        return id
    }

    func complete(_ id: UUID) {
        guard generation == id else { return }
        ready = true
        resolve(true)
    }

    func cancel() {
        generation = nil
        ready = false
        resolve(false)
    }

    func wait() async -> Bool {
        guard !Task.isCancelled, generation != nil else { return false }
        if ready { return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                waiters[id] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.waiters.removeValue(forKey: id)?.resume(returning: false)
            }
        }
    }

    private func resolve(_ result: Bool) {
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: result) }
    }
}
