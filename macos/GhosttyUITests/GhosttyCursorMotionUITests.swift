import AppKit
import XCTest

final class GhosttyCursorMotionUITests: GhosttyCustomConfigCase {
    @MainActor func testLeadingEdgesAndThinCursorThroughMetal() throws {
        try runMotion(vsync: true)
    }

    @MainActor func testLeadingEdgesWithoutVsync() throws {
        try runMotion(vsync: false)
    }

    @MainActor private func runMotion(vsync: Bool) throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "Motion is disabled by system accessibility settings")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = directory.appendingPathComponent("mode")
        let script = directory.appendingPathComponent("motion.py")
        try "idle".write(to: control, atomically: true, encoding: .utf8)
        // Controlled PTY output uses the same hide/move/show pattern as Vim.
        // The interval is the animation stimulus, not a readiness wait.
        try """
        import pathlib, sys, time
        control = pathlib.Path(sys.argv[1])
        mode, tick, thin = '', 0, False
        while True:
            requested = control.read_text()
            if requested != mode:
                mode, tick = requested, 0
                if mode == 'bar': thin = True
                sys.stdout.write('\\033]0;Motion ' + mode + '\\007')
            row, col = 8, 8
            if mode in ('right', 'bar'): col += (tick % 12) * 3
            if mode == 'down': row = 4 + tick % 12
            sys.stdout.write('\\033[?25l')
            sys.stdout.flush()
            if tick % 7 == 0: time.sleep(0.005)
            sys.stdout.write('\\033[' + ('6' if thin else '2') + ' q')
            sys.stdout.write('\\033[%d;%dH\\033[?25h' % (row, col))
            sys.stdout.flush()
            tick += 1
            time.sleep(0.032)
        """.write(to: script, atomically: true, encoding: .utf8)
        try updateConfig("""
        command = /usr/bin/python3 -u \(script.path) \(control.path)
        shell-integration = none
        confirm-close-surface = false
        cursor-effect = smooth
        cursor-color = #00ff00
        cursor-style-blink = false
        background = #000000
        foreground = #ffffff
        font-size = 20
        window-vsync = \(vsync)
        """)
        let app = try ghosttyApplication(defaultsSuite: UUID().uuidString)
        app.launchEnvironment["MTL_DEBUG_LAYER"] = "1"
        app.launch()
        app.activate()
        defer { app.terminate() }
        let window = app.windows.firstMatch
        XCTAssertTrue(window.wait(for: \.title, toEqual: "Motion idle", timeout: 10))
        app.groups["Terminal pane"].firstMatch.click()
        let initial = try waitForCursor(in: window, name: "Resting block") { $0.width > 8 && $0.height > 15 }

        try "right".write(to: control, atomically: true, encoding: .utf8)
        XCTAssertTrue(window.wait(for: \.title, toEqual: "Motion right", timeout: 5))
        _ = try waitForCursor(in: window, name: "Wider right leading edge") {
            $0.width > initial.width * 3 / 2 && $0.columnSpan($0.maxX - 2) > $0.columnSpan($0.minX + 2) + 2
        }
        window.buttons["_XCUI:MinimizeWindow"].click()
        app.menuBars.menuBarItems["Window"].click()
        app.menuItems["Motion right"].click()
        _ = try waitForCursor(in: window, name: "Motion resumes after minimizing") {
            $0.width > initial.width * 3 / 2 && $0.columnSpan($0.maxX - 2) > $0.columnSpan($0.minX + 2) + 2
        }
        try "down".write(to: control, atomically: true, encoding: .utf8)
        XCTAssertTrue(window.wait(for: \.title, toEqual: "Motion down", timeout: 5))
        _ = try waitForCursor(in: window, name: "Wider bottom leading edge") {
            $0.height > initial.height + 4 &&
                $0.rowSpan($0.maxY - 2) > initial.width &&
                $0.rowSpan($0.maxY - 2) > $0.rowSpan($0.minY + 2) + 1
        }
        try "bar".write(to: control, atomically: true, encoding: .utf8)
        XCTAssertTrue(window.wait(for: \.title, toEqual: "Motion bar", timeout: 5))
        try "stop".write(to: control, atomically: true, encoding: .utf8)
        XCTAssertTrue(window.wait(for: \.title, toEqual: "Motion stop", timeout: 5))
        _ = try waitForCursor(in: window, name: "Restored thin insert cursor") {
            $0.width < initial.width / 2 && abs($0.height - initial.height) <= 2
        }
    }

    @MainActor private func waitForCursor(in window: XCUIElement, name: String,
                                          matching: @escaping (Mask) -> Bool) throws -> Mask {
        var result: Mask?
        var lastMask: Mask?
        var screenshot: XCUIScreenshot?
        let predicate = NSPredicate { _, _ in
            MainActor.assumeIsolated {
                // Exclude the green full-screen button in the native titlebar.
                let image = window.textViews.firstMatch.screenshot()
                screenshot = image
                guard let mask = Mask(image.image) else { return false }
                lastMask = mask
                guard matching(mask) else { return false }
                result = mask
                return true
            }
        }
        let status = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 10)
        let attachment = XCTAttachment(screenshot: try XCTUnwrap(screenshot))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let dimensions = lastMask.map { "\($0.width)x\($0.height), top \($0.rowSpan($0.minY + 2)), bottom \($0.rowSpan($0.maxY - 2))" } ?? "missing"
        XCTAssertEqual(status, .completed, "\(name): \(dimensions)")
        return try XCTUnwrap(result)
    }

    private struct Mask {
        var columns: [Int: ClosedRange<Int>] = [:]
        var rows: [Int: ClosedRange<Int>] = [:]
        var minX: Int { columns.keys.min()! }
        var maxX: Int { columns.keys.max()! }
        var minY: Int { rows.keys.min()! }
        var maxY: Int { rows.keys.max()! }
        var width: Int { maxX - minX + 1 }
        var height: Int { maxY - minY + 1 }
        func columnSpan(_ x: Int) -> Int { columns[x].map { $0.upperBound - $0.lowerBound + 1 } ?? 0 }
        func rowSpan(_ y: Int) -> Int { rows[y].map { $0.upperBound - $0.lowerBound + 1 } ?? 0 }

        init?(_ image: NSImage) {
            guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            let width = source.width
            let height = source.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                                CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
                context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    guard bytes[i] < 60, bytes[i + 1] > 170, bytes[i + 2] < 60 else { continue }
                    columns[x] = min(columns[x]?.lowerBound ?? y, y)...max(columns[x]?.upperBound ?? y, y)
                    rows[y] = min(rows[y]?.lowerBound ?? x, x)...max(rows[y]?.upperBound ?? x, x)
                }
            }
            if columns.isEmpty { return nil }
        }
    }
}
