import Foundation
import Testing
@testable import Ghostty

@MainActor struct PresentationGateTests {
    private func waitForRegistration(_ gate: PresentationGate, count: Int = 1) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while gate.pendingCount != count && ContinuousClock.now < deadline { await Task.yield() }
        try #require(gate.pendingCount == count)
    }

    @Test func completionResumesAllWaitersAndReadyWaitIsImmediate() async throws {
        let gate = PresentationGate()
        let generation = gate.begin()
        let first = Task { await gate.wait() }
        let second = Task { await gate.wait() }
        defer { gate.cancel(); first.cancel(); second.cancel() }
        try await waitForRegistration(gate, count: 2)
        gate.complete(generation)
        #expect(await first.value)
        #expect(await second.value)
        #expect(await gate.wait())
        #expect(gate.pendingCount == 0)
    }

    @Test func replacedGenerationCannotCompleteNewPresentation() async throws {
        let gate = PresentationGate()
        let old = gate.begin()
        let first = Task { await gate.wait() }
        defer { gate.cancel(); first.cancel() }
        try await waitForRegistration(gate)
        let current = gate.begin()
        #expect(await first.value == false)
        let second = Task { await gate.wait() }
        defer { second.cancel() }
        try await waitForRegistration(gate)
        gate.complete(old)
        #expect(gate.pendingCount == 1)
        gate.complete(current)
        #expect(await second.value)
    }

    @Test func cancellationDoesNotCancelOtherWaiters() async throws {
        let gate = PresentationGate()
        let generation = gate.begin()
        let first = Task { await gate.wait() }
        let second = Task { await gate.wait() }
        defer { gate.cancel(); first.cancel(); second.cancel() }
        try await waitForRegistration(gate, count: 2)
        first.cancel()
        #expect(await first.value == false)
        #expect(gate.pendingCount == 1)
        gate.complete(generation)
        #expect(await second.value)
    }

    @Test func hidingEndsPendingPresentation() async throws {
        let gate = PresentationGate()
        #expect(await gate.wait() == false)
        _ = gate.begin()
        let task = Task { await gate.wait() }
        defer { gate.cancel(); task.cancel() }
        try await waitForRegistration(gate)
        gate.cancel()
        #expect(await task.value == false)
        #expect(await gate.wait() == false)
    }
}
