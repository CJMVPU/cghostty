import AppKit
import Observation

extension Ghostty {
    @MainActor @Observable final class SearchState {

        /// We should always change needle's text and its selection together
        struct Needle: Equatable {
            var text: String
            var selection: Range<String.Index>?

            static let empty = Needle(text: "", selection: nil)
        }

        /// The pasteboard used to persist the search needle.
        ///
        /// The `.find` pasteboard lets us sync our needle across the system and other find bars.
        private let pasteboard: NSPasteboard

        var needle = Needle.empty {
            didSet {
                guard needle.text != oldValue.text else { return }
                scheduleSearch()
            }
        }

        @ObservationIgnored private var focusOwner: UUID?
        @ObservationIgnored private var focusAction: (() -> Void)?

        func attachFocusRequest(owner: UUID, action: @escaping () -> Void) {
            focusOwner = owner
            focusAction = action
        }

        func detachFocusRequest(owner: UUID) {
            guard focusOwner == owner else { return }
            focusOwner = nil
            focusAction = nil
        }

        func requestFocus() {
            focusAction?()
        }

        @ObservationIgnored private var searchTask: Task<Void, Never>?
        @ObservationIgnored private var searchAction: ((String) -> Void)?

        func startSearching(_ action: @escaping (String) -> Void) {
            stopSearching()
            searchAction = action
            scheduleSearch()
        }

        func stopSearching() {
            searchTask?.cancel()
            searchTask = nil
            searchAction = nil
        }

        private func scheduleSearch() {
            searchTask?.cancel()
            searchTask = nil
            guard let searchAction else { return }
            let text = needle.text
            if text.isEmpty || text.count >= 3 {
                searchAction(text)
            } else {
                searchTask = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                    guard !Task.isCancelled else { return }
                    self?.searchAction?(text)
                }
            }
        }

        isolated deinit {
            searchTask?.cancel()
        }

        var selected: UInt?
        var total: UInt?

        init(
            from startSearch: Ghostty.Action.StartSearch,
            pasteboard: NSPasteboard? = nil
        ) {
            self.pasteboard = pasteboard ?? .find
            if let needle = startSearch.needle, !needle.isEmpty {
                setNeedle(needle)
                writePasteboardNeedle()
            } else {
                readPasteboardNeedle()
            }
        }

        /// Replaces the search needle while keeping its selection valid.
        func setNeedle(_ needle: String, selectAll: Bool = false) {
            self.needle = .init(
                text: needle,
                selection: selectAll ? needle.startIndex..<needle.endIndex : nil
            )
        }

        func readPasteboardNeedle() {
            let pasteboardNeedle = pasteboard.string
            if let pasteboardNeedle, pasteboardNeedle != needle.text {
                setNeedle(pasteboardNeedle, selectAll: true)
            }
        }

        func writePasteboardNeedle() {
            pasteboard.string = needle.text
        }
    }

}
