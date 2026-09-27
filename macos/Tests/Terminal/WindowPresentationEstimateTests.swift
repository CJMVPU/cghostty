import Testing
@testable import Ghostty

struct WindowPresentationEstimateTests {
    @Test func warmsUpAndRejectsInvalidOrRetiredFeedback() {
        var estimate = WindowPresentationEstimate()
        for _ in 0..<4 { estimate.record(target: 1, presented: 1.02, generation: 0) }
        #expect(estimate.offset == 0)
        estimate.record(target: 1, presented: 0, generation: 0)
        estimate.record(target: 1, presented: .infinity, generation: 0)
        #expect(estimate.offset == 0)
        estimate.record(target: 1, presented: 1.02, generation: 0)
        #expect(abs(estimate.offset - 0.02) < 1e-9)
        estimate.reset()
        for _ in 0..<31 { estimate.record(target: 1, presented: 1.02, generation: 0) }
        #expect(estimate.offset == 0)
    }

    @Test func recentFramesReplaceTheOldMedian() {
        var estimate = WindowPresentationEstimate()
        for _ in 0..<31 { estimate.record(target: 1, presented: 1.02, generation: 0) }
        for _ in 0..<31 { estimate.record(target: 2, presented: 2.01, generation: 0) }
        #expect(abs(estimate.offset - 0.01) < 1e-9)
    }
}
