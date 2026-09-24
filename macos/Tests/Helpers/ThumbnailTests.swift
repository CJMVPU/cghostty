import AppKit
import Testing
@testable import Ghostty

@MainActor struct ThumbnailTests {
    private final class TestView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor(srgbRed: 0.8, green: 0.2, blue: 0.1, alpha: 1).setFill()
            bounds.fill()
        }
    }

    @Test(arguments: [NSSize(width: 1600, height: 800), NSSize(width: 800, height: 1600), NSSize(width: 100, height: 50)])
    func thumbnailBoundsAndPixels(_ size: NSSize) throws {
        let view = TestView(frame: NSRect(origin: .zero, size: size))
        let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        window.displayIfNeeded()
        defer { window.close() }
        let data = try #require(view.thumbnailPNG())
        let bitmap = try #require(NSBitmapImageRep(data: data))
        #expect(bitmap.pixelsWide <= 256 && bitmap.pixelsHigh <= 256)
        #expect(abs(Double(bitmap.pixelsWide) / Double(bitmap.pixelsHigh) - size.width / size.height) < 0.01)
        #expect(bitmap.colorSpace == .sRGB)
        #expect(bitmap.bitsPerSample == 8 && bitmap.samplesPerPixel == 4)
        // colorAt labels RGB components as calibrated RGB even for an sRGB bitmap.
        // Read the stored samples directly and verify their declared color space above.
        var pixel = [UInt](repeating: 0, count: 4)
        bitmap.getPixel(&pixel, atX: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)
        #expect(abs(Double(pixel[0]) / 255 - 0.8) < 0.025)
        #expect(abs(Double(pixel[1]) / 255 - 0.2) < 0.025)
        #expect(abs(Double(pixel[2]) / 255 - 0.1) < 0.025)
        #expect(pixel[3] == 255)
    }

    @Test func emptyViewDoesNotAllocateImage() {
        #expect(TestView(frame: .zero).thumbnailPNG() == nil)
    }

    @Test func cacheInvalidatesForFrameSizeAndScaleAndRetriesFailures() {
        var cache = SurfaceThumbnailCache()
        var renders = 0
        let key = SurfaceThumbnailCache.Key(revision: 1, size: CGSize(width: 800, height: 600), scale: 2)
        func render() -> Data? { renders += 1; return Data([UInt8(renders)]) }
        #expect(cache.value(for: key, render: render) == Data([1]))
        #expect(cache.value(for: key, render: render) == Data([1]))
        let frame = SurfaceThumbnailCache.Key(revision: 2, size: key.size, scale: key.scale)
        #expect(cache.value(for: frame, render: render) == Data([2]))
        let size = SurfaceThumbnailCache.Key(revision: 2, size: CGSize(width: 600, height: 600), scale: 2)
        #expect(cache.value(for: size, render: render) == Data([3]))
        let scale = SurfaceThumbnailCache.Key(revision: 2, size: size.size, scale: 1)
        #expect(cache.value(for: scale, render: { nil }) == nil)
        #expect(cache.value(for: scale, render: render) == Data([4]))
        #expect(cache.value(for: scale, render: render) == Data([4]))
        #expect(renders == 4)
    }

    // Run under ReleaseLocal for measurements. No timing threshold: system/GPU
    // load varies, while the one-render contract and image equality must hold.
    @Test func repeatedThumbnailMeasurement() throws {
        let view = TestView(frame: NSRect(x: 0, y: 0, width: 1600, height: 800))
        let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        window.displayIfNeeded()
        defer { window.close() }
        let expected = try #require(view.thumbnailPNG())
        let clock = ContinuousClock()
        let count = 100
        let baseline = try clock.measure {
            for _ in 0..<count {
                let image = try #require(view.thumbnailPNG())
                #expect(image == expected)
            }
        }
        var cache = SurfaceThumbnailCache()
        let key = SurfaceThumbnailCache.Key(revision: 1, size: view.bounds.size, scale: window.backingScaleFactor)
        var renders = 0
        let reused = clock.measure {
            for _ in 0..<count {
                #expect(cache.value(for: key) { renders += 1; return view.thumbnailPNG() } == expected)
            }
        }
        #expect(renders == 1)
        print("Thumbnail benchmark (\(count) reads, 1600x800 → 256x128): fresh=\(baseline), reused=\(reused)")
    }
}
