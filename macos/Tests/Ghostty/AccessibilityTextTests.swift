@testable import Ghostty
import Foundation
import Testing

struct AccessibilityTextTests {
    @Test func indicesUseUTF16IncludingEmojiAndCombiningMarks() {
        let value = AccessibilityText("😀e\u{301}\n中文\nZ")
        #expect(value.utf16Length == 9)
        #expect(value.line(for: 2) == 0)
        #expect(value.line(for: 4) == 0)
        #expect(value.line(for: 5) == 1)
        #expect(value.line(for: 8) == 2)
        #expect(value.substring(in: NSRange(location: 0, length: 2)) == "😀")
        #expect(value.substring(in: NSRange(location: 2, length: 2)) == "e\u{301}")
        #expect(value.substring(in: NSRange(location: 2, length: 1)) == "e")
        #expect(value.substring(in: NSRange(location: 3, length: 1)) == "\u{301}")
        #expect(value.substring(in: NSRange(location: 5, length: 2)) == "中文")
    }

    @Test func emptyTrailingAndCRLFLines() {
        #expect(AccessibilityText("").line(for: 0) == 0)
        let value = AccessibilityText("A\r\nB\n")
        #expect(value.line(for: 2) == 0)
        #expect(value.line(for: 3) == 1)
        #expect(value.line(for: 5) == 2)
    }

    @Test func rejectsInvalidRangesWithoutOverflow() {
        let value = AccessibilityText("😀\nZ")
        #expect(value.line(for: -1) == NSNotFound)
        #expect(value.line(for: 5) == NSNotFound)
        #expect(value.substring(in: NSRange(location: -1, length: 1)) == nil)
        #expect(value.substring(in: NSRange(location: 1, length: 1)) == nil)
        #expect(value.substring(in: NSRange(location: 3, length: Int.max)) == nil)
        #expect(value.substring(in: NSRange(location: NSNotFound, length: 0)) == nil)
        #expect(value.substring(in: NSRange(location: 4, length: 0)) == "")
    }

    @MainActor @Test func cacheRefreshesAtDeadlineWithoutScheduledTasks() {
        var instant = ContinuousClock.now
        var reads = 0
        let cache = CachedValue(duration: .milliseconds(500), now: { instant }, fetch: {
            reads += 1
            return reads
        })
        #expect(cache.get() == 1)
        instant += .milliseconds(499)
        #expect(cache.get() == 1)
        instant += .milliseconds(1)
        #expect(cache.get() == 2)
        #expect(reads == 2)
    }
}
