import AppKit
import AppIntents
import GhosttyKit
import Metal
import Testing
@testable import Ghostty

@Suite(.serialized)
@MainActor struct SurfaceBridgeTests {
    // Apple Silicon uses the system GPU. Unsupported hardware is an explicit
    // skip; a capable device with a broken compiler must still fail.
    nonisolated private static func metal4Available() throws -> Bool {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        print("GPU frame tests: device=\(device.name), Metal4=\(device.supportsFamily(.metal4))")
        guard device.supportsFamily(.metal4) else { return false }
        _ = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
        return true
    }

    private func show(_ view: Ghostty.SurfaceView) throws -> NSWindow {
        let surface = try #require(view.surfaceModel)
        let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        // These tests bypass SurfaceScrollView, so publish the viewport size
        // explicitly. Focus and cursor blinking are not prerequisites to draw.
        view.sizeDidChange(view.bounds.size)
        surface.setVisible(true)
        return window
    }

    private func waitForFrame(after revision: UInt64, in view: Ghostty.SurfaceView) async throws {
        let surface = try #require(view.surfaceModel)
        let deadline = ContinuousClock.now + .seconds(5)
        while surface.renderRevision <= revision {
            try #require(ContinuousClock.now < deadline,
                         """
                         No completed terminal frame: revision=\(surface.renderRevision), expected>\(revision),
                         healthy=\(view.healthy), bounds=\(view.bounds), core=\(surface.size),
                         windowVisible=\(view.window?.isVisible ?? false), focused=\(view.focused)
                         """)
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeView(command: String = "/bin/cat") -> Ghostty.SurfaceView {
        let app = Ghostty.App(configPath: "/dev/null")
        var config = Ghostty.SurfaceConfiguration()
        config.command = command
        config.workingDirectory = FileManager.default.temporaryDirectory.path
        return Ghostty.SurfaceView(app, baseConfig: config)
    }

    private func waitForText(_ text: String, in surface: Ghostty.Surface) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while true {
            let contents = surface.readContents(viewport: false)
            if contents.contains(text) { return }
            try #require(ContinuousClock.now < deadline,
                         """
                         Terminal output did not contain \(text).
                         grid=\(surface.size.columns)x\(surface.size.rows), exited=\(surface.processExited),
                         output=\(String(reflecting: String(contents.suffix(2048))))
                         """)
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test(arguments: [false, true])
    func claudeCompatibilityConfigReachesPTY(enabled: Bool) async throws {
        let config = try TemporaryConfig("claude-compatibility = \(enabled)")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        var base = Ghostty.SurfaceConfiguration()
        base.workingDirectory = FileManager.default.temporaryDirectory.path
        base.command = #"/bin/sh -c 'printf "compat=%s;terminal=%s" "${CGHOSTTY_CLAUDE_COMPATIBILITY:-off}" "$TERM_PROGRAM"; exec /bin/cat'"#
        let view = Ghostty.SurfaceView(app, baseConfig: base)
        let surface = try #require(view.surfaceModel)
        try await waitForText("compat=\(enabled ? "1" : "off");terminal=cghostty", in: surface)
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

    @Test func accessibilitySnapshotKeepsTextAndUTF16SelectionTogether() async throws {
        var view: Ghostty.SurfaceView? = makeView()
        var surface: Ghostty.Surface? = try #require(view?.surfaceModel)
        #expect(surface!.sendKeyEvent(.init(keyCode: 0, action: .press, text: "桥接🙂e\u{301}")))
        try await waitForText("桥接🙂e\u{301}", in: surface!)
        #expect(surface!.perform(.selectAll))
        let snapshot = try #require(surface!.readAccessibility())
        let value = AccessibilityText(snapshot)
        let reused = try #require(surface!.readAccessibility())
        #expect(reused.revision == snapshot.revision)
        #expect(reused.text == snapshot.text)
        #expect(value.text == surface!.readContents(viewport: false))
        // A login banner may precede the input. Select-all must still address
        // the exact captured UTF-16 string, including that prefix and emoji.
        #expect(value.selectedRanges == [NSRange(location: 0, length: value.utf16Length)])
        #expect(value.substring(in: value.selectedRanges[0]) == value.text)
        #expect(value.substring(in: value.visibleRange) != nil)
        #expect(surface!.perform(.reset))
        let reset = try #require(surface!.readAccessibility())
        #expect(reset.revision > snapshot.revision)
        #expect(reset.text != snapshot.text)
        view = nil
        surface = nil
        #expect(value.text.contains("桥接🙂e\u{301}"))
        #expect(value.substring(in: value.selectedRanges[0]) == value.text)
    }

    @Test(.enabled(if: try Self.metal4Available(), "Requires a Metal 4 GPU"))
    func completedFramesAdvanceThumbnailRevisionAndMetadataSkipsImages() async throws {
        let view = makeView()
        let surface = try #require(view.surfaceModel)
        let window = try show(view)
        defer { window.close() }
        let initialRevision = surface.renderRevision
        #expect(surface.sendKeyEvent(.init(keyCode: 0, action: .press, text: "first frame")))
        try await waitForText("first frame", in: surface)
        try await waitForFrame(after: initialRevision, in: view)
        let revision = surface.renderRevision
        #expect(TerminalEntity(view).displayRepresentation.image == nil)
        #expect(TerminalEntity(view, includeThumbnail: true).displayRepresentation.image != nil)
        #expect(surface.sendKeyEvent(.init(keyCode: 0, action: .press, text: "new frame")))
        try await waitForText("new frame", in: surface)
        try await waitForFrame(after: revision, in: view)
        #expect(surface.renderRevision > revision)
    }

    @Test(.enabled(if: try Self.metal4Available(), "Requires a Metal 4 GPU"))
    func focusVisibilityChangesAndSynchronousDisplayKeepRendering() async throws {
        let view = makeView()
        let surface = try #require(view.surfaceModel)
        let window = try show(view)
        defer { window.close() }
        for round in 0..<6 {
            surface.setFocus(false)
            surface.setVisible(false)
            surface.setVisible(true)
            surface.setFocus(true)
            let revision = surface.renderRevision
            let marker = "focus-frame-\(round)"
            #expect(surface.sendKeyEvent(.init(keyCode: 0, action: .press, text: marker)))
            try await waitForText(marker, in: surface)
            try await waitForFrame(after: revision, in: view)
            // Exercise the main-thread synchronous path while completed async
            // presentations may still be queued. This must not wait on main.
            let layer = try #require(view.layer)
            layer.display()
            #expect(layer.contents != nil)
            #expect(view.healthy)
        }
    }

    @Test(.enabled(if: try Self.metal4Available(), "Requires a Metal 4 GPU"))
    func kittyPlacementsAndSynchronizedFramesReachNativeRenderer() async throws {
        // Two placements exercise nonzero offsets in the shared instance buffer.
        let output = "\u{1b}[H\u{1b}_Ga=T,f=32,s=1,v=1,i=1,q=2,c=4,r=2;/wAA/w==\u{1b}\\" +
            "\u{1b}[1;8H\u{1b}_Ga=p,i=1,p=2,q=2,c=4,r=2\u{1b}\\" +
            "\u{1b}[4;1Hready-images\u{1b}[?2026h\u{1b}[5;1Hnext-frame\u{1b}[?2026l"
        let encoded = Data(output.utf8).base64EncodedString()
        let view = makeView(command: "/bin/sh -c 'printf %s \(encoded) | /usr/bin/base64 -D; exec /bin/cat'")
        let surface = try #require(view.surfaceModel)
        let window = try show(view)
        defer { window.close() }
        try await waitForText("next-frame", in: surface)
        let revision = surface.renderRevision
        #expect(surface.sendKeyEvent(.init(keyCode: 0, action: .press, text: "draw-check")))
        try await waitForText("draw-check", in: surface)
        try await waitForFrame(after: revision, in: view)
        #expect(view.healthy)
        let png = try #require(view.thumbnailPNG())
        let bitmap = try #require(NSBitmapImageRep(data: png))
        var redColumns = Set<Int>()
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.redComponent > 0.8, color.greenComponent < 0.2, color.blueComponent < 0.2 {
                    redColumns.insert(x)
                }
            }
        }
        let bands = redColumns.filter { !redColumns.contains($0 - 1) }.count
        #expect(bands == 2, "Both red image placements must survive distinct buffer offsets")
    }

    @Test(arguments: [false, true])
    func searchRefreshesFromPTYChangesAndAfterVisibilityRestoration(delayedStartup: Bool) async throws {
        // PTY echo can arrive before login prints its banner and launches the
        // command. Wait for the child after configuring raw, non-echoing input
        // so both writes below must make a real round trip through cat.
        let delay = delayedStartup ? "/bin/sleep 0.2; " : ""
        let command = "/bin/sh -c '\(delay)/bin/stty raw -echo && " +
            "printf \"search-pty-ready\\r\\n\" && exec /bin/cat'"
        let view = makeView(command: command)
        let surface = try #require(view.surfaceModel)
        try await waitForText("search-pty-ready", in: surface)
        let needle = "unique-search-word"
        view.searchState = Ghostty.SearchState(from: Ghostty.Action.StartSearch(c: .init(needle: nil)),
                                               pasteboard: .withUniqueName())
        #expect(surface.sendKeyEvent(.init(keyCode: 0, action: .press, text: needle)))
        try await waitForText(needle, in: surface)
        #expect(surface.search(needle))
        func waitForMatches(_ total: UInt) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while view.searchState?.total != total {
                try #require(ContinuousClock.now < deadline,
                             "Search total expected=\(total), actual=\(String(describing: view.searchState?.total))")
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        try await waitForMatches(1)
        surface.setVisible(false)
        #expect(surface.sendKeyEvent(.init(keyCode: 0, action: .press, text: " " + needle)))
        try await waitForText(needle + " " + needle, in: surface)
        #expect(view.searchState?.total == 1)
        surface.setVisible(true)
        try await waitForMatches(2)
        #expect(surface.endSearch())
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
        #expect(view.keyTables.isEmpty)
        #expect(view.keySequence.isEmpty)
    }

}
