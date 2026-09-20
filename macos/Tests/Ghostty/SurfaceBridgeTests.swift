import AppKit
import GhosttyKit
import Testing
@testable import Ghostty

@MainActor struct SurfaceBridgeTests {
    private func makeView(command: String = "/bin/cat") -> Ghostty.SurfaceView {
        let app = Ghostty.App(configPath: "/dev/null")
        var config = Ghostty.SurfaceConfiguration()
        config.command = command
        config.workingDirectory = FileManager.default.temporaryDirectory.path
        return Ghostty.SurfaceView(app, baseConfig: config)
    }

    private func waitForText(_ text: String, in surface: Ghostty.Surface) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !surface.readContents(viewport: false).contains(text) {
            guard ContinuousClock.now < deadline else {
                Issue.record("Terminal output did not contain \(text)")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func unknownHardwareCodesAndCommittedTextSurviveMarshalling() {
        let event = Ghostty.Input.KeyEvent(
            keyCode: 65535, action: .repeat, text: "中文🙂", composing: true,
            mods: [.alt, .shiftRight], consumedMods: [.alt], unshiftedCodepoint: 0x4E2D)
        event.withCValue { value in
            #expect(value.keycode == 65535)
            #expect(value.action == GHOSTTY_ACTION_REPEAT)
            #expect(value.composing)
            #expect(String(cString: value.text) == "中文🙂")
            #expect(value.mods == event.mods.cMods)
            #expect(value.consumed_mods == event.consumedMods.cMods)
            #expect(value.unshifted_codepoint == 0x4E2D)
        }
        Ghostty.Input.KeyEvent(keyCode: 0, action: .press, text: "提交").withCValue {
            #expect($0.keycode == 0)
            #expect(!$0.composing)
            #expect(String(cString: $0.text) == "提交")
        }
    }

    @Test func selectionSnapshotOutlivesCoreMutationAndView() async throws {
        var view: Ghostty.SurfaceView? = makeView(command: "/usr/bin/printf '桥接🙂snapshot'")
        var surface: Ghostty.Surface? = try #require(view?.surfaceModel)
        try await waitForText("桥接🙂snapshot", in: surface!)
        #expect(surface!.perform(.selectAll))
        let snapshot = try #require(surface!.selection)
        #expect(snapshot.text.contains("桥接🙂snapshot"))
        #expect(snapshot.range.length > 0)
        #expect(surface!.perform(.reset))
        view = nil
        surface = nil
        #expect(snapshot.text.contains("桥接🙂snapshot"))
    }

    @Test func repeatedKeyAndPreeditBridgeReachPTY() async throws {
        let view = makeView()
        let surface = try #require(view.surfaceModel)
        // A native preedit is a renderer update and must not submit its text.
        view.setMarkedText("未提交", selectedRange: NSRange(location: 3, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText())
        #expect(!surface.readContents(viewport: false).contains("未提交"))
        view.unmarkText()
        #expect(surface.sendKeyEvent(.init(keyCode: 0, action: .press, text: "提交🙂")))
        #expect(!view.hasMarkedText())
        for _ in 0..<20 {
            #expect(surface.sendKeyEvent(.init(key: .n, action: .repeat, text: "n")))
        }
        #expect(surface.sendKeyEvent(.init(key: .enter, text: "\r")))
        try await waitForText("提交🙂" + String(repeating: "n", count: 20), in: surface)
    }

    @Test func coreClipboardConfirmationCancelsOnceAndReleasesSurface() async throws {
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(previous.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            })
        }
        pasteboard.clearContents()
        pasteboard.setString("bridge clipboard payload", forType: .string)
        var view: Ghostty.SurfaceView? = makeView(command: "/usr/bin/printf '\\033]52;c;?\\007'")
        weak let weakView = view
        weak let weakSurface = view?.surfaceModel
        let deadline = ContinuousClock.now + .seconds(5)
        while view?.pendingClipboardConfirmation == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let request = try #require(view?.pendingClipboardConfirmation)
        #expect(request.contents.contains("bridge clipboard payload"))
        // Closing cancels with the explicit view while its weak reference is unavailable.
        view = nil
        request.cancel()
        request.complete()
        #expect(weakView == nil)
        #expect(weakSurface == nil)
    }

    @Test func fixedCommandsAndInvalidFontDeltaUseTypedBridge() async throws {
        let view = makeView()
        let surface = try #require(view.surfaceModel)
        #expect(!surface.changeFontSize(by: .nan))
        #expect(!surface.changeFontSize(by: .infinity))
        #expect(surface.changeFontSize(by: 1.5))
        #expect(surface.perform(.resetFontSize))
        #expect(surface.perform(.toggleReadonly))
        await Task.yield()
        #expect(view.readonly)
        #expect(surface.perform(.toggleReadonly))
        await Task.yield()
        #expect(!view.readonly)
        surface.setSize(width: 640, height: 480)
        #expect(surface.size.pixels == CGSize(width: 640, height: 480))
        #expect(surface.size.columns > 0)
    }
}
