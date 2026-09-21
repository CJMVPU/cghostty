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
        return cachedScreenContents.get()
    }

    /// Returns the range of text that is currently selected in the terminal.
    /// This allows VoiceOver and other assistive technologies to understand
    /// what text the user has selected.
    override func accessibilitySelectedTextRange() -> NSRange {
        return selectedRange()
    }

    /// Returns the currently selected text as a string.
    /// This allows assistive technologies to read the selected content.
    override func accessibilitySelectedText() -> String? {
        guard let surface = self.surfaceModel else { return nil }

        // Attempt to read the selection
        guard let text = surface.selection else { return nil }

        let str = text.text
        return str.isEmpty ? nil : str
    }

    /// Returns the number of characters in the terminal content.
    /// This helps assistive technologies understand the size of the content.
    override func accessibilityNumberOfCharacters() -> Int {
        let content = cachedScreenContents.get()
        return content.count
    }

    /// Returns the visible character range for the terminal.
    /// For terminals, we typically show all content as visible.
    override func accessibilityVisibleCharacterRange() -> NSRange {
        let content = cachedScreenContents.get()
        return NSRange(location: 0, length: content.count)
    }

    /// Returns the line number for a given character index.
    /// This helps assistive technologies navigate by line.
    override func accessibilityLine(for index: Int) -> Int {
        let content = cachedScreenContents.get()
        let substring = String(content.prefix(index))
        return substring.components(separatedBy: .newlines).count - 1
    }

    /// Returns a substring for the given range.
    /// This allows assistive technologies to read specific portions of the content.
    override func accessibilityString(for range: NSRange) -> String? {
        let content = cachedScreenContents.get()
        guard let swiftRange = Range(range, in: content) else { return nil }
        return String(content[swiftRange])
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

/// Caches a value for some period of time, evicting it automatically when that time expires.
/// We use this to cache our surface content. This probably should be extracted some day
/// to a more generic helper.
class CachedValue<T> {
    private let lock = NSLock()
    private var value: T?
    private let fetch: () -> T
    private let duration: Duration
    private var expiryTask: Task<Void, Never>?

    init(duration: Duration, fetch: @escaping () -> T) {
        self.duration = duration
        self.fetch = fetch
    }

    isolated deinit {
        lock.lock()
        expiryTask?.cancel()
        lock.unlock()
    }

    func get() -> T {
        lock.lock()
        defer { lock.unlock() }

        if let value {
            return value
        }

        // We don't have a value (or it expired). Fetch and store.
        let result = fetch()
        let now = ContinuousClock.now
        let expires = now + duration
        self.value = result

        // Schedule a task to clear the value
        expiryTask = Task { [weak self] in
            do {
                try await Task.sleep(until: expires)
                self?.expire()
            } catch {
                // Task was cancelled, do nothing
            }
        }

        return result
    }

    private func expire() {
        lock.lock()
        defer { lock.unlock() }

        value = nil
        expiryTask = nil
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
