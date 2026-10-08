import AppKit
import Darwin
import Testing
@testable import Ghostty

/// Opt-in measurements, kept out of ordinary CI. Source readiness is semantic;
/// these are sampled resources and PTY echo latency, not an FPS or RSS claim.
@Suite(.serialized)
@MainActor struct RendererResourceProbeTests {
    nonisolated struct Threads: Codable, Sendable {
        let total: Int
        let names: [String: Int]
    }

    nonisolated struct Record: Codable, Sendable {
        let surfaces: Int
        let before: Threads
        let ready: Threads
        let released: Threads
        let uniqueGrids: Int
        let sharedAtlasBytes: UInt64
        let ownedAtlasGPUBytes: UInt64
        let ownedPrivateQueues: UInt64
        let echoNanoseconds: [Int64]
        let resources: [Ghostty.Surface.RendererResources]
    }

    private func threads() throws -> Threads {
        var ports: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        let result = task_threads(mach_task_self_, &ports, &count)
        try #require(result == KERN_SUCCESS, "task_threads returned \(result)")
        let list = try #require(ports, "task_threads returned \(result)")
        defer {
            _ = vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)),
                vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        var names: [String: Int] = [:]
        for port in UnsafeBufferPointer(start: list, count: Int(count)) {
            defer { _ = mach_port_deallocate(mach_task_self_, port) }
            // Query by retained Mach right; a pthread pointer could become
            // invalid if an unrelated framework worker exits during sampling.
            var info = thread_extended_info_data_t()
            var words = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(words)) {
                    thread_info(port, thread_flavor_t(THREAD_EXTENDED_INFO), $0, &words)
                }
            }
            guard status == KERN_SUCCESS else { continue }
            let value = withUnsafePointer(to: &info.pth_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) }
            }
            names[value.isEmpty ? "<unnamed>" : value, default: 0] += 1
        }
        return Threads(total: Int(count), names: names)
    }

    private func waitForText(_ text: String, in surface: Ghostty.Surface) async throws {
        try await NativeTestWait.until("resource probe PTY readiness", timeout: .seconds(10), polling: .milliseconds(5),
            diagnostics: { NativeTestWait.surfaceState(surface, expectedText: text) }, {
            surface.readContents(viewport: false).contains(text)
        })
    }

    private func echo(_ surface: Ghostty.Surface) async throws -> [Int64] {
        var values: [Int64] = []
        for index in 0..<12 {
            let marker = "resource-echo-\(index)"
            let start = ContinuousClock.now
            surface.sendText(marker + "\n")
            try await waitForText(marker, in: surface)
            let elapsed = start.duration(to: .now).components
            values.append(elapsed.seconds * 1_000_000_000 + elapsed.attoseconds / 1_000_000_000)
        }
        return values
    }

    @Test(.enabled(if: (Int(ProcessInfo.processInfo.environment["CGHOSTTY_RESOURCE_SURFACES"] ?? "") ?? 0) > 0))
    func hiddenSurfaceResources() async throws {
        let count = try #require(Int(ProcessInfo.processInfo.environment["CGHOSTTY_RESOURCE_SURFACES"] ?? ""))
        try #require((1...32).contains(count))
        let config = try TemporaryConfig("shell-integration = none\ncursor-style-blink = false\ncursor-effect = false")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let before = try threads()
        var base = Ghostty.SurfaceConfiguration()
        base.command = "/bin/sh -c 'stty -echo; printf probe-ready; exec /bin/cat'"
        base.workingDirectory = FileManager.default.temporaryDirectory.path
        var views: [Ghostty.SurfaceView] = []
        var samples: [Ghostty.Surface.RendererResources] = []
        for _ in 0..<count {
            let view = Ghostty.SurfaceView(app, baseConfig: base)
            let surface = try #require(view.surfaceModel)
            surface.setVisible(false)
            views.append(view)
            try await waitForText("probe-ready", in: surface)
            samples.append(await Task.detached { surface.rendererResources() }.value)
        }
        let ready = try threads()
        let latency = try await echo(#require(views.first?.surfaceModel))
        var grids: Set<UInt64> = []
        var cpu: UInt64 = 0
        for sample in samples where grids.insert(sample.gridID).inserted {
            cpu += sample.cpuGrayscaleBytes + sample.cpuColorBytes + sample.cpuNodeBytes
        }
        views.removeAll()
        let record = Record(surfaces: count, before: before, ready: ready, released: try threads(),
            uniqueGrids: grids.count, sharedAtlasBytes: cpu,
            ownedAtlasGPUBytes: samples.reduce(0) { $0 + $1.gpuAllocatedBytes },
            ownedPrivateQueues: samples.reduce(0) { $0 + $1.gpuQueueCount },
            echoNanoseconds: latency, resources: samples)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = try #require(String(data: encoder.encode(record), encoding: .utf8))
        print("HIDDEN_RESOURCE_JSON " + json)
        #expect(grids.count == 1)
        #expect(ready.names["cf_release", default: 0] == 0)
        #expect(samples.allSatisfy { $0.gpuTextureCount == 0 && $0.gpuQueueCount == 0 })
    }
}
