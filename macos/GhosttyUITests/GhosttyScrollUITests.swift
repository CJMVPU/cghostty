import AppKit
import XCTest

final class GhosttyScrollUITests: GhosttyCustomConfigCase {
    @MainActor func testRegionMotionKeepsStatusFixed() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = directory.appendingPathComponent("mode")
        let script = directory.appendingPathComponent("scroll.py")
        try "idle".write(to: control, atomically: true, encoding: .utf8)
        try """
        import pathlib, sys, time
        control = pathlib.Path(sys.argv[1])
        sys.stdout.write('\\033[?1049h\\033[?25l')
        tick = 0
        while True:
            mode = control.read_text()
            sys.stdout.write('\\033[?2026h')
            if mode == 'idle':
                sys.stdout.write('\\033[r\\033[0m\\033[2J')
                for row in range(3,19):
                    sys.stdout.write('\\033[%d;1H\\033[48;2;%sm\\033[2K' % (row, '255;0;0' if row % 2 else '0;0;255'))
                sys.stdout.write('\\033[20;1H\\033[48;2;0;255;0m\\033[2K')
            else:
                sys.stdout.write('\\033[0m\\033[3;18r' + ('\\033[S' if tick % 2 else '\\033[T'))
            sys.stdout.write('\\033[?2026l\\033]0;Scroll ' + mode + '\\007')
            sys.stdout.flush()
            tick += 1
            time.sleep(0.16)
        """.write(to: script, atomically: true, encoding: .utf8)
        try updateConfig(baseConfig + "\ncommand = /usr/bin/python3 -u \(script.path) \(control.path)")
        let app = try ghosttyApplication(defaultsSuite: UUID().uuidString)
        app.launchEnvironment["MTL_DEBUG_LAYER"] = "1"
        app.launchArguments += ["--render-trace=true", "--render-trace-directory=\(directory.path)"]
        app.launch()
        app.activate()
        defer { app.terminate() }
        let window = app.windows.firstMatch
        XCTAssertTrue(window.wait(for: \.title, toEqual: "Scroll idle", timeout: 10))
        let surface = window.textViews.firstMatch
        let baseline = try waitForBands(surface)
        let pitch = baseline.edges[1] - baseline.edges[0]
        XCTAssertGreaterThan(pitch, 10)
        try "moving".write(to: control, atomically: true, encoding: .utf8)
        XCTAssertTrue(window.wait(for: \.title, toEqual: "Scroll moving", timeout: 5))
        var intermediates = 0
        for _ in 0..<16 {
            let shot = surface.screenshot()
            guard let bands = Bands(shot.image), bands.edges.count > 2 else { continue }
            XCTAssertEqual(bands.green, baseline.green, "The status row must not move")
            if bands.edges.contains(where: { edge in
                let remainder = abs(edge - baseline.edges[0]) % pitch
                return remainder > 1 && remainder < pitch - 1
            }) {
                intermediates += 1
                if intermediates == 1 { add(XCTAttachment(screenshot: shot)) }
            }
        }
        XCTAssertGreaterThan(intermediates, 0, "Rendered rows must pass through sub-cell positions")
        try "idle".write(to: control, atomically: true, encoding: .utf8)
        XCTAssertTrue(window.wait(for: \.title, toEqual: "Scroll idle", timeout: 5))
        XCTAssertEqual(try waitForBands(surface).green, baseline.green)
        try assertHealthyTrace(directory, requiresMotion: true)
    }

    @MainActor func testWheelScrollbackAndNeovimMouse() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("history.py")
        try """
        import sys, time
        for i in range(200):
            print('history %03d ' % i + 'content ' * 8)
        print('\\033]0;Scroll history\\007', end='', flush=True)
        time.sleep(120)
        """.write(to: script, atomically: true, encoding: .utf8)
        try updateConfig(baseConfig + "\ncommand = /usr/bin/python3 -u \(script.path)")
        let app = try ghosttyApplication(defaultsSuite: UUID().uuidString)
        app.launchEnvironment["MTL_DEBUG_LAYER"] = "1"
        app.launchArguments += ["--render-trace=true", "--render-trace-directory=\(directory.path)"]
        app.launch()
        app.activate()
        var window = app.windows.firstMatch
        XCTAssertTrue(window.wait(for: \.title, toEqual: "Scroll history", timeout: 10))
        let before = window.textViews.firstMatch.screenshot().pngRepresentation
        window.textViews.firstMatch.scroll(byDeltaX: 0, deltaY: 12)
        let changed = NSPredicate { _, _ in window.textViews.firstMatch.screenshot().pngRepresentation != before }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: changed, object: nil)], timeout: 5), .completed)
        window.textViews.firstMatch.scroll(byDeltaX: 0, deltaY: -8)
        app.terminate()
        try assertHealthyTrace(directory, requiresMotion: true)

        let nvim = "/opt/homebrew/bin/nvim"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: nvim), "Neovim is not installed")
        let config = directory.appendingPathComponent("init.lua")
        try """
        vim.o.mouse = 'a'
        vim.o.laststatus = 2
        vim.o.title = true
        vim.o.statusline = 'FIXED STATUS'
        vim.o.scrolloff = 0
        vim.api.nvim_create_autocmd('VimEnter', {callback = function()
          local lines = {}
          for i=1,500 do lines[i] = string.format('Neovim row %03d', i) end
          vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
          vim.api.nvim_set_hl(0, 'StatusLine', {bg='#00ff00', fg='#000000'})
          vim.o.titlestring = 'Scroll nvim 1'
        end})
        vim.api.nvim_create_autocmd('WinScrolled', {callback = function()
          vim.o.titlestring = 'Scroll nvim '..vim.fn.line('w0')
        end})
        """.write(to: config, atomically: true, encoding: .utf8)
        try updateConfig(baseConfig + "\ncommand = \(nvim) -u \(config.path) -i NONE -n")
        app.launch()
        app.activate()
        defer { app.terminate() }
        window = app.windows.firstMatch
        XCTAssertTrue(window.wait(for: \.title, toEqual: "Scroll nvim 1", timeout: 10))
        let surface = window.textViews.firstMatch
        let status = Bands(surface.screenshot().image)?.green
        XCTAssertNotNil(status)
        surface.scroll(byDeltaX: 0, deltaY: -80)
        let moved = NSPredicate { _, _ in window.title.hasPrefix("Scroll nvim ") && window.title != "Scroll nvim 1" }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: moved, object: nil)], timeout: 5), .completed)
        XCTAssertEqual(Bands(surface.screenshot().image)?.green, status)
        app.terminate()
        try assertHealthyTrace(directory, requiresMotion: true)
    }

    @MainActor func testSynchronizedBoundariesNeverShowIncompleteRows() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("synchronized.py")
        try """
        import os, time
        def rows(flip):
            a, b = ('255;0;0', '0;0;255') if flip else ('0;0;255', '255;0;0')
            return '\\033[3;1H\\033[48;2;%sm\\033[2K\\033[4;1H\\033[48;2;%sm\\033[2K' % (a,b)
        os.write(1, ('\\033[?1049h\\033[?25l\\033[2J' + rows(False)).encode())
        for tick in range(300):
            # Complete two rows, then release/set in the SAME write. The
            # next (unfinished) frame has a green row that must stay hidden.
            data = rows(tick % 2) + '\\033[?2026l\\033[?2026h'
            data += '\\033[3;1H\\033[48;2;0;255;0m\\033[2K'
            data += '\\033]0;Synchronized rows\\007'
            os.write(1, data.encode())
            time.sleep(0.25)
        """.write(to: script, atomically: true, encoding: .utf8)
        try updateConfig(baseConfig + "\ncommand = /usr/bin/python3 -u \(script.path)")
        let app = try ghosttyApplication(defaultsSuite: UUID().uuidString)
        app.launchEnvironment["MTL_DEBUG_LAYER"] = "1"
        app.launchArguments += ["--render-trace=true", "--render-trace-directory=\(directory.path)"]
        app.launch()
        app.activate()
        defer { app.terminate() }
        let window = app.windows.firstMatch
        XCTAssertTrue(window.wait(for: \.title, toEqual: "Synchronized rows", timeout: 10))
        for index in 0..<16 {
            let shot = window.textViews.firstMatch.screenshot()
            let bands = try XCTUnwrap(Bands(shot.image))
            XCTAssertTrue(bands.green.isEmpty, "A row from the incomplete frame leaked through mode 2026")
            XCTAssertEqual(bands.edges.count, 1, "Both completed color rows must remain visible")
            if index == 0 { add(XCTAttachment(screenshot: shot)) }
        }
        app.terminate()
        try assertHealthyTrace(directory, requiresMotion: false)
    }

    private var baseConfig: String {
        """
        shell-integration = none
        confirm-close-surface = false
        background = #000000
        foreground = #ffffff
        smooth-scroll = true
        cursor-style-blink = false
        font-size = 16
        """
    }

    private func temporaryDirectory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }

    @MainActor private func waitForBands(_ surface: XCUIElement) throws -> Bands {
        var found: Bands?
        let ready = NSPredicate { _, _ in
            found = Bands(surface.screenshot().image)
            return (found?.edges.count ?? 0) > 5 && !(found?.green.isEmpty ?? true)
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 5), .completed)
        return try XCTUnwrap(found)
    }

    private func assertHealthyTrace(_ directory: URL, requiresMotion: Bool) throws {
        let paths = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "csv" }
        let lines = try paths.flatMap { try String(contentsOf: $0, encoding: .utf8).split(separator: "\n").map(String.init) }
        XCTAssertFalse(lines.isEmpty)
        XCTAssertFalse(lines.contains { $0.hasPrefix("gpu,") && $0.split(separator: ",")[3] == "0" })
        if requiresMotion {
            for path in paths {
                let trace = try String(contentsOf: path, encoding: .utf8)
                XCTAssertTrue(trace.split(separator: "\n").contains { $0.hasPrefix("scroll,") }, "Each terminal must render its own scroll transition")
            }
        }
    }

    private struct Bands {
        var edges: [Int] = []
        var green: [Int] = []
        init?(_ image: NSImage) {
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
            let x = bitmap.pixelsWide / 2
            var previous = 0
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let red = color.redComponent > 0.65 && color.redComponent > color.greenComponent * 2 && color.redComponent > color.blueComponent * 2
                let blue = color.blueComponent > 0.65 && color.blueComponent > color.greenComponent * 2 && color.blueComponent > color.redComponent * 2
                let kind = red ? 1 : blue ? 2 : 0
                if kind != 0 && previous != 0 && kind != previous { edges.append(y) }
                if color.greenComponent > 0.65 && color.greenComponent > color.redComponent * 1.3 && color.greenComponent > color.blueComponent * 1.3 { green.append(y) }
                previous = kind
            }
        }
    }
}
