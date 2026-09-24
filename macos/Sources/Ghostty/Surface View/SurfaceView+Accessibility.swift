import AppKit
import Foundation

// MARK: Accessibility

extension Ghostty.SurfaceView {
    /// Indicates that this view should be exposed to accessibility tools like VoiceOver.
    /// By returning true, we make the terminal surface accessible to screen readers
    /// and other assistive technologies.
    override func isAccessibilityElement() -> Bool {
         return true
     }

    /// Defines the accessibility role for this view, which helps assistive technologies
    /// understand what kind of content this view contains and how users can interact with it.
    override func accessibilityRole() -> NSAccessibility.Role? {
        /// We use .textArea because the terminal surface is essentially an editable text area
        /// where users can input commands and view output.
        return .textArea
    }

    override func accessibilityHelp() -> String? {
        return "Terminal content area"
    }

    override func accessibilityValue() -> Any? {
        return cachedScreenContents.get().text
    }

    /// Returns the range of text that is currently selected in the terminal.
    /// This allows VoiceOver and other assistive technologies to understand
    /// what text the user has selected.
    override func accessibilitySelectedTextRange() -> NSRange {
        return cachedScreenContents.get().selectedRanges.first ?? NSRange(location: NSNotFound, length: 0)
    }

    /// Returns the currently selected text as a string.
    /// This allows assistive technologies to read the selected content.
    override func accessibilitySelectedText() -> String? {
        let snapshot = cachedScreenContents.get()
        guard !snapshot.selectedRanges.isEmpty else { return nil }
        return snapshot.selectedRanges.compactMap { snapshot.substring(in: $0) }.joined(separator: "\n")
    }

    override func accessibilitySelectedTextRanges() -> [NSValue]? {
        cachedScreenContents.get().selectedRanges.map { NSValue(range: $0) }
    }

    /// Returns the number of characters in the terminal content.
    /// This helps assistive technologies understand the size of the content.
    override func accessibilityNumberOfCharacters() -> Int {
        let content = cachedScreenContents.get()
        return content.utf16Length
    }

    /// Returns the visible character range for the terminal.
    /// The range addresses the same immutable snapshot as accessibilityValue.
    override func accessibilityVisibleCharacterRange() -> NSRange {
        let content = cachedScreenContents.get()
        return content.visibleRange
    }

    /// Returns the line number for a given character index.
    /// This helps assistive technologies navigate by line.
    override func accessibilityLine(for index: Int) -> Int {
        let content = cachedScreenContents.get()
        return content.line(for: index)
    }

    /// Returns a substring for the given range.
    /// This allows assistive technologies to read specific portions of the content.
    override func accessibilityString(for range: NSRange) -> String? {
        let content = cachedScreenContents.get()
        return content.substring(in: range)
    }

    /// Returns an attributed string for the given range.
    ///
    /// Note: right now this only applies font information. One day it'd be nice to extend
    /// this to copy styling information as well but we need to augment Ghostty core to
    /// expose that.
    ///
    /// This provides styling information to assistive technologies.
    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        guard let surface = self.surfaceModel else { return nil }
        guard let plainString = accessibilityString(for: range) else { return nil }

        var attributes: [NSAttributedString.Key: Any] = [:]

        // Try to get the font from the surface
        if let font = surface.font {
            attributes[.font] = font
        }

        return NSAttributedString(string: plainString, attributes: attributes)
    }

}

/// One immutable text/index snapshot, using Cocoa's UTF-16 coordinate system.
/// Line offsets are built once per refresh instead of scanning the scrollback
/// for every accessibilityLine request.
struct AccessibilityText {
    let text: String
    let utf16Length: Int
    private let cocoaText: NSString
    private let lineStarts: [Int]
    let visibleRange: NSRange
    let selectedRanges: [NSRange]
    let revision: UInt64

    init(_ snapshot: Ghostty.Surface.AccessibilitySnapshot?) {
        self.init(snapshot?.text ?? "", visibleRange: snapshot?.visibleRange,
                  selectedRanges: snapshot?.selectedRanges ?? [], revision: snapshot?.revision ?? 0)
    }

    init(_ text: String, visibleRange: NSRange? = nil, selectedRanges: [NSRange] = [], revision: UInt64 = 0) {
        self.visibleRange = visibleRange ?? NSRange(location: 0, length: text.utf16.count)
        self.selectedRanges = selectedRanges
        self.revision = revision
        self.text = text
        cocoaText = text as NSString
        var starts = [0]
        var offset = 0
        var previousWasCR = false
        for unit in text.utf16 {
            offset += 1
            if unit == 0x0A && previousWasCR {
                starts[starts.count - 1] = offset
            } else if unit == 0x0A || unit == 0x0D || unit == 0x85 || unit == 0x2028 || unit == 0x2029 {
                starts.append(offset)
            }
            previousWasCR = unit == 0x0D
        }
        utf16Length = offset
        lineStarts = starts
    }

    func line(for index: Int) -> Int {
        guard index >= 0 && index <= utf16Length else { return NSNotFound }
        var low = 0
        var high = lineStarts.count
        while low < high {
            let middle = low + (high - low) / 2
            if lineStarts[middle] <= index {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low - 1
    }

    func substring(in range: NSRange) -> String? {
        guard range.location >= 0, range.length >= 0,
              range.location <= utf16Length,
              range.length <= utf16Length - range.location else { return nil }
        let end = range.location + range.length
        // Swift String slicing may expand a range inside a grapheme cluster.
        // Cocoa offsets must stay exact, without splitting a surrogate pair.
        for boundary in [range.location, end] where boundary < utf16Length {
            if UTF16.isTrailSurrogate(cocoaText.character(at: boundary)) { return nil }
        }
        return cocoaText.substring(with: range)
    }
}

/// Main-thread surface readers expire lazily. No task or timer is needed when
/// accessibility and App Intents are not asking for text.
@MainActor
class CachedValue<T> {
    private var value: T?
    private let fetch: (T?) -> T
    private let duration: Duration
    private let now: () -> ContinuousClock.Instant
    private var expires: ContinuousClock.Instant?

    init(
        duration: Duration,
        now: @escaping () -> ContinuousClock.Instant = { .now },
        fetch: @escaping () -> T
    ) {
        self.duration = duration
        self.now = now
        self.fetch = { _ in fetch() }
    }

    init(duration: Duration, refresh: @escaping (T?) -> T) {
        self.duration = duration
        self.now = { .now }
        self.fetch = refresh
    }

    func get() -> T {
        let instant = now()
        if let value, let expires, instant < expires { return value }
        let result = fetch(value)
        value = result
        expires = now() + duration
        return result
    }
}

/// Check if a UTF16 text is a single lead surrogate character
struct LeadSurrogate {
    let char: UTF16Char

    init?(_ text: NSString) {
        guard text.length == 1 else {
            return nil
        }
        let char = text.character(at: 0)
        if UTF16.isLeadSurrogate(char) {
            self.char = char
        } else {
            return nil
        }
    }

    func encode(trail: TrailSurrogate) -> String {
        String(decoding: [char, trail.char], as: UTF16.self)
    }
}

/// Check if a UTF16 text is a single trail surrogate character
struct TrailSurrogate {
    let char: UTF16Char

    init?(_ text: NSString) {
        guard text.length == 1 else {
            return nil
        }
        let char = text.character(at: 0)
        if UTF16.isTrailSurrogate(char) {
            self.char = char
        } else {
            return nil
        }
    }
}
