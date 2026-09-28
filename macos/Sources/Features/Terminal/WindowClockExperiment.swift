#if CGHOSTTY_CLOCK_EXPERIMENT
import AppKit
import QuartzCore

/// Standalone foreground integration harness. Compiled out of ordinary builds.
/// Uses real terminal sessions/PTYs/renderers, not a clear-only Metal reference.
@MainActor enum WindowClockExperiment {
    enum Failure: Error { case progress(String), foreground, resource }
    private final class Session { weak var surface: Ghostty.Surface?; init(_ surface: Ghostty.Surface) { self.surface = surface } }
    private static var measuring = false
    private static var focusLost = false
    static func run(app: Ghostty.App, output: URL) async {
        let observer = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if measuring { focusLost = true } }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        var results: [[String: Any]] = []
        var failure = ""
        var sessions: [Session] = []
        let env = ProcessInfo.processInfo.environment
        let samples = Int(env["CGHOSTTY_CLOCK_SAMPLES"] ?? "200") ?? 200
        let root = output.deletingLastPathComponent()
        let configPath = env["CGHOSTTY_CONFIG_PATH"]!
        var phaseID: UInt64 = 0
        var probeID: UInt64 = 0
        let variant = "metal"
        do {
            guard app.readiness == .ready else { throw Failure.resource }
            let phases = ["idle", "echo-idle", "echo-active", "mixed", "cold", "history", "vim-responsive", "vim-instant", "vim-scroll"]
            let selected = env["CGHOSTTY_CLOCK_PHASES"]?.split(separator: ",").map(String.init) ?? phases
            guard !selected.isEmpty, selected.allSatisfy(phases.contains) else { throw Failure.progress("unknown phase") }
            for name in selected {
                let paneCount = name == "mixed" ? 4 : 1
                let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 800, height: 480),
                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.title = "cghostty clock experiment: \(name)"
                window.isReleasedWhenClosed = false
                window.isOpaque = false
                window.backgroundColor = .clear
                var views: [Ghostty.SurfaceView] = []
                defer { window.close(); views.forEach { $0.removeFromSuperview() } }
                let isVim = name.hasPrefix("vim")
                let mode = root.appendingPathComponent("mode")
                try "idle".write(to: mode, atomically: true, encoding: .utf8)
                for index in 0..<paneCount {
                    var config = Ghostty.SurfaceConfiguration()
                    let control = index == 0 ? mode : root.appendingPathComponent("quiet-mode")
                    try "idle".write(to: control, atomically: true, encoding: .utf8)
                    config.command = isVim ? "\(env["CGHOSTTY_CLOCK_NVIM"]!) --clean -n \(root.appendingPathComponent("vim.txt").path)" :
                        "/usr/bin/python3 -u \(env["CGHOSTTY_CLOCK_WORKLOAD"]!) \(control.path)"
                    config.workingDirectory = root.path
                    let view = Ghostty.SurfaceView(app, baseConfig: config)
                    view.frame = CGRect(x: 0, y: index * 480 / paneCount, width: 800, height: 480 / paneCount)
                    window.contentView!.addSubview(view)
                    views.append(view)
                    if let surface = view.surfaceModel { sessions.append(Session(surface)) }
                }
                window.makeKeyAndOrderFront(nil)
                NSApp.activate()
                for view in views { view.sizeDidChange(view.bounds.size); view.surfaceModel?.setVisible(true) }
                let target = views.last!.surfaceModel!
                target.setFocus(true)
                window.makeFirstResponder(views.last!)
                let worker = views.first!.windowCompositor!.worker
                try await wait("foreground") { NSApp.isActive && window.isKeyWindow }
                do {
                    try await wait("PTY ready") {
                        views.allSatisfy { $0.surfaceModel!.readContents(viewport: false).contains(isVim ? "clock-row-0000" : "clock-ready") }
                    }
                } catch {
                    throw Failure.progress("PTY ready: " + views.map { $0.surfaceModel!.readContents(viewport: false) }.joined(separator: " | "))
                }
                if name == "vim-instant" {
                    let path = root.appendingPathComponent("instant.ghostty")
                    try (String(contentsOfFile: configPath, encoding: .utf8) + "\ncursor-effect-mode = instant\n")
                        .write(to: path, atomically: true, encoding: .utf8)
                    target.updateConfig(Ghostty.Config(at: path.path))
                }
                // Defined warmup excludes initial window/PTY lifecycle work from measurements.
                try await Task.sleep(for: .seconds(1))
                try await wait("settled") { worker.isIdle }
                focusLost = false
                measuring = true
                defer { measuring = false }
                phaseID += 1
                let before = worker.statistics
                target.traceCompositor(stage: 13, sequence: phaseID, time: CACurrentMediaTime(), prediction: 1)
                let start = CACurrentMediaTime()
                var inputCount = 0
                if name == "idle" {
                    // This is the measured idle observation interval, not a readiness delay.
                    try await Task.sleep(for: .seconds(2))
                } else if name.hasPrefix("echo") || name == "mixed" {
                    if name == "mixed" {
                        try "flood".write(to: mode, atomically: true, encoding: .utf8)
                        try await wait("load ready") { views[0].surfaceModel!.readContents(viewport: false).contains("ASCII output") }
                    }
                    for _ in 0..<samples {
                        try foreground(window)
                        if name == "echo-idle" { try await wait("idle input") { worker.isIdle } }
                        probeID += 1
                        let marker = "probe-\(probeID)-end"
                        target.traceCompositor(stage: 6, sequence: probeID, time: CACurrentMediaTime())
                        guard target.sendKeyEvent(.init(keyCode: 0, action: .press, text: "\r\n\(marker) ")) else { throw Failure.resource }
                        try await wait("echo") { target.readContents(viewport: false).contains(marker) }
                        target.traceCompositor(stage: 7, sequence: probeID, time: 0)
                        inputCount += 1
                        if name != "echo-idle" { try await Task.sleep(for: .milliseconds(16)) } // Defined input cadence.
                    }
                    try "idle".write(to: mode, atomically: true, encoding: .utf8)
                } else if name == "cold" {
                    try "cold".write(to: mode, atomically: true, encoding: .utf8)
                    try await wait("cold glyph output", timeout: 30) { target.readContents(viewport: false).contains("cold-300") }
                    try "idle".write(to: mode, atomically: true, encoding: .utf8)
                } else if name == "history" {
                    try "history".write(to: mode, atomically: true, encoding: .utf8)
                    try await wait("history") { target.readContents(viewport: false).contains("history-0599") }
                    for index in 0..<300 {
                        try foreground(window)
                        target.sendMouseScroll(.init(x: 0, y: index < 150 ? 12 : -12, mods: .init(precision: true)))
                        try await Task.sleep(for: .milliseconds(16)) // Defined input cadence.
                    }
                } else {
                    for index in 0..<300 {
                        try foreground(window)
                        let key = name == "vim-scroll" ? "j" : ["l", "j", "h", "k"][(index / 8) % 4]
                        guard target.sendKeyEvent(.init(keyCode: 0, action: .press, text: key)) else { throw Failure.resource }
                        try await Task.sleep(for: .milliseconds(16)) // Defined key-repeat cadence.
                    }
                }
                try await wait("final presentation", timeout: 30) { worker.isIdle }
                try foreground(window)
                target.traceCompositor(stage: 13, sequence: phaseID, time: CACurrentMediaTime(), prediction: 0)
                guard !focusLost else { throw Failure.foreground }
                measuring = false
                let after = worker.statistics
                results.append(["id": phaseID, "name": name, "start": start, "end": CACurrentMediaTime(),
                    "inputs": inputCount, "panes": paneCount, "active": NSApp.isActive, "key": window.isKeyWindow,
                    "submitted": after.submitted - before.submitted, "displayed": after.displayed - before.displayed,
                    "failed": after.failed - before.failed, "screenMaxFPS": window.screen?.maximumFramesPerSecond ?? 0])
            }
        } catch { failure = String(describing: error) }
        // Session teardown flushes trace writers; failure is part of the result.
        do { try await wait("session retirement") { sessions.allSatisfy { $0.surface == nil } } } catch { if failure.isEmpty { failure = String(describing: error) } }
        let data: [String: Any] = ["variant": variant, "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "samples": samples, "error": failure, "phases": results,
            "drawableCount": Int(env["CGHOSTTY_CLOCK_DRAWABLES"] ?? "3") ?? 3,
            "ratePolicy": env["CGHOSTTY_CLOCK_RATE"] ?? "max"]
        do { try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]).write(to: output) } catch { Ghostty.logger.error("Clock experiment result write failed: \(error)") }
        NSApp.terminate(nil)
    }

    private static func foreground(_ window: NSWindow) throws {
        guard NSApp.isActive, window.isKeyWindow else { throw Failure.foreground }
    }

    private static func wait(_ context: String, timeout: Double = 15, until predicate: () -> Bool) async throws {
        let deadline = CACurrentMediaTime() + timeout
        while !predicate() {
            guard CACurrentMediaTime() < deadline else { throw Failure.progress(context) }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}
#endif
