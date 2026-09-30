@testable import Ghostty
import Foundation
import Testing

struct InputTextTests {
    @Test func documentRangesUseUTF16AndInclusiveSelections() {
        let value = InputText("old\n😀中e\u{301}Z", selectedRanges: [NSRange(location: 4, length: 5)])
        #expect(value.selectedRange == NSRange(location: 4, length: 5))
        let result = value.substring(proposed: NSRange(location: 4, length: 5))
        #expect(result?.text == "😀中e\u{301}")
        #expect(result?.range == value.selectedRange)
    }

    @Test func proposedRangesReportClippingAndGraphemeExpansion() {
        let value = InputText("A😀e\u{301}中", selectedRanges: [])
        #expect(value.substring(proposed: NSRange(location: 2, length: 1))?.range == NSRange(location: 1, length: 2))
        #expect(value.substring(proposed: NSRange(location: 3, length: 1))?.text == "e\u{301}")
        #expect(value.substring(proposed: NSRange(location: 5, length: Int.max))?.text == "中")
        #expect(value.substring(proposed: NSRange(location: 0, length: 1))?.text == "A")
        #expect(value.substring(proposed: NSRange(location: 0, length: 0)) == nil)
    }

    @Test func quickLookFallbackAndRectangleUseActualSelectionSpan() {
        let value = InputText("ab\ncd", selectedRanges: [NSRange(location: 1, length: 1), NSRange(location: 4, length: 1)])
        let result = value.substring(proposed: NSRange(location: NSNotFound, length: 1))
        #expect(result?.text == "b")
        #expect(result?.range == NSRange(location: 1, length: 1))
        let empty = InputText("", selectedRanges: [])
        #expect(empty.selectedRange.location == NSNotFound)
        #expect(empty.substring(proposed: NSRange(location: NSNotFound, length: 1)) == nil)
    }
    @Test func unknownAndDocumentRangesDoNotMoveTheCompositionAnchor() {
        #expect(InputText.compositionOffset(for: NSRange(location: NSNotFound, length: 0), markedLength: 0) == 0)
        #expect(InputText.compositionOffset(for: NSRange(location: 1000, length: 0), markedLength: 2) == 0)
        #expect(InputText.compositionOffset(for: NSRange(location: -1, length: 0), markedLength: 2) == 0)
        #expect(InputText.compositionOffset(for: NSRange(location: 1, length: 1), markedLength: 2) == 0)
        #expect(InputText.compositionOffset(for: NSRange(location: 2, length: 0), markedLength: 2) == 2)
    }

}
