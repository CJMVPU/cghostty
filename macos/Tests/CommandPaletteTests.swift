//
//  CommandPaletteTests.swift
//  GhosttyTests
//
//  Tests for command palette query filtering and match ranking.
//

import Testing
import SwiftUI
@testable import Ghostty

struct CommandPaletteFilterTests {
    private func option(
        title: String,
        subtitle: String? = nil,
        description: String? = nil,
        leadingColor: Color? = nil,
        sortKey: ObjectIdentifier? = nil
    ) -> CommandOption {
        CommandOption(
            title: title,
            subtitle: subtitle,
            description: description,
            leadingColor: leadingColor,
            sortKey: sortKey
        ) {}
    }

    /// Title matches outrank subtitle matches, which outrank description
    /// matches. Options that don't match at all are dropped.
    @Test func textMatchTiers() {
        let byDescription = option(title: "Alpha", description: "make it fast")
        let bySubtitle = option(title: "Beta", subtitle: "fast scrolling")
        let byTitle = option(title: "Fast Redraw")
        let noMatch = option(title: "Quit")

        let results = [noMatch, byDescription, bySubtitle, byTitle]
            .filteredAndSorted(query: "fast")

        #expect(results == [byTitle, bySubtitle, byDescription])
    }

    /// Options with equal scores keep their original relative order.
    @Test func tiesPreserveOriginalOrder() {
        let first = option(title: "New Window")
        let second = option(title: "New Tab")

        #expect([first, second].filteredAndSorted(query: "new") == [first, second])
        #expect([second, first].filteredAndSorted(query: "new") == [second, first])
    }

    /// Equal titles use their sort keys independent of input order.
    @Test func equalTitlesUseSortKey() {
        let firstKey = NSObject()
        let secondKey = NSObject()
        let first = option(
            title: "Focus: Shell",
            subtitle: "/tmp",
            sortKey: ObjectIdentifier(firstKey)
        )
        let second = option(
            title: "Focus: Shell",
            subtitle: "/tmp",
            sortKey: ObjectIdentifier(secondKey)
        )

        let forward = sortedTerminalPaletteOptions([first, second])
        let reverse = sortedTerminalPaletteOptions([second, first])
        #expect(forward == reverse)
    }
}

struct CommandPaletteReuseTests {
    @Test func stableIdentityFreshCallbacksAndChangedText() throws {
        let cache = CommandPaletteSearch()
        var calls = 0
        func make(_ title: String, increment: Int) -> CommandOption {
            CommandOption(id: .command("new_window", 0), title: title) { calls += increment }
        }
        let first = make("New Window 中文🙂", increment: 1)
        let second = make("New Window 中文🙂", increment: 10)
        #expect(first.id == second.id)
        _ = cache.matches(options: [first], query: "中文")
        let matches = cache.matches(options: [second], query: "中文")
        #expect(cache.rebuilds == 1)
        let match = try #require(matches.first)
        let indices = try #require(match.titleIndices)
        #expect(String(indices.map { match.option.title[$0] }) == "中文")
        match.option.action()
        #expect(calls == 10)
        #expect(cache.matches(options: [make("Renamed", increment: 100)], query: "中文").isEmpty)
        #expect(cache.rebuilds == 2)
        #expect(cache.matches(options: [second], query: "").count == 1)
        #expect(cache.matches(options: [], query: "").isEmpty)
    }

    @Test func equivalentUnicodeSpellingsInvalidateStoredIndices() throws {
        let cache = CommandPaletteSearch()
        let first = CommandOption(id: .command("copy", 0), title: "e\u{301} 中文") {}
        let second = CommandOption(id: .command("copy", 0), title: "é 中文") {}
        _ = cache.matches(options: [first], query: "中文")
        let match = try #require(cache.matches(options: [second], query: "中文").first)
        #expect(cache.rebuilds == 2)
        let indices = try #require(match.titleIndices)
        #expect(String(indices.map { match.option.title[$0] }) == "中文")
    }

    @Test func duplicateCommandsAndSurfaceRenameKeepDistinctIdentity() {
        let id = UUID()
        let a = CommandOption(id: .surface(id), title: "before") {}
        let b = CommandOption(id: .surface(id), title: "after") {}
        #expect(a.id == b.id)
        let first = CommandOption(id: .command("new_tab", 0), title: "Tab") {}
        let second = CommandOption(id: .command("new_tab", 1), title: "Tab") {}
        #expect(first.id != second.id)
    }

    @Test func sortingMeasurementPreservesBaselineOrder() {
        let options = (0..<170).map {
            CommandOption(title: "\(["Focus", "Terminal", "Window", "Split"][$0 % 4]): \(($0 * 73) % 170) 中文 workspace") {}
        }
        func baseline(_ values: [CommandOption]) -> [CommandOption] {
            values.sorted {
                $0.title.replacingOccurrences(of: ":", with: "\t")
                    .localizedCaseInsensitiveCompare($1.title.replacingOccurrences(of: ":", with: "\t")) == .orderedAscending
            }
        }
        let expected = baseline(options)
        #expect(sortedTerminalPaletteOptions(options) == expected)
        let clock = ContinuousClock()
        for run in 1...5 {
            let before = clock.measure { for _ in 0..<50 { #expect(baseline(options) == expected) } }
            let after = clock.measure { for _ in 0..<50 { #expect(sortedTerminalPaletteOptions(options) == expected) } }
            print("Palette sorting benchmark run=\(run), 50x170: baseline=\(before), cached_keys=\(after)")
        }
    }
}
