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
