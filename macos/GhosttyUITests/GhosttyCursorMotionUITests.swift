import AppKit
import XCTest

final class GhosttyCursorMotionUITests: GhosttyCustomConfigCase {
    @MainActor func testWideCellsAndShapeChangesKeepConnectedMotion() throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "Motion is disabled by system accessibility settings")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = directory.appendingPathComponent("mode")
        let script = directory.appendingPathComponent("geometry.py")
        try "idle".write(to: control, atomically: true, encoding: .utf8)
        // The right target is a real two-cell character. Every moving step
        // changes width; the shape mode additionally cycles DECSCUSR styles.
        try """
        import pathlib, sys, time
        control = pathlib.Path(sys.argv[1])
        sys.stdout.write('\\033[2J')
        mode, tick = '', 0
        while True:
            requested = control.read_text()
            if requested != mode:
                mode, tick = requested, 0
            col = 8 if mode == 'idle' else 60 if mode == 'idlewide' else [8, 60][tick % 2]
            style = [2, 6, 4][tick % 3] if mode == 'shape' else 2
            # Repaint after startup resizes; publish text and cursor together.
            sys.stdout.write('\\033[?2026h\\033[?25l\\033[8;60H中')
            sys.stdout.write('\\033[%d q\\033[8;%dH\\033[?25h\\033[?2026l' % (style, col))
            sys.stdout.write('\\033]0;Geometry ' + mode + '\\007')
            sys.stdout.flush()
            tick += 1
            time.sleep(0.160)
        """.write(to: script, atomically: true, encoding: .utf8)
        try updateConfig("""
        command = /usr/bin/python3 -u \(script.path) \(control.path)
        shell-integration = none
        confirm-close-surface = false
        cursor-effect = true
        cursor-color = #00ff00
        cursor-text = #00ff00
        cursor-style-blink = false
        background = #000000
        foreground = #000000
        font-size = 16
        """)
        let app = try ghosttyApplication(defaultsSuite: UUID().uuidString)
        app.launchEnvironment["MTL_DEBUG_LAYER"] = "1"
        app.launch()
        app.activate()
        defer { app.terminate() }
        let window = app.windows.firstMatch
        XCTAssertTrue(window.wait(for: \.title, toEqual: "Geometry idle", timeout: 10))
        app.groups["Terminal pane"].firstMatch.click()
        let native = try waitForCursor(in: window, name: "Single-cell block") { $0.width > 8 && $0.height > 15 }
        try "idlewide".write(to: control, atomically: true, encoding: .utf8)
        XCTAssertTrue(window.wait(for: \.title, toEqual: "Geometry idlewide", timeout: 5))
        _ = try waitForCursor(in: window, name: "Chinese two-cell block") {
            abs($0.width - native.width * 2) <= 1 && $0.height == native.height
        }
        for mode in ["wide", "shape"] {
            try mode.write(to: control, atomically: true, encoding: .utf8)
            XCTAssertTrue(window.wait(for: \.title, toEqual: "Geometry \(mode)", timeout: 5))
            _ = try waitForCursor(in: window, name: "Connected \(mode) transition") {
                $0.width > native.width * 4 && $0.isConnected
            }
            var movingFrames = 0
            for _ in 0..<12 {
                guard let mask = Mask(window.textViews.firstMatch.screenshot().image), !mask.isOccluded else { continue }
                if mask.width > native.width * 4 && mask.isConnected { movingFrames += 1 }
            }
            XCTAssertGreaterThanOrEqual(movingFrames, 4, "\(mode) must keep moving across repeated geometry changes")
        }
        try "idle".write(to: control, atomically: true, encoding: .utf8)
        XCTAssertTrue(window.wait(for: \.title, toEqual: "Geometry idle", timeout: 5))
        _ = try waitForCursor(in: window, name: "Exact single-cell shape after settling") {
            $0.width == native.width && $0.height == native.height
        }
    }

    @MainActor func testCellCacheRefreshAndBlinkTransitions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = directory.appendingPathComponent("mode")
        let script = directory.appendingPathComponent("cache.py")
        try "red".write(to: control, atomically: true, encoding: .utf8)
        try """
        import pathlib, sys, time
        control = pathlib.Path(sys.argv[1])
        mode, tick = '', 0
        while True:
            requested = control.read_text()
            if requested != mode:
                mode = requested
                color = '255;0;0' if mode == 'red' else '0;0;255'
                sys.stdout.write('\\033[0m\\033[2J\\033[1;1H\\033[38;2;' + color + 'mMMMMMMMM')
                sys.stdout.write('\\033[2;1H\\033[48;2;' + color + 'm          \\033[0m\\033[3;8H')
                sys.stdout.write('\\033[' + ('5' if mode == 'blink' else '6') + ' q')
                sys.stdout.write('\\033]0;Cache ' + mode + '\\007')
            if mode in ['red', 'blue']:
                sys.stdout.write('\\033[3;%dH' % (8 + (tick % 2) * 30))
            sys.stdout.flush()
            tick += 1
            time.sleep(0.160)
        """.write(to: script, atomically: true, encoding: .utf8)
        try updateConfig("""
        command = /usr/bin/python3 -u \(script.path) \(control.path)
        shell-integration = none
        confirm-close-surface = false
        background = #000000
        cursor-color = #00ff00
        cursor-effect = true
        """)
        let app = try ghosttyApplication(defaultsSuite: UUID().uuidString)
        app.launchEnvironment["MTL_DEBUG_LAYER"] = "1"
        app.launch()
        app.activate()
        defer { app.terminate() }
        let window = app.windows.firstMatch
        XCTAssertTrue(window.wait(for: \.title, toEqual: "Cache red", timeout: 10))
        for mode in ["red", "blue", "red", "blue"] {
            try mode.write(to: control, atomically: true, encoding: .utf8)
            XCTAssertTrue(window.wait(for: \.title, toEqual: "Cache \(mode)", timeout: 5))
            let ready = NSPredicate { _, _ in
                let colors = Self.colorCounts(window.textViews.firstMatch.screenshot().image)
                return mode == "red" ? colors.red > 500 && colors.blue == 0 : colors.blue > 500 && colors.red == 0
            }
            let status = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 5)
            let snapshot = window.textViews.firstMatch.screenshot()
            let attachment = XCTAttachment(screenshot: snapshot)
            attachment.name = "Cell cache \(mode)"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertEqual(status, .completed, "\(Self.colorCounts(snapshot.image))")
            for _ in 0..<8 {
                let colors = Self.colorCounts(window.textViews.firstMatch.screenshot().image)
                XCTAssertTrue(mode == "red" ? colors.red > 500 && colors.blue == 0 : colors.blue > 500 && colors.red == 0)
            }
        }
        try "blink".write(to: control, atomically: true, encoding: .utf8)
        XCTAssertTrue(window.wait(for: \.title, toEqual: "Cache blink", timeout: 5))
        var seenVisible = false
        var seenHidden = false
        let blinking = NSPredicate { _, _ in
            let visible = Self.colorCounts(window.textViews.firstMatch.screenshot().image).green > 10
            seenVisible = seenVisible || visible
            seenHidden = seenHidden || !visible
            return seenVisible && seenHidden
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: blinking, object: nil)], timeout: 6), .completed)
        try "steady".write(to: control, atomically: true, encoding: .utf8)
        XCTAssertTrue(window.wait(for: \.title, toEqual: "Cache steady", timeout: 5))
        for _ in 0..<10 {
            XCTAssertGreaterThan(Self.colorCounts(window.textViews.firstMatch.screenshot().image).green, 10)
        }
    }

    private static func colorCounts(_ image: NSImage) -> (red: Int, blue: Int, green: Int) {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return (0, 0, 0) }
        var result = (red: 0, blue: 0, green: 0)
        // Sparse sampling keeps screenshot inspection inexpensive.
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                // Screenshot color profiles need not encode pure primaries as
                // exact 0/1 device RGB. Classify dominant channels instead.
                let red = color.redComponent, green = color.greenComponent, blue = color.blueComponent
                if red > 0.6 && red > blue + 0.3 && red > green + 0.3 { result.red += 1 }
                if blue > 0.6 && blue > red + 0.3 && blue > green + 0.3 { result.blue += 1 }
                if green > 0.6 && green > red + 0.3 && green > blue + 0.3 { result.green += 1 }
            }
        }
        return result
    }

    @MainActor func testStableBodyAndTailThroughMetal() throws {
        try runMotion(vsync: true)
    }

    @MainActor func testStableBodyAndTailWithoutVsync() throws {
        try runMotion(vsync: false)
    }

    @MainActor private func runMotion(vsync: Bool) throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "Motion is disabled by system accessibility settings")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = directory.appendingPathComponent("mode")
        let script = directory.appendingPathComponent("motion.py")
        try "block-idle-32".write(to: control, atomically: true, encoding: .utf8)
        // One-cell PTY moves and slow repeats exercise ordinary editing, not
        // just large search jumps. Input cadence is stimulus, not a test wait.
        try """
        import pathlib, sys, time
        control = pathlib.Path(sys.argv[1])
        mode, tick, row, col = '', 0, 8, 8
        while True:
            requested = control.read_text()
            if requested != mode:
                mode, tick = requested, 0
                sys.stdout.write('\\033]0;Motion ' + mode + '\\007')
            shape, direction, interval = mode.split('-')
            offset = min(tick % 24, 24 - tick % 24)
            if direction != 'idle':
                row, col = 8, 8
                if direction == 'right': col += offset
                if direction == 'left': col += 12 - offset
                if direction == 'down': row += offset
                if direction == 'up': row += 12 - offset
                if direction == 'diagonal': row, col = row + offset, col + offset
                if direction.startswith('jump'):
                    row, col = 4, 8
                    side = tick % 2
                    if direction == 'jumpright': col += side * 52
                    if direction == 'jumpdown': row += side * 20
                    if direction == 'jumpdiagonal': row, col = row + side * 18, col + side * 30
                    if direction == 'jumpturn': row, col = [(4, 8), (4, 60), (24, 60), (24, 8)][tick % 4]
            sys.stdout.write('\\033[?25l')
            sys.stdout.flush()
            if tick % 7 == 0: time.sleep(0.005)
            style = {'block': '2', 'bar': '6', 'underline': '4'}[shape]
            sys.stdout.write('\\033[' + style + ' q')
            sys.stdout.write('\\033[%d;%dH\\033[?25h' % (row, col))
            sys.stdout.flush()
            tick += 1
            time.sleep(int(interval) / 1000)
        """.write(to: script, atomically: true, encoding: .utf8)
        try updateConfig("""
        command = /usr/bin/python3 -u \(script.path) \(control.path)
        shell-integration = none
        confirm-close-surface = false
        cursor-effect = true
        cursor-color = #00ff00
        cursor-style-blink = false
        background = #000000
        foreground = #ffffff
        font-size = 16
        window-vsync = \(vsync)
        window-padding-x = \(vsync ? 12 : 0)
        window-padding-y = \(vsync ? 8 : 0)
        """)
        let app = try ghosttyApplication(defaultsSuite: UUID().uuidString)
        app.launchEnvironment["MTL_DEBUG_LAYER"] = "1"
        app.launch()
        app.activate()
        defer { app.terminate() }
        let window = app.windows.firstMatch
        XCTAssertTrue(window.wait(for: \.title, toEqual: "Motion block-idle-32", timeout: 10))
        app.groups["Terminal pane"].firstMatch.click()
        let block = try waitForCursor(in: window, name: "Resting block") { $0.width > 8 && $0.height > 15 }

        for mode in ["block-right-32", "block-left-60", "block-down-100", "block-up-32", "block-diagonal-60"] {
            try setMode(mode, control: control, window: window)
            try assertStableMotion(in: window, native: block,
                                   name: mode, requireTail: mode == "block-right-32")
        }
        window.buttons["_XCUI:MinimizeWindow"].click()
        app.menuBars.menuBarItems["Window"].click()
        app.menuItems["Motion block-diagonal-60"].click()
        try assertStableMotion(in: window, native: block, name: "Restored motion")
        try setMode("block-idle-32", control: control, window: window)
        _ = try waitForCursor(in: window, name: "Exact resting block") {
            $0.width == block.width && $0.height == block.height
        }

        try assertLongTravel(in: window, control: control, native: block, block: block, shape: "block")
        for shape in ["bar", "underline"] {
            try setMode("\(shape)-idle-32", control: control, window: window)
            let native = try waitForCursor(in: window, name: "Native \(shape)") {
                shape == "bar" ? $0.width == 3 && $0.height == block.height : $0.height == 3 && $0.width == block.width
            }
            for direction in ["right", "down"] {
                try setMode("\(shape)-\(direction)-60", control: control, window: window)
                try assertStableMotion(in: window, native: native, name: "\(shape) \(direction)")
            }
            try assertLongTravel(in: window, control: control, native: native, block: block, shape: shape)
            try setMode("\(shape)-idle-32", control: control, window: window)
            _ = try waitForCursor(in: window, name: "Restored \(shape)") {
                $0.width == native.width && $0.height == native.height
            }
        }
    }

    @MainActor private func assertLongTravel(in window: XCUIElement, control: URL, native: Mask, block: Mask, shape: String) throws {
        for direction in ["jumpright", "jumpdown", "jumpdiagonal", "jumpturn"] {
            let mode = "\(shape)-\(direction)-\(direction == "jumpturn" ? 32 : 160)"
            try setMode(mode, control: control, window: window)
            // A rendered extension beyond one whole cell proves that neither
            // the old cell-width cap nor a thin-stroke cap remains active.
            _ = try waitForCursor(in: window, name: "Uncapped connected tail: \(mode)") {
                let extraX = Double($0.width) - Double(native.width) * 1.12
                let extraY = Double($0.height) - Double(native.height) * 1.12
                return max(extraX, extraY) > Double(block.width) && $0.isConnected
            }
            try assertStableMotion(in: window, native: native, name: mode)
        }
    }

    @MainActor private func setMode(_ mode: String, control: URL, window: XCUIElement) throws {
        try mode.write(to: control, atomically: true, encoding: .utf8)
        XCTAssertTrue(window.wait(for: \.title, toEqual: "Motion \(mode)", timeout: 5))
    }

    @MainActor private func assertStableMotion(in window: XCUIElement, native: Mask,
                                               name: String, requireTail: Bool = false) throws {
        // Leave one pixel for subpixel sampling at the antialiased boundary.
        let bodyWidth = max(native.width, Int((Double(native.width) * 1.12).rounded()) - 1)
        let bodyHeight = max(native.height, Int((Double(native.height) * 1.12).rounded()) - 1)
        let expanded: (Mask) -> Bool = {
            $0.containsBody(width: bodyWidth, height: bodyHeight) && $0.isConnected
        }
        _ = try waitForCursor(in: window, name: "\(name), native \(native.width)x\(native.height)", matching: expanded)
        // Check an intact body inside the union, not just its bounding box:
        // a long tail must not mask a body that has become thin or clipped.
        var observed = 0
        var tailFrames = 0
        for _ in 0..<12 {
            let screenshot = window.textViews.firstMatch.screenshot()
            guard let mask = Mask(screenshot.image), !mask.isOccluded else { continue }
            observed += 1
            if !expanded(mask) {
                let attachment = XCTAttachment(screenshot: screenshot)
                attachment.name = "Unexpected shape: \(name)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            XCTAssertTrue(expanded(mask), "\(name): \(mask.width)x\(mask.height), native \(native.width)x\(native.height)")
            if Double(mask.width) > ceil(Double(native.width) * 1.12) + 1 ||
                Double(mask.height) > ceil(Double(native.height) * 1.12) + 1 {
                tailFrames += 1
                if tailFrames == 1 {
                    let attachment = XCTAttachment(screenshot: screenshot)
                    attachment.name = "Visible tail: \(name)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
        XCTAssertGreaterThanOrEqual(observed, 8, "Need a sequence of visible frames")
        if requireTail { XCTAssertGreaterThan(tailFrames, 0, "Repeated input should render a trailing follower") }
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
                guard let mask = Mask(image.image), !mask.isOccluded else { return false }
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
        var pixels: Set<Int> = []
        var pixelStride = 0
        var indicatorBounds: CGRect?
        var minX: Int { columns.keys.min()! }
        var maxX: Int { columns.keys.max()! }
        var minY: Int { rows.keys.min()! }
        var maxY: Int { rows.keys.max()! }
        var width: Int { maxX - minX + 1 }
        var height: Int { maxY - minY + 1 }
        // macOS may overlay its blue Caps Lock indicator on the text view.
        // Only unobstructed frames can measure the renderer's actual shape;
        // keep the minimum visible-frame count and all geometry assertions.
        var isOccluded: Bool {
            indicatorBounds?.intersects(CGRect(x: minX, y: minY, width: width, height: height)) == true
        }
        func columnSpan(_ x: Int) -> Int { columns[x].map { $0.upperBound - $0.lowerBound + 1 } ?? 0 }
        func rowSpan(_ y: Int) -> Int { rows[y].map { $0.upperBound - $0.lowerBound + 1 } ?? 0 }

        var isConnected: Bool {
            guard let first = pixels.first else { return false }
            var remaining = pixels
            remaining.remove(first)
            var pending = [first]
            while let pixel = pending.popLast() {
                for neighbor in [pixel - pixelStride, pixel + pixelStride, pixel - 1, pixel + 1] {
                    // Horizontal neighbors cannot wrap across a scanline.
                    if abs(neighbor - pixel) == 1 && neighbor / pixelStride != pixel / pixelStride { continue }
                    if remaining.remove(neighbor) != nil { pending.append(neighbor) }
                }
            }
            return remaining.isEmpty
        }

        func containsBody(width: Int, height: Int) -> Bool {
            guard self.width >= width, self.height >= height else { return false }
            for top in minY...(maxY - height + 1) {
                for left in minX...(maxX - width + 1) {
                    let centerX = left + width / 2
                    let centerY = top + height / 2
                    guard let horizontal = rows[centerY], let vertical = columns[centerX],
                          horizontal.contains(left), horizontal.contains(left + width - 1),
                          vertical.contains(top), vertical.contains(top + height - 1) else { continue }
                    // The inner rectangle must also be solid. Its corners lie
                    // inside the mildly oval body, away from antialiasing.
                    let innerLeft = left + width / 4
                    let innerRight = left + width - 1 - width / 4
                    let solid = (top + height / 4...top + height - 1 - height / 4).allSatisfy {
                        rows[$0]?.contains(innerLeft) == true && rows[$0]?.contains(innerRight) == true
                    }
                    if solid { return true }
                }
            }
            return false
        }

        init?(_ image: NSImage) {
            guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            let width = source.width
            let height = source.height
            pixelStride = width
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
                    if bytes[i] < 40, bytes[i + 1] > 90, bytes[i + 1] < 200, bytes[i + 2] > 220 {
                        let pixel = CGRect(x: x, y: y, width: 1, height: 1)
                        indicatorBounds = indicatorBounds?.union(pixel) ?? pixel
                    }
                    guard bytes[i] < 60, bytes[i + 1] > 170, bytes[i + 2] < 60 else { continue }
                    pixels.insert(y * width + x)
                    columns[x] = min(columns[x]?.lowerBound ?? y, y)...max(columns[x]?.upperBound ?? y, y)
                    rows[y] = min(rows[y]?.lowerBound ?? x, x)...max(rows[y]?.upperBound ?? x, x)
                }
            }
            if columns.isEmpty { return nil }
        }
    }
}
