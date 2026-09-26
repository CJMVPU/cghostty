import AppKit
import XCTest

/// Fixed-duration workloads, not performance thresholds. Compare identical
/// ReleaseLocal runs; trace timings include instrumentation and scheduling.
final class GhosttyRendererPerformanceUITests: GhosttyCustomConfigCase {
    @MainActor func testVsyncWorkloads() throws { try runWorkloads(vsync: true) }
    @MainActor func testTimerWorkloads() throws { try runWorkloads(vsync: false) }

    @MainActor private func runWorkloads(vsync: Bool) throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "Motion disabled")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = directory.appendingPathComponent("mode")
        let script = directory.appendingPathComponent("workload.py")
        try "idle".write(to: control, atomically: true, encoding: .utf8)
        try """
        import base64, os, pathlib, sys, time, tty
        tty.setraw(sys.stdin.fileno())
        control = pathlib.Path(sys.argv[1])
        mode, tick = '', 0
        def graphics(command, data=b''):
            sys.stdout.write('\\033_G' + command + ';' + base64.b64encode(data).decode() + '\\033\\\\')
        while True:
            requested = control.read_text()
            if requested != mode:
                mode, tick = requested, 0
                graphics('a=d,d=A,q=2')
                cols, rows = os.get_terminal_size()
                sys.stdout.write('\\033[2J')
                for row in range(1, rows):
                    sys.stdout.write('\\033[%d;1H' % row + ('renderer0123456789 ' * cols)[:cols-1])
                if mode == 'kitty':
                    sys.stdout.write('\\033[1;1H')
                    graphics('a=T,f=24,s=16,v=16,i=7,q=2', bytes([255,0,0])*256)
                    graphics('a=f,f=24,s=16,v=16,i=7,z=40,q=2', bytes([0,0,255])*256)
                    graphics('a=a,i=7,r=1,z=40,s=3,v=0,q=2')
                sys.stdout.write('\\033]0;Perf ' + mode + '\\007\\033[2 q\\033[?25h')
            if mode != 'idle':
                cols, rows = os.get_terminal_size()
                if mode == 'typing':
                    row, col = 3, 2 + tick % max(2, cols - 4)
                    sys.stdout.write('\\033[%d;%dHX' % (row, col))
                else:
                    row = 3 + (tick % 2) * max(1, rows - 6)
                    col = 2 + ((tick // 2) % 2) * max(1, cols - 5)
                    sys.stdout.write('\\033[%d;%dH' % (row, col))
            sys.stdout.flush()
            tick += 1
            time.sleep(0.032 if mode == 'typing' else 0.160)
        """.write(to: script, atomically: true, encoding: .utf8)
        try updateConfig("""
        command = /usr/bin/python3 -u \(script.path) \(control.path)
        shell-integration = none
        confirm-close-surface = false
        cursor-effect = true
        cursor-style-blink = false
        font-size = 10
        window-width = 140
        window-height = 42
        window-vsync = \(vsync)
        """)
        let app = try ghosttyApplication(defaultsSuite: UUID().uuidString)
        app.launchArguments += ["--render-trace=true", "--render-trace-directory=\(directory.path)"]
        app.launch()
        app.activate()
        defer { app.terminate() }
        let window = app.windows.firstMatch
        XCTAssertTrue(window.wait(for: \.title, toEqual: "Perf idle", timeout: 10))
        for phase in ["idle", "typing", "jumps", "kitty", "split"] {
            if phase == "split" {
                app.groups["Terminal pane"].firstMatch.typeKey("d", modifierFlags: .command)
                XCTAssertTrue(app.groups["Right pane"].waitForExistence(timeout: 5))
            }
            try phase.write(to: control, atomically: true, encoding: .utf8)
            XCTAssertTrue(window.wait(for: \.title, toEqual: "Perf \(phase)", timeout: 5))
            // Explicit benchmark warm-up and observation windows. Readiness is
            // checked above; these durations define the measured workload.
            observationWindow(seconds: 1)
            let starts = try traceLines(directory)
            observationWindow(seconds: 6)
            let ends = try traceLines(directory)
            XCTAssertFalse(ends.isEmpty, "Trace instrumentation must be enabled")
            for (file, lines) in ends {
                let slice = lines.dropFirst(starts[file]?.count ?? 0).joined(separator: "\n")
                let attachment = XCTAttachment(data: Data(slice.utf8), uniformTypeIdentifier: "public.comma-separated-values-text")
                attachment.name = "perf-\(vsync ? "vsync" : "timer")-\(phase)-\(file)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    private func traceLines(_ directory: URL) throws -> [String: [String]] {
        var result: [String: [String]] = [:]
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where file.pathExtension == "csv" {
            let contents = try String(contentsOf: file, encoding: .utf8)
            // Ignore a partial final line while the renderer is writing.
            result[file.lastPathComponent] = contents.components(separatedBy: "\n").dropLast().map { $0 }
        }
        return result
    }

    private func observationWindow(seconds: TimeInterval) {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        let predicate = NSPredicate { _, _ in ProcessInfo.processInfo.systemUptime >= end }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: seconds + 2), .completed)
    }
}
