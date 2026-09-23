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
}
