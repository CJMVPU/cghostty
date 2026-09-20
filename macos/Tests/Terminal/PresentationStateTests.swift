import AppKit
import GhosttyKit
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

    @Test func surfacePresentationTracksOnlyReadProperties() throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let surface = Ghostty.SurfaceView(try #require(app.app), baseConfig: isolatedSurfaceConfiguration)
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
            try #require(app?.app), baseConfig: isolatedSurfaceConfiguration)
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
        let surface = Ghostty.SurfaceView(try #require(app.app), baseConfig: isolatedSurfaceConfiguration)
        let core = surface.surface
        let controller = BaseTerminalController(app, surfaceTree: .init(view: surface))
        let view = NSHostingView(rootView: TerminalView(ghostty: app, viewModel: controller.uiState))
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        view.layoutSubtreeIfNeeded()
        controller.commandPaletteIsShowing = true
        controller.commandPaletteIsShowing = false
        view.rootView = TerminalView(ghostty: app, viewModel: controller.uiState)
        view.layoutSubtreeIfNeeded()
        #expect(controller.uiState.surfaceTree.first === surface)
        #expect(surface.surface == core)
        #expect(BaseTerminalController.controller(owning: surface) === controller)
        withExtendedLifetime(app) {}
    }

    @Test func observationTasksDoNotRetainWindowController() async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let surface = Ghostty.SurfaceView(try #require(app.app), baseConfig: isolatedSurfaceConfiguration)
        var controller: BaseTerminalController? = BaseTerminalController(app, surfaceTree: .init(view: surface))
        weak let weakController = controller
        controller?.focusedSurfaceDidChange(to: surface)
        await drainMainQueue()
        controller = nil
        await drainMainQueue()
        #expect(weakController == nil)
        withExtendedLifetime(app) {}
    }

    @Test func loadedTerminalControllerLivesUntilWindowCloses() async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let surface = Ghostty.SurfaceView(try #require(app.app), baseConfig: isolatedSurfaceConfiguration)
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
        let surface = Ghostty.SurfaceView(try #require(app.app), baseConfig: isolatedSurfaceConfiguration)
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
        let controller = ConfigurationErrorsController()
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
        let first = Ghostty.SurfaceView(try #require(app.app), baseConfig: isolatedSurfaceConfiguration)
        let second = Ghostty.SurfaceView(try #require(app.app), baseConfig: isolatedSurfaceConfiguration)
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
        let surface = Ghostty.SurfaceView(try #require(app.app), baseConfig: isolatedSurfaceConfiguration)
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
        let core = try #require(app.app)
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
        let surface = Ghostty.SurfaceView(try #require(app.app), baseConfig: isolatedSurfaceConfiguration)
        let controller = CommandWindowController(app, surfaceTree: .init(view: surface))
        #expect(try binding("new_split:right", on: surface))
        #expect(controller.surfaceTree.isSplit)
        let sibling = try #require(controller.surfaceTree.first(where: { $0 !== surface }))
        #expect(BaseTerminalController.controller(owning: sibling) === controller)
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
        #expect(BaseTerminalController.controller(owning: sibling) == nil)
        await drainMainQueue()
        withExtendedLifetime(app) {}
    }

    @Test func commandsFollowSurfaceOwnershipAfterMovingBetweenWindows() async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let core = try #require(app.app)
        let moving = Ghostty.SurfaceView(core, baseConfig: isolatedSurfaceConfiguration)
        let other = Ghostty.SurfaceView(core, baseConfig: isolatedSurfaceConfiguration)
        let source = CommandWindowController(app, surfaceTree: .init(view: moving))
        let destination = CommandWindowController(app, surfaceTree: .init(view: other))
        source.surfaceTree = .init()
        destination.surfaceTree = try destination.surfaceTree.inserting(view: moving, at: other, direction: .right)
        #expect(BaseTerminalController.controller(owning: moving) === destination)
        #expect(try binding("close_window", on: moving))
        #expect(source.closeRequests == 0)
        #expect(destination.closeRequests == 1)
        // A stale controller cannot mutate the moved surface.
        source.closeSurface(moving, withConfirmation: false)
        #expect(destination.surfaceTree.contains(moving))
        Ghostty.App.closeSurface(Unmanaged.passUnretained(moving).toOpaque(), processAlive: false)
        #expect(!destination.surfaceTree.contains(moving))
        #expect(destination.surfaceTree.contains(other))
        await drainMainQueue()
        withExtendedLifetime(app) {}
    }

    private func binding(_ action: String, on surface: Ghostty.SurfaceView) throws -> Bool {
        let core = try #require(surface.surface)
        return ghostty_surface_binding_action(core, action, UInt(action.utf8.count))
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
