import AppKit

/// Split topology, focus transfer and undo share one mutation path.
extension BaseTerminalController {
    /// Find the next surface to focus when a node is being closed.
    /// Goes to previous split unless we're the leftmost leaf, then goes to next.
    func findNextFocusTargetAfterClosing(node: SplitTree<Ghostty.SurfaceView>.Node) -> Ghostty.SurfaceView? {
        guard let root = surfaceTree.root else { return nil }

        // If we're the leftmost, then we move to the next surface after closing.
        // Otherwise, we move to the previous.
        if root.leftmostLeaf() == node.leftmostLeaf() {
            return surfaceTree.focusTarget(for: .next, from: node)
        } else {
            return surfaceTree.focusTarget(for: .previous, from: node)
        }
    }

    /// Remove a node from the surface tree and move focus appropriately.
    ///
    /// This also updates the undo manager to support restoring this node.
    ///
    /// This does no confirmation and assumes confirmation is already done.
    func removeSurfaceNode(_ node: SplitTree<Ghostty.SurfaceView>.Node) {
        guard surfaceTree.contains(node) else { return }
        // Move focus if the closed surface was focused and we have a next target
        let nextFocus: Ghostty.SurfaceView? = if node.contains(
            where: { $0 == focusedSurface }
        ) {
            findNextFocusTargetAfterClosing(node: node)
        } else {
            nil
        }

        replaceSurfaceTree(
            surfaceTree.removing(node),
            // When a non-focused surface is removed and this window stays as the key window,
            // we should refocus the `focusedSurface` to make sure the window's firstResponder remains as it is.
            //
            // This is a weird workaround, since `resignFirstResponder` wasn't called on `focusedSurface` after drag,
            // but the first responder became the window itself.
            moveFocusTo: nextFocus ?? focusedSurface,
            moveFocusFrom: focusedSurface,
            undoAction: "Close Terminal"
        )
    }

    func equalizeSplits(from target: Ghostty.SurfaceView) {
        // Check if target surface is in current controller's tree
        guard surfaceTree.contains(target) else { return }

        // Equalize the splits
        surfaceTree = surfaceTree.equalized()
    }

    func focusSplit(from target: Ghostty.SurfaceView, direction: Ghostty.SplitFocusDirection) {
        // Find the target within this controller's tree
        guard let targetNode = surfaceTree.root?.node(view: target) else { return }

        // Find the next surface to focus
        guard let nextSurface = surfaceTree.focusTarget(for: direction.toSplitTreeFocusDirection(), from: targetNode) else {
            return
        }

        if surfaceTree.zoomed != nil {
            if controllerConfig.splitPreserveZoom.contains(.navigation) {
                surfaceTree = SplitTree(
                    root: surfaceTree.root,
                    zoomed: surfaceTree.root?.node(view: nextSurface))
            } else {
                surfaceTree = SplitTree(root: surfaceTree.root, zoomed: nil)
            }
        }

        // Move focus to the next surface
        DispatchQueue.main.async {
            guard self.surfaceTree.contains(nextSurface) else { return }
            Ghostty.moveFocus(to: nextSurface, from: target)
        }
    }

    func toggleSplitZoom(on target: Ghostty.SurfaceView) {
        // The target must be within our tree
        guard let targetNode = surfaceTree.root?.node(view: target) else { return }

        // Toggle the zoomed state
        if surfaceTree.zoomed == targetNode {
            // Already zoomed, unzoom it
            surfaceTree = SplitTree(root: surfaceTree.root, zoomed: nil)
        } else {
            // We require that the split tree have splits
            guard surfaceTree.isSplit else { return }

            // Not zoomed or different node zoomed, zoom this node
            surfaceTree = SplitTree(root: surfaceTree.root, zoomed: targetNode)
        }

        // Move focus to our window. Importantly this ensures that if we click the
        // reset zoom button in a tab bar of an unfocused tab that we become focused.
        window?.makeKeyAndOrderFront(nil)

        // Ensure focus stays on the target surface. We lose focus when we do
        // this so we need to grab it again.
        DispatchQueue.main.async {
            Ghostty.moveFocus(to: target)
        }
    }

    func resizeSplit(from target: Ghostty.SurfaceView, direction: Ghostty.SplitResizeDirection, amount: UInt16) {
        // The target must be within our tree
        guard let targetNode = surfaceTree.root?.node(view: target) else { return }

        // Convert Ghostty.SplitResizeDirection to SplitTree.Spatial.Direction
        let spatialDirection: SplitTree<Ghostty.SurfaceView>.Spatial.Direction
        switch direction {
        case .up: spatialDirection = .up
        case .down: spatialDirection = .down
        case .left: spatialDirection = .left
        case .right: spatialDirection = .right
        }

        // Use viewBounds for the spatial calculation bounds
        let bounds = CGRect(origin: .zero, size: surfaceTree.viewBounds())

        // Perform the resize using the new SplitTree resize method
        do {
            surfaceTree = try surfaceTree.resizing(node: targetNode, by: amount, in: spatialDirection, with: bounds)
        } catch {
            Ghostty.logger.warning("failed to resize split: \(error, privacy: .public)")
        }
    }

    func detachSplit(_ target: Ghostty.SurfaceView, at position: NSPoint) {
        guard let targetNode = surfaceTree.root?.node(view: target) else { return }

        // If our tree isn't split, then we never create a new window, because
        // it is already a single split.
        guard surfaceTree.isSplit else { return }

        // If we are removing our focused surface then we move it. We need to
        // keep track of our old one so undo sends focus back to the right place.
        let oldFocusedSurface = focusedSurface
        if focusedSurface == target {
            focusedSurface = findNextFocusTargetAfterClosing(node: targetNode)
        }

        // Remove the surface from our tree
        let removedTree = surfaceTree.removing(targetNode)

        // Create a new tree with the dragged surface and open a new window
        let newTree = SplitTree<Ghostty.SurfaceView>(view: target)

        // Treat our undo below as a full group.
        undoManager?.beginUndoGrouping()
        defer {
            undoManager?.setActionName("Move Split")
            undoManager?.endUndoGrouping()
        }

        replaceSurfaceTree(removedTree, moveFocusFrom: oldFocusedSurface)
        _ = TerminalController.newWindow(
            ghostty,
            tree: newTree,
            position: position,
            confirmUndo: false,
            inheritBackgroundOpacity: isBackgroundOpaque)
    }

    func performSplitAction(_ action: TerminalSplitOperation) {
        switch action {
        case .resize(let resize):
            splitDidResize(node: resize.node, to: resize.ratio)
        case .drop(let drop):
            splitDidDrop(source: drop.payload, destination: drop.destination, zone: drop.zone)
        }
    }

    private func splitDidResize(node: SplitTree<Ghostty.SurfaceView>.Node, to newRatio: Double) {
        let resizedNode = node.resizing(to: newRatio)
        do {
            surfaceTree = try surfaceTree.replacing(node: node, with: resizedNode)
        } catch {
            Ghostty.logger.warning("failed to replace node during split resize: \(error, privacy: .public)")
        }
    }

    private func splitDidDrop(
        source: Ghostty.SurfaceView,
        destination: Ghostty.SurfaceView,
        zone: TerminalSplitDropZone
    ) {
        // Map drop zone to split direction
        let direction: SplitTree<Ghostty.SurfaceView>.NewDirection = switch zone {
        case .top: .up
        case .bottom: .down
        case .left: .left
        case .right: .right
        }

        // Check if source is in our tree
        if let sourceNode = surfaceTree.root?.node(view: source) {
            // Source is in our tree - same window move
            let treeWithoutSource = surfaceTree.removing(sourceNode)
            let newTree: SplitTree<Ghostty.SurfaceView>
            do {
                newTree = try treeWithoutSource.inserting(view: source, at: destination, direction: direction)
            } catch {
                Ghostty.logger.warning("failed to insert surface during drop: \(error, privacy: .public)")
                return
            }

            replaceSurfaceTree(
                newTree,
                moveFocusTo: source,
                moveFocusFrom: focusedSurface,
                undoAction: "Move Split")
            return
        }

        guard let sourceController = ghostty.windowRegistry.owner(of: source),
              sourceController !== self,
              let sourceNode = sourceController.surfaceTree.root?.node(view: source) else {
            Ghostty.logger.warning("source surface not found in this app during drop")
            return
        }

        // Remove from source controller's tree and add it to our tree.
        // We do this first because if there is an error then we can
        // abort.
        let newTree: SplitTree<Ghostty.SurfaceView>
        do {
            newTree = try surfaceTree.inserting(view: source, at: destination, direction: direction)
        } catch {
            Ghostty.logger.warning("failed to insert surface during cross-window drop: \(error, privacy: .public)")
            return
        }

        // Treat our undo below as a full group.
        undoManager?.beginUndoGrouping()
        defer {
            undoManager?.setActionName("Move Split")
            undoManager?.endUndoGrouping()
        }

        // Remove the node from the source.
        sourceController.removeSurfaceNode(sourceNode)

        // Add in the surface to our tree
        replaceSurfaceTree(
            newTree,
            moveFocusTo: source,
            moveFocusFrom: focusedSurface)
    }

    func applySplitTree(
        _ tree: SplitTree<Ghostty.SurfaceView>,
        focus: Ghostty.SurfaceView?,
        previousFocus: Ghostty.SurfaceView?,
        actionName: String?
    ) {
        let previous = surfaceTree
        surfaceTree = tree
        if let focus {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.surfaceTree.contains(focus),
                      self.ghostty.windowRegistry.owner(of: focus) === self else { return }
                Ghostty.moveFocus(to: focus, from: previousFocus)
            }
        }
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self, expiresAfter: undoExpiration) { target in
            target.replaceSurfaceTree(
                previous,
                moveFocusTo: previousFocus,
                moveFocusFrom: focus,
                undoAction: actionName
            )
        }
        if let actionName { undoManager.setActionName(actionName) }
    }
}
