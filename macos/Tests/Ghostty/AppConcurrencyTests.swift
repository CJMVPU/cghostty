import Foundation
import Testing
@testable import Ghostty

@MainActor
struct AppConcurrencyTests {
    @Test func wakeupGateCoalescesConcurrentProducersAndAllowsReentrantWork() async {
        let gate = AppWakeupGate()
        let scheduled = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<1_000 { group.addTask { gate.request() } }
            var count = 0
            for await accepted in group where accepted { count += 1 }
            return count
        }
        #expect(scheduled == 1)
        gate.beginTick()
        // A producer during draining must be able to schedule another tick.
        #expect(gate.request())
        #expect(!gate.request())
        gate.beginTick()
        #expect(gate.request())
    }

    @Test func queuedWakeupDoesNotRetainApp() async {
        var app: Ghostty.App? = Ghostty.App(configPath: "/dev/null")
        weak let releasedApp = app
        Ghostty.App.wakeup(Unmanaged.passUnretained(app!).toOpaque())
        app = nil
        #expect(releasedApp == nil)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(releasedApp == nil)
    }

    @Test func backgroundWakeupReturnsToMainActor() async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        #expect(app.readiness == .ready)
        _ = try #require(app.app)

        await Task.detached { @Sendable in
            dispatchPrecondition(condition: .notOnQueue(.main))
            Ghostty.App.wakeup(Unmanaged.passUnretained(app).toOpaque())
        }.value

        // Drain the tick queued by wakeup before releasing its unretained C userdata.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(app.readiness == .ready)
    }
}
