import AppKit
import Observation
import SwiftUI
import Synchronization
import Testing
@testable import Ghostty

@MainActor struct PresentationStateTests {
    private var isolatedSurfaceConfiguration: Ghostty.SurfaceConfiguration {
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/zsh -f"
        config.workingDirectory = FileManager.default.temporaryDirectory.path
        return config
    }

    @Test func queuedFocusCannotOverrideNewSurfaceChoice() async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let first = Ghostty.SurfaceView(app, baseConfig: isolatedSurfaceConfiguration)
        let second = Ghostty.SurfaceView(app, baseConfig: isolatedSurfaceConfiguration)
        let tree = try SplitTree(view: first).inserting(view: second, at: first, direction: .right)
        let controller = BaseTerminalController(app, surfaceTree: tree)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        controller.window = window
        window.delegate = controller
        defer { window.close() }
        window.contentView?.addSubview(first)
        window.contentView?.addSubview(second)
        controller.requestFocus(to: first)
        #expect(window.makeFirstResponder(second))
        await drainMainQueue()
        #expect(window.firstResponder === second)
        controller.requestFocus(to: first)
        controller.requestFocus(to: second)
        await drainMainQueue()
        #expect(window.firstResponder === second)
    }

    @Test func queuedFocusCannotOverrideNewTextEditOrClosedWindow() async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let view = Ghostty.SurfaceView(app, baseConfig: isolatedSurfaceConfiguration)
        let controller = BaseTerminalController(app, surfaceTree: .init(view: view))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        controller.window = window
        window.delegate = controller
        defer { window.close() }
        let editor = NSTextView(frame: .zero)
        window.contentView?.addSubview(view)
        window.contentView?.addSubview(editor)
        controller.requestFocus(to: view)
        #expect(window.makeFirstResponder(editor))
        await drainMainQueue()
        #expect(window.firstResponder === editor)
        controller.requestFocus(to: view)
        controller.windowWillClose(.init(name: NSWindow.willCloseNotification, object: window))
        await drainMainQueue()
        #expect(window.firstResponder !== view)
    }

    @Test func quickTerminalIgnoresInterruptedHideCompletion() async throws {
        let config = try TemporaryConfig("quick-terminal-animation-duration = 0\nquick-terminal-autohide = false")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let controller = QuickTerminalController(app, baseConfig: isolatedSurfaceConfiguration)
        let window = try #require(controller.window)
        defer { controller.animateOut(); window.close() }
        controller.animateIn()
        await drainMainQueue()
        controller.animateOut()
        controller.animateIn()
        // Zero-duration animation completions still enqueue AppKit callbacks.
        await drainMainQueue()
        await drainMainQueue()
        #expect(controller.visible)
        #expect(window.isVisible)
        controller.animateOut()
        controller.animateIn()
        controller.animateOut()
        await drainMainQueue()
        await drainMainQueue()
        #expect(!controller.visible)
        #expect(!window.isVisible)
    }

    @Test func restoredFocusWaitsForAttachmentAndCompletesOnce() async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let view = Ghostty.SurfaceView(app, baseConfig: isolatedSurfaceConfiguration)
        let controller = BaseTerminalController(app, surfaceTree: .init(view: view))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        controller.window = window
        window.delegate = controller
        defer { window.close() }
        controller.restoreFocus(to: view)
        await drainMainQueue()
        #expect(window.firstResponder !== view)
        window.contentView?.addSubview(view)
        controller.focusedSurface = nil // SwiftUI's initial focus assignment can race attachment.
        await drainMainQueue()
        #expect(window.firstResponder === view)
        #expect(controller.focusedSurface === view)
        window.makeFirstResponder(window)
        controller.surfaceDidAttach(view)
        await drainMainQueue()
        #expect(window.firstResponder === window)
    }

    @Test func removedSurfaceCannotCompletePendingRestoration() async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let view = Ghostty.SurfaceView(app, baseConfig: isolatedSurfaceConfiguration)
        let controller = BaseTerminalController(app, surfaceTree: .init(view: view))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        controller.window = window
        defer { window.close() }
        controller.restoreFocus(to: view)
        controller.surfaceTree = .init()
        window.contentView?.addSubview(view)
        controller.surfaceDidAttach(view)
        await drainMainQueue()
        #expect(window.firstResponder !== view)
    }

    @Test func surfacePresentationTracksOnlyReadProperties() throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let surface = Ghostty.SurfaceView(app, baseConfig: isolatedSurfaceConfiguration)
        let changes = Mutex(0)
        withObservationTracking {
            _ = surface.state.pwd
        } onChange: {
            changes.withLock { $0 += 1 }
        }
        surface.state.bell = true
        #expect(changes.withLock { $0 } == 0)
        surface.pwd = "/tmp/observation"
        #expect(changes.withLock { $0 } == 1)
        #expect(surface.state.pwd == surface.pwd)
        withExtendedLifetime(app) {}
    }

    @Test func surfaceHandleKeepsCoreAppAliveUntilItIsFreed() async throws {
        var app: Ghostty.App? = Ghostty.App(configPath: "/dev/null")
        weak let weakApp = app
        var view: Ghostty.SurfaceView? = Ghostty.SurfaceView(
            try #require(app), baseConfig: isolatedSurfaceConfiguration)
        #expect(view?.surfaceModel != nil)
        weak let weakView = view
        app = nil
        await drainMainQueue()
        #expect(weakApp != nil)
        // The view owns its handle; releasing both must also release the app.
        view = nil
        await drainMainQueue()
        #expect(weakView == nil)
        #expect(weakApp == nil)
    }

    @Test func windowStatePreservesSurfaceAndCoreIdentity() throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let surface = Ghostty.SurfaceView(app, baseConfig: isolatedSurfaceConfiguration)
        let core = surface.surfaceModel
        let controller = BaseTerminalController(app, surfaceTree: .init(view: surface))
        let view = NSHostingView(rootView: TerminalView(ghostty: app, viewModel: controller.uiState))
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        view.layoutSubtreeIfNeeded()
        controller.commandPaletteIsShowing = true
        controller.commandPaletteIsShowing = false
        view.rootView = TerminalView(ghostty: app, viewModel: controller.uiState)
        view.layoutSubtreeIfNeeded()
        #expect(controller.uiState.surfaceTree.first === surface)
        #expect(surface.surfaceModel === core)
        #expect(surface.windowRegistry.owner(of: surface) === controller)
        withExtendedLifetime(app) {}
    }

    @Test func terminalFieldEditorCommitsLiteralTextAcrossFields() throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let controller = BaseTerminalController(app, surfaceTree: .init())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        controller.window = window
        window.delegate = controller
        defer { window.close() }
        let first = NSTextField(frame: NSRect(x: 0, y: 50, width: 250, height: 24))
        let second = NSTextField(frame: NSRect(x: 0, y: 10, width: 250, height: 24))
        window.contentView?.addSubview(first)
        window.contentView?.addSubview(second)
        #expect(window.makeFirstResponder(first))
        let editor = try #require(first.currentEditor() as? NSTextView)
        let literal = "\"teh\" -- https://example.com"
        editor.insertText(literal, replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.enabledTextCheckingTypes == 0)
        #expect(window.makeFirstResponder(second))
        #expect(first.stringValue == literal)
        #expect(second.currentEditor() === editor)
        editor.insertText(literal, replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.enabledTextCheckingTypes == 0)
        #expect(window.makeFirstResponder(nil))
        #expect(second.stringValue == literal)
        withExtendedLifetime(controller) {}
    }

    @Test func observationTasksDoNotRetainWindowController() async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let surface = Ghostty.SurfaceView(app, baseConfig: isolatedSurfaceConfiguration)
        var controller: BaseTerminalController? = BaseTerminalController(app, surfaceTree: .init(view: surface))
        weak let weakController = controller
        controller?.focusedSurfaceDidChange(to: surface)
        await drainMainQueue()
        controller = nil
        await drainMainQueue()
        #expect(weakController == nil)
        #expect(app.windowRegistry.owner(of: surface) == nil)
        withExtendedLifetime(app) {}
    }

    @Test func loadedTerminalControllerLivesUntilWindowCloses() async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let surface = Ghostty.SurfaceView(app, baseConfig: isolatedSurfaceConfiguration)
        var controller: TerminalController? = TerminalController(app, withSurfaceTree: .init(view: surface))
        weak let weakController = controller
        let window = try #require(controller?.window)
        controller = nil
        await drainMainQueue()
        #expect(weakController != nil)
        #expect(window.windowController === weakController)
        window.close()
        await drainMainQueue()
        await drainMainQueue()
        #expect(weakController == nil)
        withExtendedLifetime(app) {}
    }

    @Test func clipboardReplacementAndCancellationCompleteEachRequestOnce() async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let surface = Ghostty.SurfaceView(app, baseConfig: isolatedSurfaceConfiguration)
        var results: [String] = []
        let first = Ghostty.ClipboardConfirmationRequest(surface: surface, contents: "first", kind: .osc_52_read) { _, confirmed, _ in
            results.append(confirmed ? "first allowed" : "first denied")
        }
        let second = Ghostty.ClipboardConfirmationRequest(surface: surface, contents: "second", kind: .osc_52_read) { _, confirmed, _ in
            results.append(confirmed ? "second allowed" : "second denied")
        }
        surface.pendingClipboardConfirmation = first
        surface.pendingClipboardConfirmation = second
        #expect(results == ["first denied"])
        surface.pendingClipboardConfirmation = nil
        first.cancel()
        second.cancel()
        await drainMainQueue()
        #expect(results == ["first denied", "second denied"])
        withExtendedLifetime(app) {}
    }

    @Test func configurationErrorsDoNotLoadWindowWhenEmpty() {
        let app = Ghostty.App(configPath: "/dev/null")
        let controller = ConfigurationErrorsController(app: app)
        controller.updateErrors([])
        #expect(!controller.isWindowLoaded)
        controller.updateErrors(["Invalid test setting"])
        let window = controller.window
        #expect(window?.contentView is NSHostingView<ConfigurationErrorsView>)
        #expect(window?.title == "Configuration Errors")
        controller.updateErrors([])
        #expect(window?.isVisible == false)
    }

    @Test func focusedSurfaceTitleChangesReachNativeWindow() async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let first = Ghostty.SurfaceView(app, baseConfig: isolatedSurfaceConfiguration)
        let second = Ghostty.SurfaceView(app, baseConfig: isolatedSurfaceConfiguration)
        let controller = BaseTerminalController(app, surfaceTree: .init(view: first))
        controller.window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        controller.focusedSurfaceDidChange(to: first)
        first.state.title = "First terminal"
        await drainMainQueue()
        await drainMainQueue()
        #expect(controller.window?.title == "First terminal")

        controller.surfaceTree = .init(view: second)
        controller.focusedSurfaceDidChange(to: second)
        first.state.title = "Inactive terminal"
        second.state.title = "Second terminal"
        await drainMainQueue()
        await drainMainQueue()
        #expect(controller.window?.title == "Second terminal")
        withExtendedLifetime(app) {}
    }

    @Test func clipboardWindowHostsAndReplacesSwiftUIContent() throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let surface = Ghostty.SurfaceView(app, baseConfig: isolatedSurfaceConfiguration)
        let delegate = BaseTerminalController(app, surfaceTree: .init(view: surface))
        let first = Ghostty.ClipboardConfirmationRequest(surface: surface, contents: "first", kind: .paste) { _, _, _ in }
        let controller = ClipboardConfirmationController(confirmation: first, delegate: delegate)
        let window = try #require(controller.window)
        #expect(window.title == "Warning: Potentially Unsafe Paste")
        #expect((window.contentView as? NSHostingView<ClipboardConfirmationView>)?.rootView.contents == "first")
        let second = Ghostty.ClipboardConfirmationRequest(surface: surface, contents: "second", kind: .osc_52_read) { _, _, _ in }
        controller.replaceConfirmation(with: second)
        #expect(controller.window === window)
        #expect(window.title == "Authorize Clipboard Access")
        #expect((window.contentView as? NSHostingView<ClipboardConfirmationView>)?.rootView.contents == "second")
        controller.close()
        withExtendedLifetime(app) {}
    }

    @Test func aboutWindowHostsSwiftUIContent() {
        let controller = AboutController()
        #expect(controller.window?.contentView is NSHostingView<AboutView>)
        controller.close()
    }

    @Test func coreCommandsReachOnlyTheOwningWindow() async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let core = app
        let first = Ghostty.SurfaceView(core, baseConfig: isolatedSurfaceConfiguration)
        let second = Ghostty.SurfaceView(core, baseConfig: isolatedSurfaceConfiguration)
        let owner = CommandWindowController(app, surfaceTree: .init(view: first))
        let other = CommandWindowController(app, surfaceTree: .init(view: second))
        #expect(first.window == nil)
        #expect(try binding("close_window", on: first))
        #expect(owner.closeRequests == 1)
        #expect(other.closeRequests == 0)
        #expect(try binding("toggle_command_palette", on: first))
        #expect(owner.commandPaletteIsShowing)
        #expect(!other.commandPaletteIsShowing)
        await drainMainQueue()
        withExtendedLifetime(app) {}
    }

    @Test func splitCommandsWorkWhileSurfaceIsDetached() async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let surface = Ghostty.SurfaceView(app, baseConfig: isolatedSurfaceConfiguration)
        let controller = CommandWindowController(app, surfaceTree: .init(view: surface))
        #expect(try binding("new_split:right", on: surface))
        #expect(controller.surfaceTree.isSplit)
        let sibling = try #require(controller.surfaceTree.first(where: { $0 !== surface }))
        #expect(sibling.windowRegistry.owner(of: sibling) === controller)
        #expect(try binding("toggle_split_zoom", on: surface))
        #expect(controller.surfaceTree.zoomed == controller.surfaceTree.root?.node(view: surface))
        #expect(try binding("goto_split:right", on: surface))
        #expect(controller.surfaceTree.zoomed == nil)
        #expect(try binding("equalize_splits", on: surface))
        if case .split(let split) = controller.surfaceTree.root {
            #expect(split.ratio == 0.5)
        } else {
            Issue.record("Expected a split tree")
        }
        controller.closeSurface(sibling, withConfirmation: false)
        #expect(!controller.surfaceTree.isSplit)
        #expect(controller.surfaceTree.first === surface)
        #expect(sibling.windowRegistry.owner(of: sibling) == nil)
        await drainMainQueue()
        withExtendedLifetime(app) {}
    }

    @Test func commandsFollowSurfaceOwnershipAfterMovingBetweenWindows() async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let core = app
        let moving = Ghostty.SurfaceView(core, baseConfig: isolatedSurfaceConfiguration)
        let other = Ghostty.SurfaceView(core, baseConfig: isolatedSurfaceConfiguration)
        let source = CommandWindowController(app, surfaceTree: .init(view: moving))
        let destination = CommandWindowController(app, surfaceTree: .init(view: other))
        source.surfaceTree = .init()
        destination.surfaceTree = try destination.surfaceTree.inserting(view: moving, at: other, direction: .right)
        #expect(moving.windowRegistry.owner(of: moving) === destination)
        #expect(try binding("close_window", on: moving))
        #expect(source.closeRequests == 0)
        #expect(destination.closeRequests == 1)
        // A stale controller cannot mutate the moved surface.
        source.closeSurface(moving, withConfirmation: false)
        #expect(destination.surfaceTree.contains(moving))
        Ghostty.App.closeSurface(Unmanaged.passUnretained(try #require(moving.surfaceModel).callbackContext).toOpaque(), processAlive: false)
        #expect(!destination.surfaceTree.contains(moving))
        #expect(destination.surfaceTree.contains(other))
        await drainMainQueue()
        withExtendedLifetime(app) {}
    }

    @Test func registryKeepsDestinationWhenSourceDetachesLater() async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let moving = Ghostty.SurfaceView(app, baseConfig: isolatedSurfaceConfiguration)
        let source = CommandWindowController(app, surfaceTree: .init(view: moving))
        let destination = CommandWindowController(app, surfaceTree: .init(view: moving))
        #expect(app.windowRegistry.owner(of: moving) === destination)
        source.surfaceTree = .init()
        #expect(app.windowRegistry.owner(of: moving) === destination)
        #expect(try binding("close_window", on: moving))
        #expect(destination.closeRequests == 1)
        #expect(source.closeRequests == 0)
        // Restoring the tree must restore ownership, as close undo does.
        destination.surfaceTree = .init()
        #expect(app.windowRegistry.owner(of: moving) == nil)
        source.surfaceTree = .init(view: moving)
        #expect(app.windowRegistry.owner(of: moving) === source)
        await drainMainQueue()
    }

    @Test func registryIsScopedToTheCreatingApp() throws {
        let first = Ghostty.App(configPath: "/dev/null")
        let second = Ghostty.App(configPath: "/dev/null")
        let surface = Ghostty.SurfaceView(first, baseConfig: isolatedSurfaceConfiguration)
        let controller = CommandWindowController(first, surfaceTree: .init(view: surface))
        #expect(first.windowRegistry.owner(of: surface) === controller)
        #expect(second.windowRegistry.owner(of: surface) == nil)
    }

    @Test(arguments: ["中文:next", "line one\nline two", "prefix\0suffix"])
    func typedSearchBridgeClearsAndEndsSearch(query: String) throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let view = Ghostty.SurfaceView(app, baseConfig: isolatedSurfaceConfiguration)
        let surface = try #require(view.surfaceModel)
        #expect(!surface.navigateSearch(.next))
        #expect(surface.search(query))
        #expect(surface.navigateSearch(.next))
        #expect(surface.navigateSearch(.previous))
        #expect(surface.search(""))
        #expect(!surface.navigateSearch(.next))
        #expect(surface.search(query))
        #expect(surface.endSearch())
        #expect(!surface.endSearch())
    }

    @Test func surfaceConfigSnapshotDoesNotReplaceAppConfiguration() async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let view = Ghostty.SurfaceView(app, baseConfig: isolatedSurfaceConfiguration)
        let original = app.config.snapshot
        let local = try TemporaryConfig("window-title-font-family = Surface Font\nbackground-opacity = 0.43\nwindow-theme = light")
        let surface = try #require(view.surfaceModel)
        surface.updateConfig(local)
        await drainMainQueue()
        #expect(view.derivedConfig.windowTitleFontFamily == "Surface Font")
        #expect(view.derivedConfig.backgroundOpacity == 0.43)
        #expect(app.config.snapshot.window == original.window)
        #expect(app.config.snapshot.backgroundOpacity == original.backgroundOpacity)
        #expect(app.config.snapshot.windowTheme == original.windowTheme)
    }

    @Test func activeSearchReleasesWithSurfaceAfterReplacingLongQueries() async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        for round in 0..<3 {
            var view: Ghostty.SurfaceView? = Ghostty.SurfaceView(app, baseConfig: isolatedSurfaceConfiguration)
            var surface = view?.surfaceModel
            #expect(surface != nil)
            weak let weakView = view
            weak let weakSurface = surface
            let query = String(repeating: "搜索-\(round)", count: 128)
            for index in 0..<4 {
                #expect(surface?.search(query + String(index)) == true)
            }
            #expect(surface?.search("") == true)
            #expect(surface?.navigateSearch(.next) == false)
            #expect(surface?.search(query) == true)
            // Leave the worker running. Final core release must stop and join it.
            view = nil
            surface = nil
            await drainMainQueue()
            #expect(weakView == nil)
            #expect(weakSurface == nil)
        }
    }

    @Test func renderSessionReleasesAfterQueuedFontAndDisplayChanges() async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        for _ in 0..<3 {
            var view: Ghostty.SurfaceView? = Ghostty.SurfaceView(app, baseConfig: isolatedSurfaceConfiguration)
            var surface = view?.surfaceModel
            #expect(surface != nil)
            weak let weakView = view
            weak let weakSurface = surface
            for size in [640, 720, 800] {
                #expect(surface?.changeFontSize(by: 1) == true)
                surface?.setSize(width: UInt32(size), height: 480)
                surface?.setVisible(false)
                surface?.setVisible(true)
                surface?.setFocus(false)
                surface?.setFocus(true)
            }
            // Release while render messages can still be pending.
            view = nil
            surface = nil
            await drainMainQueue()
            #expect(weakView == nil)
            #expect(weakSurface == nil)
        }
    }

    private func binding(_ action: String, on surface: Ghostty.SurfaceView) throws -> Bool {
        let core = try #require(surface.surfaceModel)
        return core.perform(action: action)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

private class CommandWindowController: BaseTerminalController {
    // The test's short-lived core must not leave surfaces in the host app's undo stack.
    override var undoManager: ExpiringUndoManager? { nil }

    var closeRequests = 0

    override func closeWindow(_ sender: Any) {
        closeRequests += 1
    }
}
