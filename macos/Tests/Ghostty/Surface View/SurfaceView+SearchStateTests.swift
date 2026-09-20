import AppKit
import GhosttyKit
import Testing
@testable import Ghostty

@MainActor struct SurfaceView_SearchStateTests {
    typealias SearchState = Ghostty.SearchState
    typealias StartSearch = Ghostty.Action.StartSearch

    /// A unique pasteboard for each test case prevents flakiness.
    let pasteboard = NSPasteboard.withUniqueName()

    init() {
        pasteboard.setString("pb", forType: .string)
    }

    @Test func init_withNilNeedle_readsPasteboardNeedle() {
        let sut = SearchState(
            from: StartSearch(c: .init(needle: nil)),
            pasteboard: pasteboard
        )
        #expect(sut.needle.text == "pb")
    }

    @Test func init_withEmptyNeedle_readsPasteboardNeedle() {
        "".withCString { needle in
            let sut = SearchState(
                from: StartSearch(c: .init(needle: needle)),
                pasteboard: pasteboard
            )
            #expect(sut.needle.text == "pb")
        }
    }

    @Test func init_withNeedle_setsNeedle() {
        "start".withCString { needle in
            let sut = SearchState(
                from: StartSearch(c: .init(needle: needle)),
                pasteboard: pasteboard
            )
            #expect(sut.needle.text == "start")
        }
    }

    @Test func init_withNeedle_writesPasteboard() {
        "start".withCString { needle in
            _ = SearchState(
                from: StartSearch(c: .init(needle: needle)),
                pasteboard: pasteboard
            )
            #expect(pasteboard.string(forType: .string) == "start")
        }
    }

    @Test func writePasteboardNeedle_writesPasteboard() {
        let sut = SearchState(
            from: StartSearch(c: .init(needle: nil)),
            pasteboard: pasteboard
        )
        sut.setNeedle("sut")
        sut.writePasteboardNeedle()
        #expect(pasteboard.string(forType: .string) == "sut")
    }

    @Test func setNeedle_clearsNeedleSelection() {
        let sut = SearchState(
            from: StartSearch(c: .init(needle: nil)),
            pasteboard: pasteboard
        )
        sut.needle.selection = sut.needle.text.startIndex..<sut.needle.text.endIndex

        sut.setNeedle("x")

        #expect(sut.needle.text == "x")
        #expect(sut.needle.selection == nil)
    }

    @Test func readPasteboardNeedle_whenPasteboardNeedleIsNil() {
        let sut = SearchState(
            from: StartSearch(c: .init(needle: nil)),
            pasteboard: pasteboard
        )
        pasteboard.clearContents()
        sut.setNeedle("sut")
        sut.readPasteboardNeedle()
        #expect(sut.needle.text == "sut")
    }

    @Test func readPasteboardNeedle_whenPasteboardNeedleIsValid() {
        let sut = SearchState(
            from: StartSearch(c: .init(needle: nil)),
            pasteboard: pasteboard
        )
        sut.setNeedle("sut")
        sut.readPasteboardNeedle()
        #expect(sut.needle.text == "pb")
    }

    @Test func readPasteboardNeedle_setsNeedleSelectionRange() {
        let sut = SearchState(
            from: StartSearch(c: .init(needle: nil)),
            pasteboard: pasteboard
        )
        sut.setNeedle("sut")
        sut.readPasteboardNeedle()

        let expected = "pb".startIndex..<"pb".endIndex
        #expect(sut.needle.selection == expected)
    }
}

extension SurfaceView_SearchStateTests {
    @Test func selectionChangesDoNotRepeatSearch() {
        let state = SearchState(from: StartSearch(c: .init(needle: nil)), pasteboard: pasteboard)
        state.setNeedle("terminal")
        var calls: [String] = []
        state.startSearching { calls.append($0) }
        state.needle.selection = state.needle.text.startIndex..<state.needle.text.endIndex
        #expect(calls == ["terminal"])
        state.setNeedle("")
        #expect(calls == ["terminal", ""])
        state.stopSearching()
        state.setNeedle("ignored")
        #expect(calls == ["terminal", ""])
    }

    @Test func replacingSearchCancelsDelayedNeedle() async throws {
        let state = SearchState(from: StartSearch(c: .init(needle: nil)), pasteboard: pasteboard)
        var calls: [String] = []
        state.setNeedle("a")
        state.startSearching { calls.append($0) }
        state.setNeedle("complete")
        #expect(calls == ["complete"])
        // Exercise the real debounce deadline: the obsolete short query must
        // never fire after the newer immediate query.
        try await Task.sleep(for: .milliseconds(350))
        #expect(calls == ["complete"])
        state.setNeedle("b")
        state.stopSearching()
        try await Task.sleep(for: .milliseconds(350))
        #expect(calls == ["complete"])
    }

    @Test func delayedSearchDoesNotRetainModel() async throws {
        var state: SearchState? = SearchState(from: StartSearch(c: .init(needle: nil)), pasteboard: pasteboard)
        weak let weakState = state
        var calls: [String] = []
        state?.setNeedle("a")
        state?.startSearching { calls.append($0) }
        state = nil
        #expect(weakState == nil)
        try await Task.sleep(for: .milliseconds(350))
        #expect(calls.isEmpty)
    }
}
