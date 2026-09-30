import Foundation

/// NSTextInputClient offsets address one immutable document in UTF-16 units.
/// Terminal cell positions and pixel geometry are separate coordinate systems.
struct InputText {
    let selectedRange: NSRange
    private let text: NSString

    init(_ value: String, selectedRanges: [NSRange]) {
        let document = value as NSString
        text = document
        // AppKit has one selection; a rectangular selection exposes its first
        // contiguous span. Accessibility continues to expose every span.
        selectedRange = selectedRanges.first.flatMap { range in
            range.location >= 0 && range.location < NSNotFound && range.length >= 0 &&
                range.location <= document.length && range.length <= document.length - range.location ? range : nil
        } ?? NSRange(location: NSNotFound, length: 0)
    }

    /// A caret offset belongs to marked text, never document history. Unknown
    /// AppKit ranges must keep the IME/dictation indicator at the cursor.
    static func compositionOffset(for range: NSRange, markedLength: Int) -> Int? {
        guard range.length == 0, range.location >= 0, range.location != NSNotFound,
              range.location <= markedLength else { return nil }
        return range.location
    }

    struct Substring {
        let text: String
        let range: NSRange
    }

    func substring(proposed range: NSRange) -> Substring? {
        guard range.length > 0 else { return nil }
        let requested: NSRange
        if range.location >= 0 && range.location < text.length {
            requested = NSRange(location: range.location, length: min(range.length, text.length - range.location))
        } else {
            // QuickLook occasionally asks for a range outside the document.
            // Preserve selection fallback, reporting the range actually read.
            requested = selectedRange
        }
        guard requested.location != NSNotFound, requested.length > 0 else { return nil }
        // Avoid returning half a surrogate or grapheme. Report any expansion.
        let actual = text.rangeOfComposedCharacterSequences(for: requested)
        return Substring(text: text.substring(with: actual), range: actual)
    }
}
