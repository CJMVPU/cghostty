import Testing

@MainActor struct NativeTestWaitTests {
    @Test func timeoutReportsStageStateAndCallSiteOnce() async throws {
        var diagnostics = 0
        var predicates = 0
        do {
            try await NativeTestWait.until("text and compositor idle", timeout: .zero, polling: .milliseconds(5),
                diagnostics: { diagnostics += 1; return "textReady=false, idle=true, completed=2, submitted=2" },
                fileID: "Fixture.swift", line: 42, { predicates += 1; return false })
            Issue.record("An unsatisfied zero-deadline wait must throw")
        } catch let failure as NativeTestWait.Timeout {
            #expect(failure.stage == "text and compositor idle")
            #expect(failure.description.contains("Fixture.swift:42"))
            #expect(failure.description.contains("textReady=false, idle=true, completed=2, submitted=2"))
        }
        #expect(diagnostics == 1)
        #expect(predicates == 1)
    }

    @Test func readinessPrecedesDeadlineAndDoesNotReadDiagnostics() async throws {
        try await NativeTestWait.until("already ready", timeout: .zero, polling: .milliseconds(10),
            diagnostics: { Issue.record("Successful waits must not read diagnostics"); return "" }, { true })
    }

    @Test func waitsForLaterReadiness() async throws {
        var attempts = 0
        try await NativeTestWait.until("later readiness", timeout: .seconds(1), polling: .milliseconds(1),
            diagnostics: { "attempts=\(attempts)" }, { attempts += 1; return attempts == 3 })
        #expect(attempts == 3)
    }

    @Test func predicateErrorsPropagateWithoutTimeoutDiagnostics() async throws {
        enum Probe: Error { case failed }
        do {
            try await NativeTestWait.until("throwing predicate", timeout: .seconds(1), polling: .milliseconds(1),
                diagnostics: { Issue.record("Predicate failures must not become timeouts"); return "" }, { throw Probe.failed })
            Issue.record("The predicate error must propagate")
        } catch Probe.failed {}
    }

    @Test func cancellationPropagates() async throws {
        let task = Task {
            try await NativeTestWait.until("cancelled wait", timeout: .seconds(1), polling: .milliseconds(1),
                diagnostics: { Issue.record("Cancellation must not become a timeout"); return "" }, { false })
        }
        task.cancel()
        do {
            try await task.value
            Issue.record("A cancelled polling wait must throw")
        } catch is CancellationError {}
    }
}
