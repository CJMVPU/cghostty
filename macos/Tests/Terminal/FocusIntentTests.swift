import AppKit
import Testing
@testable import Ghostty

@MainActor struct FocusIntentTests {
    enum Operation: CaseIterable {
        case navigation
        case zoom
        case treeReplacement

        func request(_ controller: BaseTerminalController, first: Ghostty.SurfaceView, second: Ghostty.SurfaceView) {
            switch self {
            case .navigation:
                controller.focusSplit(from: second, direction: .previous)
            case .zoom:
                controller.toggleSplitZoom(on: first)
            case .treeReplacement:
                controller.applySplitTree(controller.surfaceTree, focus: first, previousFocus: second, actionName: nil)
            }
        }
    }

    private func surface(_ app: Ghostty.App) -> Ghostty.SurfaceView {
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/cat"
        config.workingDirectory = FileManager.default.temporaryDirectory.path
        return Ghostty.SurfaceView(app, baseConfig: config)
    }

    @Test(arguments: Operation.allCases)
    func newerSurfaceChoiceSupersedesSplitFocusIntent(_ operation: Operation) async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let first = surface(app)
        let second = surface(app)
        let tree = try SplitTree(view: first).inserting(view: second, at: first, direction: .right)
        let controller = FocusIntentController(app, surfaceTree: tree)
        controller.focusedSurface = second

        operation.request(controller, first: first, second: second)
        // A native responder change arrives before queued layout work runs.
        controller.surfaceDidFocus(second)
        await drainFocusWork()

        #expect(controller.focusedSurface === second)
    }

    @Test(arguments: Operation.allCases)
    func newerTextEditSupersedesSplitFocusIntent(_ operation: Operation) async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let first = surface(app)
        let second = surface(app)
        let tree = try SplitTree(view: first).inserting(view: second, at: first, direction: .right)
        let controller = FocusIntentController(app, surfaceTree: tree)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        controller.window = window
        window.delegate = controller
        defer { window.close() }
        let editor = NSTextView(frame: .zero)
        window.contentView?.addSubview(first)
        window.contentView?.addSubview(second)
        window.contentView?.addSubview(editor)
        #expect(window.makeFirstResponder(second))

        operation.request(controller, first: first, second: second)
        #expect(window.makeFirstResponder(editor))
        await drainFocusWork()

        #expect(window.firstResponder === editor)
    }

    @Test func zoomFocusIntentDoesNotFollowSurfaceToAnotherOwner() async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let moving = surface(app)
        let sourceSibling = surface(app)
        let destinationSibling = surface(app)
        let tree = try SplitTree(view: moving).inserting(view: sourceSibling, at: moving, direction: .right)
        let source = FocusIntentController(app, surfaceTree: tree)
        let destination = FocusIntentController(app, surfaceTree: .init(view: destinationSibling))
        destination.focusedSurface = destinationSibling

        source.toggleSplitZoom(on: moving)
        source.surfaceTree = .init(view: sourceSibling)
        destination.surfaceTree = try destination.surfaceTree.inserting(
            view: moving, at: destinationSibling, direction: .right)
        #expect(app.windowRegistry.owner(of: moving) === destination)
        await drainFocusWork()

        #expect(destination.focusedSurface === destinationSibling)
    }

    private func drainFocusWork() async {
        // Drain deferred attachment and focus completion through two queue barriers.
        for _ in 0..<2 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}

private class FocusIntentController: BaseTerminalController {
    override var undoManager: ExpiringUndoManager? { nil }
}
