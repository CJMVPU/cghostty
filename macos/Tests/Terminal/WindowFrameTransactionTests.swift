@testable import Ghostty
import Testing

struct WindowFrameTransactionTests {
    @Test func encoderFailureBeforeSubmissionReleasesWithoutDraining() {
        var value = WindowFrameTransaction()
        #expect(value.abort() == .release)
        #expect(value.abort() == .none)
    }

    @Test(arguments: [1, 2, 4]) func partialSubmissionFailureDrainsBeforeRelease(commits: Int) {
        var value = WindowFrameTransaction()
        for _ in 0..<commits { value.didSubmit() }
        #expect(value.abort() == .drainAndRelease)
        #expect(value.abort() == .none)
    }

    @Test func finalCompletionOwnsSlotEvenBeforePresentation() {
        var value = WindowFrameTransaction()
        value.didSubmit()
        value.handoffToCompletion()
        #expect(value.abort() == .none)
        #expect(value.abort() == .none)
    }
}
