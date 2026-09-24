import AppKit

/// App-scoped topology index. It owns neither windows nor terminal sessions.
/// Split-tree mutations publish membership independently of AppKit attachment.
@MainActor
final class WindowRegistry {
    private let owners = NSMapTable<Ghostty.SurfaceView, BaseTerminalController>.weakToWeakObjects()

    private let surfaces = NSMapTable<NSUUID, Ghostty.SurfaceView>.strongToWeakObjects()

    private let controllers = NSHashTable<BaseTerminalController>.weakObjects()
    private(set) weak var lastMain: TerminalController?
    private(set) var lastCascadePoint = NSPoint.zero

    /// Preserve AppKit's ordering, including inactive tabs, but exclude windows
    /// from other apps and closed controllers retained by undo or pending work.
    var windowControllers: [BaseTerminalController] {
        NSApp.windows.compactMap { window in
            guard let controller = window.windowController as? BaseTerminalController,
                  controllers.contains(controller) else { return nil }
            return controller
        }
    }

    var registeredControllers: [BaseTerminalController] { controllers.allObjects }

    var all: [TerminalController] { windowControllers.compactMap { $0 as? TerminalController } }

    var preferredParent: TerminalController? {
        let controllers = all
        return controllers.first { $0.window?.isMainWindow ?? false }
            ?? lastMain ?? controllers.last
    }

    func register(_ controller: BaseTerminalController) {
        precondition(controller.ghostty.windowRegistry === self)
        guard !controllers.contains(controller) else { return }
        controllers.add(controller)
        update(controller, from: .init(), to: controller.surfaceTree)
    }

    func unregister(_ controller: BaseTerminalController) {
        update(controller, from: controller.surfaceTree, to: .init())
        controllers.remove(controller)
        if lastMain === controller { lastMain = nil }
        if !controllers.allObjects.contains(where: { $0 is TerminalController }) { lastCascadePoint = .zero }
    }

    func didBecomeMain(_ controller: TerminalController) {
        guard controllers.contains(controller) else { return }
        lastMain = controller
    }

    func applyCascade(to window: NSWindow, hasFixedPos: Bool) {
        guard !hasFixedPos,
              let controller = window.windowController as? TerminalController,
              controllers.contains(controller) else { return }
        lastCascadePoint = window.cascadeTopLeft(from: all.count > 1 ? lastCascadePoint : .zero)
    }

    /// Closing a tab preserves the next offset from the remaining focused window.
    /// A key window belonging to another app (or a panel) cannot affect placement.
    func windowWillClose(_ controller: TerminalController, keyWindow: NSWindow?) {
        guard controllers.contains(controller) else { return }
        defer { unregister(controller) }
        guard let keyWindow,
              let focused = keyWindow.windowController as? TerminalController,
              controllers.contains(focused) else { return }
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

    func surface(id: UUID) -> Ghostty.SurfaceView? {
        guard let surface = surfaces.object(forKey: id as NSUUID),
              owner(of: surface) != nil else { return nil }
        return surface
    }

    func owner(of surface: Ghostty.SurfaceView) -> BaseTerminalController? {
        guard surface.windowRegistry === self,
              let owner = owners.object(forKey: surface),
              controllers.contains(owner) else { return nil }
        return owner
    }

    func update(
        _ owner: BaseTerminalController,
        from oldTree: SplitTree<Ghostty.SurfaceView>,
        to newTree: SplitTree<Ghostty.SurfaceView>
    ) {
        precondition(owner.ghostty.windowRegistry === self)
        let newMembers = Set(newTree.map(ObjectIdentifier.init))
        for surface in oldTree where !newMembers.contains(ObjectIdentifier(surface)) {
            // A destination may register before the source finishes detaching.
            if owners.object(forKey: surface) === owner {
                owners.removeObject(forKey: surface)
                if surfaces.object(forKey: surface.id as NSUUID) === surface {
                    surfaces.removeObject(forKey: surface.id as NSUUID)
                }
            }
        }
        for surface in newTree {
            precondition(surface.windowRegistry === self)
            owners.setObject(owner, forKey: surface)
            surfaces.setObject(surface, forKey: surface.id as NSUUID)
        }
    }
}
