import AppKit
import GhosttyKit
import Testing
@testable import Ghostty

@MainActor struct ClipboardConfirmationPreviewTests {
    @Test func mixedTextAndPNGShowsBothRepresentations() throws {
        let png = try pngData()
        let preview = ClipboardConfirmationPreview(contents: [
            .init(mime: "text/plain", data: Data("private text".utf8)),
            .init(mime: "image/png", data: png),
        ])
        #expect(preview.items.map(\.mime) == ["text/plain", "image/png"])
        #expect(preview.items.first?.text == "private text")
        #expect(preview.items.last?.image != nil)
        #expect(preview.items.map(\.byteCount) == [12, png.count])
    }

    @Test func textAndBinaryShowsAllMIMESummaries() {
        let preview = ClipboardConfirmationPreview(contents: [
            .init(mime: "text/plain", data: Data("text".utf8)),
            .init(mime: "application/octet-stream", data: Data([0, 255, 1])),
        ])
        #expect(preview.items.map(\.summary) == [
            "text/plain (4 bytes)", "application/octet-stream (3 bytes)",
        ])
        #expect(preview.items.first?.text == "text")
    }

    @Test func availableMIMEsAreDisclosedWithoutReadingTheirData() {
        let preview = ClipboardConfirmationPreview(contents: [], availableMimes: ["text/plain", "image/png"])
        #expect(preview.items.isEmpty)
        #expect(preview.availableMimes == ["text/plain", "image/png"])
    }

    @Test func invalidTextAndImageRemainVisibleAsByteSummaries() {
        let preview = ClipboardConfirmationPreview(contents: [
            .init(mime: "text/plain", data: Data([255])),
            .init(mime: "image/png", data: Data([0])),
        ])
        #expect(preview.items.map(\.summary) == ["text/plain (1 bytes)", "image/png (1 bytes)"])
        #expect(preview.items.allSatisfy { $0.text == nil && $0.image == nil })
    }

    @Test func closingConfirmationWindowDeniesCurrentRequestOnce() throws {
        let app = Ghostty.App(configPath: "/dev/null")
        var configuration = Ghostty.SurfaceConfiguration()
        configuration.command = "/bin/cat"
        configuration.workingDirectory = FileManager.default.temporaryDirectory.path
        let surface = Ghostty.SurfaceView(app, baseConfig: configuration)
        let delegate = ConfirmationDelegate()
        var results: [Bool] = []
        let request = Ghostty.ClipboardConfirmationRequest(
            surface: surface, contents: "private text", kind: .kitty_read
        ) { _, confirmed, _ in results.append(confirmed) }
        let controller = ClipboardConfirmationController(confirmation: request, delegate: delegate)
        let window = try #require(controller.window)
        window.close()
        #expect(results == [false])
        request.cancel()
        request.complete()
        #expect(results == [false])
        withExtendedLifetime(app) {}
    }

    @Test func completedRequestWindowCloseDoesNotDenyOrCompleteAgain() throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let surface = makeSurface(app)
        let delegate = ConfirmationDelegate()
        var results: [Bool] = []
        var remembered: [Bool] = []
        let request = Ghostty.ClipboardConfirmationRequest(
            surface: surface, contents: "approved text", kind: .kitty_read
        ) { _, confirmed, remember in
            results.append(confirmed)
            remembered.append(remember)
        }
        let controller = ClipboardConfirmationController(confirmation: request, delegate: delegate)
        let window = try #require(controller.window)
        request.complete(remember: true)
        window.close()
        request.complete()
        request.cancel()
        #expect(results == [true])
        #expect(remembered == [true])
        #expect(delegate.cancellations == 0)
        withExtendedLifetime(app) {}
    }

    @Test func coreCallbackPreviewCopiesBorrowedRepresentationsBeforeReturning() throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let surface = makeSurface(app)
        let core = try #require(surface.surfaceModel)
        let userdata = ghostty_surface_userdata(core.unsafeCValue)
        "text/plain".withCString { textMime in
            "application/octet-stream".withCString { binaryMime in
                var text: [CChar] = [111, 108, 100]
                var binary: [CChar] = [0, -1]
                text.withUnsafeMutableBufferPointer { textBuffer in
                    binary.withUnsafeMutableBufferPointer { binaryBuffer in
                        let contents = [
                            ghostty_clipboard_content_s(mime: textMime, data: textBuffer.baseAddress, len: textBuffer.count),
                            ghostty_clipboard_content_s(mime: binaryMime, data: binaryBuffer.baseAddress, len: binaryBuffer.count),
                        ]
                        contents.withUnsafeBufferPointer { contentsBuffer in
                            let available: [UnsafePointer<CChar>?] = [textMime, binaryMime]
                            available.withUnsafeBufferPointer { availableBuffer in
                                var confirmation = ghostty_clipboard_confirm_s(
                                    contents: contentsBuffer.baseAddress, contents_len: contentsBuffer.count,
                                    available: availableBuffer.baseAddress, available_len: availableBuffer.count,
                                    name: nil, can_remember: true)
                                Ghostty.App.confirmReadClipboard(userdata, confirm: &confirmation, state: nil,
                                                                 request: GHOSTTY_CLIPBOARD_REQUEST_KITTY_READ)
                            }
                        }
                        textBuffer[0] = 110
                        binaryBuffer[0] = 42
                    }
                }
            }
        }
        let request = try #require(surface.pendingClipboardConfirmation)
        #expect(request.preview.items.map(\.summary) == ["text/plain (3 bytes)", "application/octet-stream (2 bytes)"])
        #expect(request.preview.items.first?.text == "old")
        #expect(request.preview.availableMimes == ["text/plain", "application/octet-stream"])
        #expect(request.canRemember)
        surface.pendingClipboardConfirmation = nil
        request.complete()
        #expect(!request.isPending)
        withExtendedLifetime(app) {}
    }

    @Test func allTextRepresentationsArePreviewedAsLiteralText() {
        let preview = ClipboardConfirmationPreview(contents: [
            .init(mime: "text/plain", data: Data("plain".utf8)),
            .init(mime: "text/html", data: Data("<b>rich</b>".utf8)),
        ])
        #expect(preview.items.map(\.text) == ["plain", "<b>rich</b>"])
    }

    private func makeSurface(_ app: Ghostty.App) -> Ghostty.SurfaceView {
        var configuration = Ghostty.SurfaceConfiguration()
        configuration.command = "/bin/cat"
        configuration.workingDirectory = FileManager.default.temporaryDirectory.path
        return Ghostty.SurfaceView(app, baseConfig: configuration)
    }

    private func pngData() throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}

@MainActor private final class ConfirmationDelegate: ClipboardConfirmationViewDelegate {
    private(set) var cancellations = 0

    func clipboardConfirmationComplete(_ action: ClipboardConfirmationView.Action, remember: Bool) {
        if action == .cancel { cancellations += 1 }
    }
}
