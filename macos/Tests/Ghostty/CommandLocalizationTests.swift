import Foundation
import Testing
@testable import Ghostty

@MainActor struct CommandLocalizationTests {
    @Test(arguments: [("zh-Hans", "重置终端"), ("zh-Hant", "重設終端機"), ("ja", "ターミナルをリセット")])
    func bundledTranslationsAndLiteralFallbacks(_ example: (String, String)) throws {
        let path = try #require(Bundle.main.path(forResource: example.0, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        #expect(Ghostty.Command.localizedText("Reset Terminal", builtIn: true, bundle: bundle) == example.1)
        #expect(Ghostty.Command.localizedText("Reset Terminal", builtIn: false, bundle: bundle) == "Reset Terminal")
        #expect(Ghostty.Command.localizedText("User-defined prose", builtIn: true, bundle: bundle) == "User-defined prose")
    }

    @Test func builtInCommandIdentityIsNotLocalized() throws {
        let config = try TemporaryConfig("")
        #expect(config.errors.isEmpty)
        let command = try #require(config.snapshot.commandPaletteEntries.first { $0.action == "goto_split:right" })
        #expect(command.title == Ghostty.Command.localizedText("Focus Split: Right", builtIn: true))
        #expect(command.description == Ghostty.Command.localizedText(
            "Focus the split to the right, if it exists.", builtIn: true))
        #expect(command.action == "goto_split:right")
        #expect(command.actionKey == "goto_split")
    }

    @Test(arguments: ["clear", "", "title:Reset Terminal,description:Custom description,action:goto_split:right"])
    func customCommandConfigurationIsRejected(_ value: String) throws {
        let defaults = try TemporaryConfig("").snapshot.commandPaletteEntries
        let config = try TemporaryConfig("command-palette-entry = \(value)")
        #expect(config.errors.count == 1)
        #expect(config.errors.contains {
            $0.contains("command-palette-entry") && $0.contains("unknown field")
        })
        let commands = config.snapshot.commandPaletteEntries
        #expect(commands.map(\.title) == defaults.map(\.title))
        #expect(commands.map(\.description) == defaults.map(\.description))
        #expect(commands.map(\.action) == defaults.map(\.action))
        #expect(commands.map(\.actionKey) == defaults.map(\.actionKey))
    }
}
