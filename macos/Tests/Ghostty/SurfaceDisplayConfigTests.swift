import AppKit
import GhosttyKit
import SwiftUI
import Testing
@testable import Ghostty

@Suite(.serialized)
@MainActor struct SurfaceDisplayConfigTests {
    private func makeView(_ app: Ghostty.App) -> Ghostty.SurfaceView {
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/cat"
        config.workingDirectory = FileManager.default.temporaryDirectory.path
        return Ghostty.SurfaceView(app, baseConfig: config)
    }

    private func deliver(_ config: TemporaryConfig, to view: Ghostty.SurfaceView, app: Ghostty.App) throws {
        let surface = try #require(view.surfaceModel)
        Ghostty.App.configChange(
            try #require(app.app),
            target: .init(tag: GHOSTTY_TARGET_SURFACE, target: .init(surface: surface.unsafeCValue)),
            v: .init(config: config.config))
    }

    private func drainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test func surfaceCallbackCopiesDisplayValuesWithoutCloningCoreConfig() async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let view = makeView(app)
        let other = makeView(app)
        let appConfig = app.config
        let originalOther = other.derivedConfig
        var source: TemporaryConfig? = try TemporaryConfig("""
        background = #123456
        background-opacity = 0.4
        background-blur = 12
        macos-window-shadow = false
        window-title-font-family = 借用字体 Display Font
        window-theme = light
        scrollbar = never
        """)
        #expect(source?.errors.isEmpty == true)
        let clones = Ghostty.ConfigHandle.cloneCallsForTesting
        try deliver(try #require(source), to: view, app: app)
        #expect(Ghostty.ConfigHandle.cloneCallsForTesting == clones)
        // Publication stays deferred, but all borrowed values must already be owned.
        #expect(view.derivedConfig.windowTitleFontFamily == nil)
        try source?.reload("window-title-font-family = Replacement Font\nbackground = #ffffff")
        source = nil
        await drainQueue()

        #expect(view.derivedConfig.backgroundColor == Color(red: 0x12 / 255.0, green: 0x34 / 255.0, blue: 0x56 / 255.0))
        #expect(view.derivedConfig.backgroundOpacity == 0.4)
        #expect(view.derivedConfig.backgroundBlur == .radius(12))
        #expect(!view.derivedConfig.macosWindowShadow)
        #expect(view.derivedConfig.windowTitleFontFamily == "借用字体 Display Font")
        #expect(view.derivedConfig.windowAppearance?.name == .aqua)
        #expect(view.derivedConfig.scrollbar == .never)
        #expect(app.config === appConfig)
        #expect(other.derivedConfig.backgroundColor == originalOther.backgroundColor)
        #expect(other.derivedConfig.backgroundOpacity == originalOther.backgroundOpacity)
        #expect(other.derivedConfig.windowTitleFontFamily == originalOther.windowTitleFontFamily)
    }

    @Test(arguments: [
        "",
        "window-theme = light\nbackground = #000000",
        "window-theme = dark\nbackground = #ffffff",
        "window-theme = auto\nbackground = #ffffff",
        "window-theme = auto\nbackground = #000000",
    ])
    func surfaceDisplayMatchesFullSnapshot(_ settings: String) async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let view = makeView(app)
        let source = try TemporaryConfig(settings)
        #expect(source.errors.isEmpty)
        let expected = Ghostty.SurfaceView.DerivedConfig(source.snapshot)
        try deliver(source, to: view, app: app)
        await drainQueue()
        let actual = view.derivedConfig
        #expect(actual.backgroundColor == expected.backgroundColor)
        #expect(actual.backgroundOpacity == expected.backgroundOpacity)
        #expect(actual.backgroundBlur == expected.backgroundBlur)
        #expect(actual.macosWindowShadow == expected.macosWindowShadow)
        #expect(actual.windowTitleFontFamily == expected.windowTitleFontFamily)
        #expect(actual.windowAppearance?.name == expected.windowAppearance?.name)
        #expect(actual.scrollbar == expected.scrollbar)
    }

    @Test(arguments: [false, true])
    func surfaceDisplayPreservesOnlyMatchingOSC11Background(_ matching: Bool) async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let view = makeView(app)
        view.acceptColorChange(.init(c: .init(kind: GHOSTTY_ACTION_COLOR_KIND_BACKGROUND,
                                             r: 0x12, g: 0x34, b: 0x56)))
        await drainQueue()
        let cached = try #require(view.backgroundColor)
        let source = try TemporaryConfig("background = \(matching ? "#123456" : "#ffffff")")
        try deliver(source, to: view, app: app)
        await drainQueue()
        #expect(view.backgroundColor == (matching ? cached : nil))
    }

    @Test func unloadedDisplayPreservesFullSnapshotFallbacks() {
        let expected = Ghostty.SurfaceView.DerivedConfig(Ghostty.Config(handle: nil).snapshot)
        let actual = Ghostty.SurfaceView.DerivedConfig(borrowing: nil)
        #expect(actual.backgroundColor == expected.backgroundColor)
        #expect(actual.backgroundOpacity == expected.backgroundOpacity)
        #expect(actual.backgroundBlur == expected.backgroundBlur)
        #expect(actual.macosWindowShadow == expected.macosWindowShadow)
        #expect(actual.windowTitleFontFamily == expected.windowTitleFontFamily)
        #expect(actual.windowAppearance?.name == expected.windowAppearance?.name)
        #expect(actual.scrollbar == expected.scrollbar)
    }

    @Test func appCallbackStillOwnsCompleteConfigAndBindings() throws {
        let app = Ghostty.App(configPath: "/dev/null")
        var source: TemporaryConfig? = try TemporaryConfig("""
        title = App callback title
        keybind = clear
        keybind = cmd+k=new_window
        """)
        let borrowed = try #require(source?.config)
        let clones = Ghostty.ConfigHandle.cloneCallsForTesting
        Ghostty.App.configChange(
            try #require(app.app), target: .init(tag: GHOSTTY_TARGET_APP, target: .init()),
            v: .init(config: borrowed))
        #expect(Ghostty.ConfigHandle.cloneCallsForTesting == clones + 1)
        #expect(app.config.config != borrowed)
        source = nil
        #expect(app.config.snapshot.title == "App callback title")
        #expect(app.config.keyboardShortcut(for: "new_window") == .init("k", modifiers: .command))
    }
}
