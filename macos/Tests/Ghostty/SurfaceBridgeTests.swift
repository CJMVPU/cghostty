import AppKit
import AppIntents
import GhosttyKit
import Testing
@testable import Ghostty

@Suite(.serialized)
@MainActor struct SurfaceBridgeTests {
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
        try await NativeTestWait.until("terminal frame completion", timeout: .seconds(5), polling: .milliseconds(10),
            diagnostics: { "expectedRevision>\(revision)\n" + NativeTestWait.surfaceState(surface, view: view) }, {
            surface.renderRevision > revision
        })
    }

    private func makeView(command: String = "/bin/cat", configPath: String = "/dev/null") -> Ghostty.SurfaceView {
        let app = Ghostty.App(configPath: configPath)
        var config = Ghostty.SurfaceConfiguration()
        config.command = command
        config.workingDirectory = FileManager.default.temporaryDirectory.path
        return Ghostty.SurfaceView(app, baseConfig: config)
    }

    private func waitForText(_ text: String, in surface: Ghostty.Surface) async throws {
        try await NativeTestWait.until("terminal text readiness", timeout: .seconds(5), polling: .milliseconds(10),
            diagnostics: { NativeTestWait.surfaceState(surface, expectedText: text) }, {
            surface.readContents(viewport: false).contains(text)
        })
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

    @Test func configuredFileInputPrecedesNativeTextThroughTheWriterLoop() async throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        let file = directory.appendingPathComponent("source")
        let contents = String(repeating: "file-input-line\n", count: 16_384)
        try Data(contents.utf8).write(to: file)
        let expected = "prefix\n" + contents + "suffix\nkey\n"
        let config = try TemporaryConfig("""
        shell-integration = none
        input = raw:prefix\\n
        input = path:\(file.path)
        input = raw:suffix\\n
        """)
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        var base = Ghostty.SurfaceConfiguration()
        base.workingDirectory = directory.path
        base.command = "/bin/sh -c 'stty -echo; head -c \(expected.utf8.count) > captured; " +
            "printf source-done; exec /bin/cat'"
        let view = Ghostty.SurfaceView(app, baseConfig: base)
        let surface = try #require(view.surfaceModel)
        // Submit through the native bridge while configured input is pending.
        // The subprocess must see every file chunk before this ordinary input.
        surface.sendText("key\n")
        try await waitForText("source-done", in: surface)
        let captured = try Data(contentsOf: directory.appendingPathComponent("captured"))
        #expect(captured == Data(expected.utf8))
    }

    private func rendererResources(_ surface: Ghostty.Surface) async -> Ghostty.Surface.RendererResources {
        await Task.detached(priority: .utility) { surface.rendererResources() }.value
    }

    @Test func atlasSnapshotsSeparateSharedCPUFromOwnedFrameTextures() async throws {
        let config = try TemporaryConfig("cursor-effect = false\ncursor-style-blink = false\nshell-integration = none")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        var base = Ghostty.SurfaceConfiguration()
        base.command = "/bin/cat"
        base.workingDirectory = FileManager.default.temporaryDirectory.path
        let first = Ghostty.SurfaceView(app, baseConfig: base)
        let second = Ghostty.SurfaceView(app, baseConfig: base)
        let one = try #require(first.surfaceModel)
        let two = try #require(second.surfaceModel)
        let hidden = await rendererResources(one)
        #expect(hidden.gridID != 0)
        #expect(hidden.gpuTextureCount == 0)
        #expect(hidden.gpuQueueCount == 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 240),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = try #require(window.contentView)
        first.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        second.frame = NSRect(x: 320, y: 0, width: 320, height: 240)
        root.addSubview(first)
        root.addSubview(second)
        window.orderFront(nil)
        first.sizeDidChange(first.bounds.size)
        second.sizeDidChange(second.bounds.size)
        one.setVisible(true)
        two.setVisible(true)
        let owner = try #require(first.windowCompositor)
        #expect(second.windowCompositor === owner)
        owner.updateGeometry()
        for (view, surface) in [(first, one), (second, two)] {
            let revision = surface.renderRevision
            surface.sendText("atlas-ready🙂\n")
            try await waitForText("atlas-ready🙂", in: surface)
            try await waitForFrame(after: revision, in: view)
        }
        let a = await rendererResources(one)
        let b = await rendererResources(two)
        #expect(a.gridID == b.gridID)
        #expect(a.cpuGrayscaleBytes == b.cpuGrayscaleBytes)
        #expect(a.cpuColorBytes == b.cpuColorBytes)
        #expect(a.cpuNodeBytes == b.cpuNodeBytes)
        #expect(a.codepointEntries == b.codepointEntries)
        #expect(a.glyphEntries == b.glyphEntries)
        #expect(a.cpuGrayscaleBytes > 0 && a.cpuColorBytes > 0)
        #expect(a.codepointCapacity >= a.codepointEntries && a.glyphCapacity >= a.glyphEntries)
        for usage in [a, b] {
            #expect(usage.gpuTextureCount == 6)
            #expect(usage.gpuQueueCount == 1)
            #expect(usage.gpuAllocatedBytes >= usage.gpuTexelBytes)
            #expect(usage.gpuAllocatedBytes > 0)
        }
        #expect(one.changeFontSize(by: 2))
        let deadline = ContinuousClock.now + .seconds(5)
        var changed = await rendererResources(one)
        while changed.gridID == a.gridID && ContinuousClock.now < deadline {
            await Task.yield()
            changed = await rendererResources(one)
        }
        #expect(changed.gridID != a.gridID)
        #expect(await rendererResources(two).gridID == a.gridID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let encoded = try encoder.encode([a, b])
        let json = try #require(String(data: encoded, encoding: .utf8))
        print("RENDERER_RESOURCE_JSON " + json)
        print("ATLAS_RESOURCE_METRIC sharedCPUBytes=\(a.cpuGrayscaleBytes + a.cpuColorBytes + a.cpuNodeBytes) " +
            "gpuOwnedBytes=\(a.gpuAllocatedBytes + b.gpuAllocatedBytes) textures=\(a.gpuTextureCount + b.gpuTextureCount)")
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
        #expect(snapshot.viewportCellRange.length > 0)
        #expect(surface!.perform(.reset))
        view = nil
        surface = nil
        #expect(snapshot.text.contains("桥接🙂snapshot"))
    }

    @Test func nativeTextInputUsesDocumentUTF16RangesAndSafeCompositionAnchor() async throws {
        let view = makeView(command: "/usr/bin/printf 'A中🙂e\u{301}Z'")
        let surface = try #require(view.surfaceModel)
        try await waitForText("A中🙂e\u{301}Z", in: surface)
        #expect(surface.perform(.selectAll))
        let document = try #require(surface.readAccessibility())
        #expect(view.selectedRange() == document.selectedRanges.first)
        let emoji = (document.text as NSString).range(of: "🙂")
        var actual = NSRange(location: NSNotFound, length: 0)
        let substring = view.attributedSubstring(
            forProposedRange: NSRange(location: emoji.location + 1, length: 1), actualRange: &actual)
        #expect(substring?.string == "🙂")
        #expect(actual == emoji)
        let fallback = view.attributedSubstring(
            forProposedRange: NSRange(location: NSNotFound, length: 1), actualRange: &actual)
        #expect(fallback?.string == document.text)
        #expect(actual == document.selectedRanges.first)
        view.setMarkedText("未提交", selectedRange: NSRange(location: 3, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        let rect = view.firstRect(forCharacterRange: NSRange(location: NSNotFound, length: 0), actualRange: nil)
        #expect(abs(rect.minX) < 100_000)
        view.unmarkText()
    }

    @Test func compositionCaretUsesRenderedWidthAndSurrogateBoundaries() async throws {
        let view = makeView()
        let surface = try #require(view.surfaceModel)
        surface.setSize(width: 640, height: 480)
        for scale in [1.0, 2.0] {
            surface.setContentScale(x: scale, y: scale)
            view.setMarkedText("中🙂e\u{301}", selectedRange: NSRange(location: 5, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
            let base = surface.compositionPoint(atUTF16Offset: 0)
            let middle = surface.compositionPoint(atUTF16Offset: 1)
            let split = surface.compositionPoint(atUTF16Offset: 2)
            let end = surface.compositionPoint(atUTF16Offset: 5)
            let cell = surface.size.cellPixels.width / scale
            #expect(abs((middle.minX - base.minX) - 2 * cell) < 1)
            #expect(split.minX == middle.minX)
            #expect(abs((end.minX - base.minX) - 5 * cell) < 1)
            #expect(surface.compositionPoint(atUTF16Offset: 9999) == surface.imePoint)
            view.unmarkText()
        }
    }

    @Test func inputWithoutSelectionDoesNotSerializeHistory() async throws {
        let view = makeView(command: "/usr/bin/printf 'input probe 中🙂'")
        let surface = try #require(view.surfaceModel)
        try await waitForText("input probe 中🙂", in: surface)
        let captures = surface.accessibilityCaptureCount
        for _ in 0..<100 {
            #expect(view.selectedRange() == NSRange(location: NSNotFound, length: 0))
        }
        #expect(surface.accessibilityCaptureCount == captures)
        #expect(surface.perform(.selectAll))
        #expect(view.selectedRange().location != NSNotFound)
        let snapshot = try #require(surface.readAccessibility())
        #expect(view.selectedRange() == snapshot.selectedRanges.first)
    }

    @Test(.enabled(if: try MetalTestSupport.metal4Available(), "Requires a Metal 4 GPU"))
    func selectionOnlyUpdateRepaintsNativeHighlight() async throws {
        let config = try TemporaryConfig("""
        background = #000000
        foreground = #ffffff
        selection-background = #ff0000
        selection-foreground = #000000
        cursor-style-blink = false
        cursor-effect = false
        shell-integration = none
        """)
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        try #require(app.startupConfigurationErrors.isEmpty)
        var base = Ghostty.SurfaceConfiguration()
        base.command = "/bin/sh -c 'printf selection-ready; exec /bin/cat'"
        let view = Ghostty.SurfaceView(app, baseConfig: base)
        let surface = try #require(view.surfaceModel)
        let window = try show(view)
        defer { window.close() }
        try await waitForText("selection-ready", in: surface)
        try await waitForFrame(after: 0, in: view)
        func redPixels(_ png: Data) throws -> Int {
            let bitmap = try #require(NSBitmapImageRep(data: png))
            try #require(bitmap.bitsPerSample == 8 && bitmap.samplesPerPixel >= 3)
            // The thumbnail is encoded as sRGB. Inspect its stored components:
            // colorAt returns calibrated RGB, whose conversion shifts pure red.
            var pixel = [Int](repeating: 0, count: bitmap.samplesPerPixel)
            var count = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    bitmap.getPixel(&pixel, atX: x, y: y)
                    if pixel[0] > 153 && pixel[1] < 26 && pixel[2] < 26 {
                        count += 1
                    }
                }
            }
            return count
        }
        let before = try redPixels(#require(view.thumbnailPNG()))
        let revision = surface.renderRevision
        #expect(surface.perform(.selectAll))
        var selected = 0
        try await NativeTestWait.until("selection highlight pixels", timeout: .seconds(5), polling: .milliseconds(10),
            diagnostics: { "before=\(before), selected=\(selected)\n" + NativeTestWait.surfaceState(surface, view: view) }, {
            guard surface.renderRevision > revision else { return false }
            selected = try redPixels(#require(view.thumbnailPNG()))
            return selected > before + 100
        })
        #expect(selected > before + 100)
        #expect(view.healthy)
    }

    @Test func selectionUpdatesReuseAccessibilityDocumentAndLineIndex() async throws {
        // The DSR reply shares the IO mailbox with the initial resize. Wait
        // for that reply before publishing ready so a delayed startup resize
        // cannot invalidate the document during the selection assertions.
        let command = "/bin/sh -c 'stty -echo -icanon min 1 time 0; printf \"\\033[5n\"; " +
            "dd bs=1 count=4 >/dev/null 2>/dev/null; printf \"old\\n桥接🙂é\\nready\"; exec /bin/cat'"
        let view = makeView(command: command)
        let surface = try #require(view.surfaceModel)
        try await waitForText("ready", in: surface)
        let initial = try #require(surface.readAccessibility())
        let captures = surface.accessibilityCaptureCount
        var indexed = AccessibilityText(initial)
        #expect(surface.perform(.selectAll))
        for direction in Array(repeating: ["left", "right"], count: 20).flatMap({ $0 }) {
            #expect(surface.perform(action: "adjust_selection:\(direction)"))
            let update = try #require(surface.readAccessibility())
            #expect(update.textRevision == initial.textRevision)
            #expect(update.cocoaText === initial.cocoaText)
            #expect(surface.accessibilityCaptureCount == captures)
            indexed = AccessibilityText(update, reusing: indexed)
            #expect(indexed.selectedRanges == update.selectedRanges)
            #expect(view.selectedRange() == update.selectedRanges.first)
            let reference = AccessibilityText(update)
            #expect(indexed.utf16Length == reference.utf16Length)
            for offset in 0...indexed.utf16Length { #expect(indexed.line(for: offset) == reference.line(for: offset)) }
        }
        #expect(surface.perform(.reset))
        let reset = try #require(surface.readAccessibility())
        #expect(reset.textRevision > initial.textRevision)
        #expect(surface.accessibilityCaptureCount == captures + 1)
        #expect(initial.text.contains("桥接🙂"))
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

    @Test(.enabled(if: try MetalTestSupport.metal4Available(), "Requires a Metal 4 GPU"))
    func completedFramesAdvanceThumbnailRevisionAndMetadataSkipsImages() async throws {
        let config = try TemporaryConfig("cursor-effect = false\ncursor-style-blink = false\nshell-integration = none")
        let view = makeView(configPath: config.temporaryFile.path)
        let surface = try #require(view.surfaceModel)
        let window = try show(view)
        defer { window.close() }
        let initialRevision = surface.renderRevision
        #expect(surface.sendKeyEvent(.init(keyCode: 0, action: .press, text: "first frame")))
        try await waitForText("first frame", in: surface)
        try await waitForFrame(after: initialRevision, in: view)
        try await NativeTestWait.until("thumbnail completed frame is stable", timeout: .seconds(2), polling: .milliseconds(5),
                                      diagnostics: { NativeTestWait.surfaceState(surface, view: view) }, { view.windowCompositor?.worker.isIdle == true })
        let revision = surface.renderRevision
        #expect(TerminalEntity(view).displayRepresentation.image == nil)
        #expect((await TerminalEntity.withThumbnail(view)).displayRepresentation.image != nil)
        #expect(surface.sendKeyEvent(.init(keyCode: 0, action: .press, text: "new frame")))
        try await waitForText("new frame", in: surface)
        try await waitForFrame(after: revision, in: view)
        #expect(surface.renderRevision > revision)
    }

    @Test(.enabled(if: try MetalTestSupport.metal4Available(), "Requires a Metal 4 GPU"))
    func focusVisibilityChangesAndAppKitInvalidationKeepRendering() async throws {
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
            // AppKit may create a backing store for the structural input layer.
            // Invalidating it must not interrupt window rendering or snapshots.
            let layer = try #require(view.layer)
            layer.display()
            #expect(view.windowCompositor != nil)
            #expect(view.thumbnailPNG() != nil)
            #expect(view.healthy)
        }
    }

    @Test(.enabled(if: try MetalTestSupport.metal4Available(), "Requires a Metal 4 GPU"))
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
        // More snapshots than drawable slots, then resume normal rendering.
        // A preview must neither exhaust the pool nor mutate the image buffers.
        for _ in 0..<4 {
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
        let afterSnapshots = surface.renderRevision
        #expect(surface.sendKeyEvent(.init(keyCode: 0, action: .press, text: "after-snapshots")))
        try await waitForText("after-snapshots", in: surface)
        try await waitForFrame(after: afterSnapshots, in: view)
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
        // Keep publishing on the main thread while the search worker consumes.
        // Navigation barriers must survive bursts, and the final query wins.
        for index in 0..<300 {
            #expect(surface.search("superseded-query-\(index)"))
            if index.isMultiple(of: 25) { #expect(surface.navigateSearch(.next)) }
        }
        #expect(surface.search(needle))
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
