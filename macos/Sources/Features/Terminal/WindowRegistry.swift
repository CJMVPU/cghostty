import AppKit

/// App-scoped topology index. It owns neither windows nor terminal sessions.
/// Split-tree mutations publish membership independently of AppKit attachment.
@MainActor
final class WindowRegistry {
    private let owners = NSMapTable<Ghostty.SurfaceView, BaseTerminalController>.weakToWeakObjects()

    private let terminals = NSHashTable<TerminalController>.weakObjects()
    private(set) weak var lastMain: TerminalController?
    private(set) var lastCascadePoint = NSPoint.zero

    /// Preserve AppKit's ordering, including inactive tabs, but exclude windows
    /// from other apps and closed controllers retained by undo or pending work.
    var all: [TerminalController] {
        NSApp.windows.compactMap { window in
            guard let controller = window.windowController as? TerminalController,
                  terminals.contains(controller) else { return nil }
            return controller
        }
    }

    var preferredParent: TerminalController? {
        let controllers = all
        return controllers.first { $0.window?.isMainWindow ?? false }
            ?? lastMain ?? controllers.last
    }

    func register(_ controller: TerminalController) {
        precondition(controller.ghostty.windowRegistry === self)
        terminals.add(controller)
    }

    func unregister(_ controller: TerminalController) {
        terminals.remove(controller)
        if lastMain === controller { lastMain = nil }
        if terminals.allObjects.isEmpty { lastCascadePoint = .zero }
    }

    func didBecomeMain(_ controller: TerminalController) {
        guard terminals.contains(controller) else { return }
        lastMain = controller
    }

    func applyCascade(to window: NSWindow, hasFixedPos: Bool) {
        guard !hasFixedPos,
              let controller = window.windowController as? TerminalController,
              terminals.contains(controller) else { return }
        lastCascadePoint = window.cascadeTopLeft(from: all.count > 1 ? lastCascadePoint : .zero)
    }

    /// Closing a tab preserves the next offset from the remaining focused window.
    /// A key window belonging to another app (or a panel) cannot affect placement.
    func windowWillClose(_ controller: TerminalController, keyWindow: NSWindow?) {
        guard terminals.contains(controller) else { return }
        defer { unregister(controller) }
        guard let keyWindow,
              let focused = keyWindow.windowController as? TerminalController,
              terminals.contains(focused) else { return }
        if focused !== controller {
            // On macOS, cascadeTopLeft can move snapped windows even from zero.
            let oldFrame = keyWindow.frame
            lastCascadePoint = keyWindow.cascadeTopLeft(from: .zero)
            if keyWindow.frame != oldFrame { keyWindow.setFrame(oldFrame, display: true) }
        } else {
            let frame = keyWindow.frame
            lastCascadePoint = NSPoint(x: frame.minX, y: frame.maxY)
        }
    }

    func owner(of surface: Ghostty.SurfaceView) -> BaseTerminalController? {
        guard surface.windowRegistry === self,
              let owner = owners.object(forKey: surface),
              owner.surfaceTree.contains(surface) else { return nil }
        return owner
    }

    func update(
        _ owner: BaseTerminalController,
        from oldTree: SplitTree<Ghostty.SurfaceView>,
        to newTree: SplitTree<Ghostty.SurfaceView>
    ) {
        precondition(owner.ghostty.windowRegistry === self)
        for surface in oldTree where !newTree.contains(surface) {
            // A destination may register before the source finishes detaching.
            if owners.object(forKey: surface) === owner {
                owners.removeObject(forKey: surface)
            }
        }
        for surface in newTree {
            precondition(surface.windowRegistry === self)
            owners.setObject(owner, forKey: surface)
        }
    }
}
