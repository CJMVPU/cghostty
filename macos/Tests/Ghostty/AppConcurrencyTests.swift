import Foundation
import Testing
@testable import Ghostty

@MainActor
struct AppConcurrencyTests {
    @Test func backgroundWakeupReturnsToMainActor() async throws {
        let app = Ghostty.App()
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
