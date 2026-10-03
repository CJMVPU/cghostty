/// An UndoManager subclass that supports registering undo operations that automatically expire after a specified duration.
///
/// This class extends the standard UndoManager to add time-based expiration for undo operations.
/// When an undo operation expires, it is automatically removed from the undo stack and cannot be invoked.
///
/// Example usage:
/// ```swift
/// let undoManager = ExpiringUndoManager()
/// undoManager.registerUndo(withTarget: myObject, expiresAfter: .seconds(30)) { target in
///     // Undo operation that expires after 30 seconds
///     target.restorePreviousState()
/// }
/// ```
class ExpiringUndoManager: UndoManager {
    /// The set of expiring targets so we can properly clean them up when removeAllActions
    /// is called with the real target.
    private lazy var expiringTargets: Set<ExpiringTarget> = []

    // Mirror only group membership, leaving action execution to UndoManager.
    // Approval must finish before UndoManager consumes any part of the group.
    private var openGroups: [[ExpiringTarget]] = []
    private var undoGroups: [[ExpiringTarget]] = []
    private var redoGroups: [[ExpiringTarget]] = []
    private var historyRevision: UInt64 = 0
    private var performingHistoryChange = false
    private(set) var pendingApproval: Task<Void, Never>?

    /// Registers an undo operation that automatically expires after the specified duration.
    ///
    /// - Parameters:
    ///   - target: The target object for the undo operation. The undo operation will be removed
    ///             if this object is deallocated before the operation is invoked.
    ///   - duration: The duration after which the undo operation should expire and be removed from the undo stack.
    ///   - handler: The closure to execute when the undo operation is invoked. The closure receives
    ///              the target object as its parameter.
    func registerUndo<TargetType: AnyObject>(
        withTarget target: TargetType,
        expiresAfter duration: Duration,
        approval: (@MainActor (TargetType) async -> Bool)? = nil,
        handler: @escaping (TargetType) -> Void
    ) {
        // Ignore instantly expiring undos
        guard duration.timeInterval > 0 else { return }

        // Ignore when undo registration is disabled. UndoManager still lets
        // registration happen then cancels later but I was seeing some
        // weird behavior with this so let's just guard on it.
        guard self.isUndoRegistrationEnabled else { return }

        let expiringTarget = ExpiringTarget(
            target,
            expiresAfter: duration,
            in: self)
        if let approval {
            expiringTarget.approval = { [weak target] in
                guard let target else { return false }
                return await approval(target)
            }
        }
        expiringTargets.insert(expiringTarget)
        historyRevision &+= 1
        if !isUndoingOrRedoing { redoGroups = [] }

        super.registerUndo(withTarget: expiringTarget) { [weak self] expiringTarget in
            self?.expiringTargets.remove(expiringTarget)
            guard let target = expiringTarget.target as? TargetType else { return }
            handler(target)
        }
        while openGroups.count < groupingLevel { openGroups.append([]) }
        if groupingLevel > 0 {
            openGroups[groupingLevel - 1].append(expiringTarget)
        } else {
            recordGroup([expiringTarget])
        }
    }

    override func endUndoGrouping() {
        let level = groupingLevel
        let group = level > 0 && openGroups.count >= level ? openGroups[level - 1] : []
        if level > 0 && openGroups.count >= level { openGroups.removeLast() }
        // UndoManager ends its inverse group before clearing isUndoing/isRedoing.
        let undoing = isUndoing
        let redoing = isRedoing
        super.endUndoGrouping()
        guard !group.isEmpty else { return }
        if level > 1 {
            while openGroups.count < level - 1 { openGroups.append([]) }
            openGroups[level - 2].append(contentsOf: group)
        } else {
            recordGroup(group, undoing: undoing, redoing: redoing)
        }
    }

    private func recordGroup(_ group: [ExpiringTarget], undoing: Bool? = nil, redoing: Bool? = nil) {
        historyRevision &+= 1
        if undoing ?? isUndoing {
            redoGroups.append(group)
        } else if redoing ?? isRedoing {
            undoGroups.append(group)
        } else {
            undoGroups.append(group)
            if levelsOfUndo > 0 && undoGroups.count > levelsOfUndo { undoGroups.removeFirst() }
        }
    }

    override func undo() {
        if performingHistoryChange {
            super.undo()
        } else {
            requestHistoryChange(redo: false)
        }
    }

    override func redo() {
        if performingHistoryChange {
            super.redo()
        } else {
            requestHistoryChange(redo: true)
        }
    }

    override func undoNestedGroup() {
        if performingHistoryChange {
            super.undoNestedGroup()
        } else {
            requestHistoryChange(redo: false)
        }
    }

    private func requestHistoryChange(redo: Bool) {
        guard pendingApproval == nil else { return }
        // Match UndoManager.undo's automatic closing of the current event group.
        if !redo && groupsByEvent && groupingLevel == 1 { endUndoGrouping() }
        guard redo ? canRedo : canUndo else { return }
        let group = (redo ? redoGroups : undoGroups).last ?? []
        let approvals = group.reversed().compactMap(\.approval)
        guard !approvals.isEmpty else {
            performHistoryChange(redo: redo)
            return
        }
        let revision = historyRevision
        pendingApproval = Task { [weak self] in
            guard let self else { return }
            defer { pendingApproval = nil }
            for approval in approvals {
                guard await approval(), !Task.isCancelled, historyRevision == revision else { return }
            }
            // A sheet can yield to new edits or expiration. Never undo a different group.
            guard historyRevision == revision else { return }
            performHistoryChange(redo: redo)
        }
    }

    private func performHistoryChange(redo: Bool) {
        performingHistoryChange = true
        defer { performingHistoryChange = false }
        historyRevision &+= 1
        if redo {
            if !redoGroups.isEmpty { redoGroups.removeLast() }
            super.redo()
        } else {
            if !undoGroups.isEmpty { undoGroups.removeLast() }
            super.undo()
        }
    }

    private func removeGroupMember(_ target: ExpiringTarget) {
        historyRevision &+= 1
        openGroups = openGroups.map { $0.filter { $0 !== target } }
        undoGroups = undoGroups.map { $0.filter { $0 !== target } }.filter { !$0.isEmpty }
        redoGroups = redoGroups.map { $0.filter { $0 !== target } }.filter { !$0.isEmpty }
    }

    /// Removes all undo and redo operations from the undo manager.
    ///
    /// This override ensures that all expiring targets are also cleared when
    /// the undo manager is reset.
    override func removeAllActions() {
        historyRevision &+= 1
        pendingApproval?.cancel()
        super.removeAllActions()
        expiringTargets = []
        openGroups = []
        undoGroups = []
        redoGroups = []
    }

    /// Removes all undo and redo operations involving the specified target.
    ///
    /// This override ensures that when actions are removed for a target, any associated
    /// expiring targets are also properly cleaned up.
    ///
    /// - Parameter target: The target object whose actions should be removed.
    override func removeAllActions(withTarget target: Any) {
        // Call super to handle standard removal
        super.removeAllActions(withTarget: target)

        // If the target is an expiring target, remove it.
        if let expiring = target as? ExpiringTarget {
            expiringTargets.remove(expiring)
            removeGroupMember(expiring)
        } else {
            // Find and remove any ExpiringTarget instances that wrap this target.
            expiringTargets
                .filter { $0.target == nil || $0.target === (target as AnyObject) }
                .forEach {
                    // Remove the proxy's undo actions before dropping our ownership.
                    $0.expire()
                    expiringTargets.remove($0)
                }
        }
    }
}

/// A target object for ExpiringUndoManager that removes itself from the
/// undo manager after it expires.
///
/// This class acts as a proxy for the real target object in undo operations.
/// It holds a weak reference to the actual target and automatically removes
/// all associated undo operations when the timer fires or expire() is called.
/// Deallocation only cancels the timer; the manager has already released the entry.
private class ExpiringTarget {
    /// The actual target object for the undo operation, held weakly to avoid retain cycles.
    private(set) weak var target: AnyObject?

    var approval: (@MainActor () async -> Bool)?

    /// Timer that triggers expiration after the specified duration.
    private var timer: Timer?

    /// The undo manager from which to remove actions when this target expires.
    private weak var undoManager: UndoManager?

    /// Creates an expiring target that will automatically remove undo actions after the specified duration.
    ///
    /// - Parameters:
    ///   - target: The target object to hold weakly.
    ///   - duration: The time after which the target should expire.
    ///   - undoManager: The UndoManager from which to remove actions when expired.
    init(_ target: AnyObject? = nil, expiresAfter duration: Duration, in undoManager: UndoManager) {
        self.target = target
        self.undoManager = undoManager
        self.timer = Timer.scheduledTimer(
            withTimeInterval: duration.timeInterval,
            repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.expire() }
        }
    }

    /// Manually expires the target, removing all associated undo actions and invalidating the timer.
    ///
    /// This method is called automatically when the timer fires, but can also be called manually
    /// to expire the target before the timer duration has elapsed.
    func expire() {
        target = nil
        undoManager?.removeAllActions(withTarget: self)
        timer?.invalidate()
        timer = nil
    }

    isolated deinit {
        // The manager has already released this entry. Calling back into it here
        // would reenter its target set while removeAllActions is mutating it.
        timer?.invalidate()
    }
}

extension ExpiringTarget: Hashable, Equatable {
    static func == (lhs: ExpiringTarget, rhs: ExpiringTarget) -> Bool {
        return lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}
