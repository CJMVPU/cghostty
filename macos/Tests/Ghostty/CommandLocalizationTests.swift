import Foundation
import Testing
@testable import Ghostty

@MainActor struct CommandLocalizationTests {
    @Test(arguments: [("zh-Hans", "重置终端"), ("zh-Hant", "重設終端機"), ("ja", "ターミナルをリセット")])
    func bundledTranslationsAndCustomTitles(_ example: (String, String)) throws {
        let path = try #require(Bundle.main.path(forResource: example.0, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        #expect(Ghostty.Command.localizedText("Reset Terminal", builtIn: true, bundle: bundle) == example.1)
        #expect(Ghostty.Command.localizedText("Reset Terminal", builtIn: false, bundle: bundle) == "Reset Terminal")
        #expect(Ghostty.Command.localizedText("User-defined prose", builtIn: true, bundle: bundle) == "User-defined prose")
    }

    @Test func customCommandIdentityAndProseStayLiteral() throws {
        let config = try TemporaryConfig("""
        command-palette-entry = clear
        command-palette-entry = title:Reset Terminal,description:Custom description,action:goto_split:right
        """)
        let command = try #require(config.snapshot.commandPaletteEntries.first)
        #expect(command.title == "Reset Terminal")
        #expect(command.description == "Custom description")
        #expect(command.action == "goto_split:right")
        #expect(command.actionKey == "goto_split")
    }
}
