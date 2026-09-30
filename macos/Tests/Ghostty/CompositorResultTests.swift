@testable import Ghostty
import Testing

struct CompositorResultTests {
    @Test func namedFlagsDecodeStableCStorage() {
        let mismatch = CompositorResult(rawValue: 6)
        #expect(mismatch == [.needsFrame, .geometryMismatch])
        let failure = CompositorResult(rawValue: 10)
        #expect(failure == [.needsFrame, .failed])
        let rendered = CompositorResult(rawValue: 17)
        #expect(rendered.contains(.repaint))
        #expect(rendered.contains(.composed))
        #expect(!rendered.contains(.failed))
        #expect(CompositorResult(rawValue: 0).isEmpty)
    }
}
