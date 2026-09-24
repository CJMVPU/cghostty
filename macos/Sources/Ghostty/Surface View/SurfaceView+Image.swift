import AppKit

extension Ghostty.SurfaceView {
    func cachedThumbnailPNG() -> Data? {
        guard let surface = surfaceModel else { return nil }
        let key = SurfaceThumbnailCache.Key(revision: surface.renderRevision, size: bounds.size,
                                            scale: window?.backingScaleFactor ?? 1)
        return thumbnailCache.value(for: key) { thumbnailPNG() }
    }

    /// A snapshot image of the current surface view.
    var asImage: NSImage? {
        guard let bitmapRep = bitmapImageRepForCachingDisplay(in: bounds) else {
            return nil
        }
        cacheDisplay(in: bounds, to: bitmapRep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(bitmapRep)
        return image
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

    mutating func value(for key: Key, render: () -> Data?) -> Data? {
        if self.key == key, let data { return data }
        guard let result = render() else { return nil }
        self.key = key
        data = result
        return result
    }
}
