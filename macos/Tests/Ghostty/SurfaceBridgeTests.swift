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

    @Test func stateCallbacksReachOnlyTheirTargetAndPreserveQueueOrder() async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/cat"
        config.workingDirectory = FileManager.default.temporaryDirectory.path
        let view = Ghostty.SurfaceView(app, baseConfig: config)
        let other = Ghostty.SurfaceView(app, baseConfig: config)
        let core = try #require(view.surfaceModel)
        let target = ghostty_target_s(tag: GHOSTTY_TARGET_SURFACE,
                                     target: .init(surface: core.unsafeCValue))
        let appHandle = try #require(app.app)
        func deliver(_ tag: ghostty_action_tag_e, _ value: ghostty_action_u) {
            #expect(Ghostty.App.action(appHandle, target: target, action: .init(tag: tag, action: value)))
        }
        func drainQueue() async {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }

        deliver(GHOSTTY_ACTION_READONLY, .init(readonly: GHOSTTY_READONLY_ON))
        #expect(view.readonly)
        #expect(!other.readonly)
        deliver(GHOSTTY_ACTION_RENDERER_HEALTH, .init(renderer_health: GHOSTTY_RENDERER_HEALTH_UNHEALTHY))
        #expect(view.healthy) // Presentation changes remain deferred.

        var name = Array("navigation".utf8CString)
        name.withUnsafeBufferPointer { buffer in
            deliver(GHOSTTY_ACTION_KEY_TABLE,
                    .init(key_table: .init(tag: GHOSTTY_KEY_TABLE_ACTIVATE,
                                           value: .init(activate: .init(name: buffer.baseAddress, len: 10)))))
        }
        name[0] = 88 // The callback must own the name before returning to the core.
        let trigger = ghostty_input_trigger_s(tag: GHOSTTY_TRIGGER_UNICODE,
                                             key: .init(unicode: 97), mods: GHOSTTY_MODS_CTRL)
        deliver(GHOSTTY_ACTION_KEY_SEQUENCE, .init(key_sequence: .init(active: true, trigger: trigger)))
        await drainQueue()
        await drainQueue()
        #expect(!view.healthy)
        #expect(other.healthy)
        #expect(view.keyTables == ["navigation"])
        #expect(other.keyTables.isEmpty)
        #expect(view.keySequence.count == 1)
        #expect(other.keySequence.isEmpty)

        deliver(GHOSTTY_ACTION_KEY_TABLE,
                .init(key_table: .init(tag: GHOSTTY_KEY_TABLE_DEACTIVATE, value: .init())))
        deliver(GHOSTTY_ACTION_KEY_SEQUENCE, .init(key_sequence: .init(active: false, trigger: trigger)))
        await drainQueue()
        await drainQueue()
        #expect(view.keyTables.isEmpty)
        #expect(view.keySequence.isEmpty)
    }

}
