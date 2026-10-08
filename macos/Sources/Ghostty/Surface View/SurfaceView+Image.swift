import AppKit

extension Ghostty.SurfaceView {
    func cachedThumbnailPNG() async -> Data? {
        guard let surface = surfaceModel, let key = thumbnailKey else { return nil }
        return await thumbnailRequests.value(for: key, render: { surface.snapshotPNG() }, currentKey: { [weak self] in self?.thumbnailKey })
    }

    private var thumbnailKey: SurfaceThumbnailCache.Key? {
        guard let surface = surfaceModel, let window else { return nil }
        return .init(revision: surface.renderRevision, size: bounds.size, scale: window.backingScaleFactor)
    }

}

/// Each surface retains at most one bounded PNG. A completed core frame,
/// resizing or moving to a different backing scale invalidates it.
struct SurfaceThumbnailCache {
    struct Key: Equatable {
        let revision: UInt64
        let size: CGSize
        let scale: CGFloat
    }
    private var key: Key?
    private var data: Data?

    func cachedValue(for key: Key) -> Data? { self.key == key ? data : nil }

    mutating func store(_ data: Data, for key: Key) {
        self.key = key
        self.data = data
    }

    mutating func value(for key: Key, render: () -> Data?) -> Data? {
        if self.key == key, let data { return data }
        guard let result = render() else { return nil }
        self.key = key
        data = result
        return result
    }
}

/// One serial executor for GPU readbacks. AppKit and cache validity stay on main.
private actor SurfaceThumbnailWorker {
    func render(_ operation: @Sendable () -> Data?) -> Data? {
        guard !Task.isCancelled else { return nil }
        let data = operation()
        return Task.isCancelled ? nil : data
    }
}

@MainActor final class SurfaceThumbnailRequests {
    private static let worker = SurfaceThumbnailWorker()
    private var cache = SurfaceThumbnailCache()
    private var pending: (key: SurfaceThumbnailCache.Key, id: UUID, task: Task<Data?, Never>)?
    #if CGHOSTTY_TESTING
    private(set) var activeRequestsForTesting = 0
    #endif

    func value(for key: SurfaceThumbnailCache.Key, render: @escaping @Sendable () -> Data?,
               currentKey: () -> SurfaceThumbnailCache.Key?) async -> Data? {
        guard !Task.isCancelled, currentKey() == key else { return nil }
        if let cached = cache.cachedValue(for: key) { return cached }
        #if CGHOSTTY_TESTING
        activeRequestsForTesting += 1
        defer { activeRequestsForTesting -= 1 }
        #endif
        let request: (key: SurfaceThumbnailCache.Key, id: UUID, task: Task<Data?, Never>)
        if let pending, pending.key == key { request = pending } else {
            pending?.task.cancel()
            request = (key, UUID(), Task { await Self.worker.render(render) })
            pending = request
        }
        let data = await request.task.value
        if pending?.id == request.id { pending = nil }
        guard !Task.isCancelled, currentKey() == key, let data else { return nil }
        cache.store(data, for: key)
        return data
    }

    isolated deinit { pending?.task.cancel() }
}
