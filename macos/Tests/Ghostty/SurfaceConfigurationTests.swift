import AppKit
import GhosttyKit
import Testing
@testable import Ghostty

@Suite(.serialized)
@MainActor struct SurfaceConfigurationTests {
    @Test func inheritedValuesRemainOwnedAfterCoreRelease() throws {
        let app = Ghostty.App(configPath: "/dev/null")
        var base = Ghostty.SurfaceConfiguration()
        base.command = "/bin/cat"
        base.workingDirectory = FileManager.default.temporaryDirectory.path
        base.fontSize = 17
        let view = Ghostty.SurfaceView(app, baseConfig: base)
        let surface = try #require(view.surfaceModel)
        for context in [GHOSTTY_SURFACE_CONTEXT_WINDOW, GHOSTTY_SURFACE_CONTEXT_TAB, GHOSTTY_SURFACE_CONTEXT_SPLIT] {
            var raw = ghostty_surface_inherited_config(surface.unsafeCValue, context)
            let copied = Ghostty.SurfaceConfiguration(from: raw)
            ghostty_surface_inherited_config_free(surface.unsafeCValue, &raw)
            #expect(raw.working_directory == nil)
            // Releasing the emptied result again is harmless.
            ghostty_surface_inherited_config_free(surface.unsafeCValue, &raw)
            #expect(copied.workingDirectory == base.workingDirectory)
            #expect(copied.fontSize == 17)
            #expect(copied.context == context)
            #expect(copied.command == nil && copied.environmentVariables.isEmpty)

            // Exercise the production adapter's synchronous copy/defer path.
            let inherited = Ghostty.SurfaceConfiguration(inheriting: surface.unsafeCValue, context: context)
            #expect(inherited.workingDirectory == copied.workingDirectory)
            #expect(inherited.fontSize == copied.fontSize)
            #expect(inherited.context == copied.context)
        }
    }

    @Test func inheritedConfigurationRespectsDisabledValues() throws {
        let config = try TemporaryConfig("""
        window-inherit-font-size = false
        window-inherit-working-directory = false
        tab-inherit-working-directory = false
        split-inherit-working-directory = false
        """)
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        var base = Ghostty.SurfaceConfiguration()
        base.command = "/bin/cat"
        base.workingDirectory = FileManager.default.temporaryDirectory.path
        let view = Ghostty.SurfaceView(app, baseConfig: base)
        let surface = try #require(view.surfaceModel)
        for context in [GHOSTTY_SURFACE_CONTEXT_WINDOW, GHOSTTY_SURFACE_CONTEXT_TAB, GHOSTTY_SURFACE_CONTEXT_SPLIT] {
            let inherited = Ghostty.SurfaceConfiguration(inheriting: surface.unsafeCValue, context: context)
            #expect(inherited.workingDirectory == nil)
            #expect(inherited.fontSize == 0)
            #expect(inherited.context == context)
        }
    }
}
