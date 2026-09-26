import AppKit

extension TerminalController {
    enum TabCloseScope: CaseIterable {
        case others
        case right

        var actionName: String {
            switch self {
            case .others: "Close Other Tabs"
            case .right: "Close Tabs to the Right"
            }
        }

        var prompt: String {
            switch self {
            case .others: "Close Other Tabs?"
            case .right: "Close Tabs on the Right?"
            }
        }

        var explanation: String {
            switch self {
            case .others:
                "At least one other tab still has a running process. If you close the tab the process will be killed."
            case .right:
                "At least one tab to the right still has a running process. If you close the tab the process will be killed."
            }
        }
    }

    @IBAction func closeOtherTabs(_ sender: Any?) { requestTabClose(.others) }
    @IBAction func closeTabsOnTheRight(_ sender: Any?) { requestTabClose(.right) }

    private func tabCloseTargets(_ scope: TabCloseScope) -> [TerminalController] {
        guard let window, let group = window.tabGroup,
              let selected = group.windows.firstIndex(of: window) else { return [] }
        return group.windows.enumerated().compactMap { index, candidate in
            guard scope == .others ? index != selected : index > selected else { return nil }
            return candidate.windowController as? TerminalController
        }
    }

    private func requestTabClose(_ scope: TabCloseScope) {
        let targets = tabCloseTargets(scope)
        guard !targets.isEmpty else { return }
        guard targets.contains(where: { $0.surfaceTree.contains(where: { $0.needsConfirmQuit }) }) else {
            closeTabsImmediately(scope, targets: targets)
            return
        }
        // Confirmation applies to this snapshot, never to tabs opened later.
        confirmClose(messageText: scope.prompt, informativeText: scope.explanation) { [weak self] in
            self?.closeTabsImmediately(scope, targets: targets)
        }
    }

    func closeTabsImmediately(_ scope: TabCloseScope) {
        closeTabsImmediately(scope, targets: tabCloseTargets(scope))
    }

    private func closeTabsImmediately(_ scope: TabCloseScope, targets: [TerminalController]) {
        guard let window, let group = window.tabGroup else { return }
        // A tab may have moved or closed while a confirmation sheet was open.
        let targets = targets.filter { candidate in
            candidate !== self && candidate.window.map { group.windows.contains($0) } == true
        }
        guard !targets.isEmpty else { return }
        let manager = undoManager
        manager?.beginUndoGrouping()
        defer { manager?.endUndoGrouping() }
        for target in targets { target.closeTabImmediately(registerRedo: false) }
        guard let manager else { return }
        manager.setActionName(scope.actionName)
        manager.registerUndo(withTarget: self, expiresAfter: undoExpiration) { target in
            DispatchQueue.main.async { [weak target] in
                guard let target, target.ghostty.windowRegistry.all.contains(where: { $0 === target }) else { return }
                target.window?.makeKeyAndOrderFront(nil)
            }
            manager.registerUndo(withTarget: target, expiresAfter: target.undoExpiration) { target in
                target.closeTabsImmediately(scope)
            }
        }
    }
}
