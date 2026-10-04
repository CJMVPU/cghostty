@testable import Ghostty
import Testing
import Foundation

struct SurfaceViewAppKitTests {
    @Test(arguments: [
        ("\u{0008}", true),
        ("\u{001F}", true),
        ("\u{007F}", false),
        (" ", false),
        ("h", false),
        ("", false),
        ("\u{0009}x", false),
        ("\u{0009}\u{0009}", false),
    ])
    func suppressesOnlySingleC0ControlTextWhileComposing(
        text: String,
        expected: Bool
    ) {
        #expect(
            Ghostty.SurfaceView.shouldSuppressComposingControlInput(
                text,
                composing: true
            ) == expected
        )
    }

    @Test func doesNotSuppressControlTextWhenNotComposing() {
        #expect(
            Ghostty.SurfaceView.shouldSuppressComposingControlInput(
                "\u{0008}",
                composing: false
            ) == false
        )
    }

    @Test func doesNotSuppressMissingText() {
        #expect(
            Ghostty.SurfaceView.shouldSuppressComposingControlInput(
                nil,
                composing: true
            ) == false
        )
    }

    @MainActor @Test func selectionChangeRefreshesAccessibilityWithinCacheLifetime() async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        var base = Ghostty.SurfaceConfiguration()
        base.command = "/bin/sh -c 'printf selection-ready; exec /bin/cat'"
        base.workingDirectory = FileManager.default.temporaryDirectory.path
        let view = Ghostty.SurfaceView(app, baseConfig: base)
        let surface = try #require(view.surfaceModel)
        try await NativeTestWait.until("selection text readiness", timeout: .seconds(5), polling: .milliseconds(10),
            diagnostics: { NativeTestWait.surfaceState(surface) }, {
                surface.readContents(viewport: false).contains("selection-ready")
            })

        // Prime the 500 ms view cache before changing only selection metadata.
        let original = view.cachedScreenContents.get()
        let captures = surface.accessibilityCaptureCount
        #expect(original.selectedRanges.isEmpty)
        #expect(surface.perform(.selectAll))
        view.selectionDidChange()
        let selected = try #require(surface.readAccessibility())
        #expect(view.accessibilitySelectedTextRange() == selected.selectedRanges.first)
        #expect(view.accessibilitySelectedText() == selected.text)
        #expect(view.cachedScreenContents.get().textRevision == original.textRevision)
        #expect(surface.accessibilityCaptureCount == captures)

        // A cleared selection must also replace the cached selected metadata,
        // including the text snapshot changed by reset, without waiting for TTL.
        #expect(surface.perform(.reset))
        view.selectionDidChange()
        #expect(view.accessibilitySelectedTextRange().location == NSNotFound)
        #expect(view.accessibilitySelectedText() == nil)
        #expect(view.cachedScreenContents.get().selectedRanges.isEmpty)
    }

    @MainActor @Test func selectionNotificationDoesNotCancelHighlightExpiry() async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        var base = Ghostty.SurfaceConfiguration()
        base.command = "/bin/cat"
        base.workingDirectory = FileManager.default.temporaryDirectory.path
        let view = Ghostty.SurfaceView(app, baseConfig: base)
        view.highlight()
        view.selectionDidChange()
        #expect(view.highlighted)
        try await NativeTestWait.until("highlight expiry after selection notification", timeout: .seconds(2),
            polling: .milliseconds(20), diagnostics: { "highlighted=\(view.highlighted)" }, {
                !view.highlighted
            })
    }

    @MainActor @Test func repeatedHighlightExtendsVisibilityAndDoesNotRetainSurface() async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        var base = Ghostty.SurfaceConfiguration()
        base.command = "/bin/cat"
        base.workingDirectory = FileManager.default.temporaryDirectory.path
        var view: Ghostty.SurfaceView? = Ghostty.SurfaceView(app, baseConfig: base)
        weak let weakView = view
        view?.highlight()
        // These intervals exercise the 400 ms animation deadline: the second
        // trigger must cancel the first expiry rather than hiding at 400 ms.
        try await Task.sleep(for: .milliseconds(250))
        view?.highlight()
        try await Task.sleep(for: .milliseconds(250))
        #expect(view?.highlighted == true)
        let deadline = ContinuousClock.now + .seconds(2)
        while view?.highlighted == true && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(view?.highlighted == false)
        view?.highlight()
        view = nil
        #expect(weakView == nil)
    }

}
