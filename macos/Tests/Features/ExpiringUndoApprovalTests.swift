import AppKit
import Testing
@testable import Ghostty

@MainActor struct ExpiringUndoApprovalTests {
    @MainActor private class ApprovalState {
        var allowed = false
        var requests = 0
    }

    private class Counter {
        var value = 0

        func increment(
            _ manager: ExpiringUndoManager,
            duration: Duration = .seconds(30),
            approval: (@MainActor (Counter) async -> Bool)? = nil
        ) {
            value += 1
            manager.registerUndo(withTarget: self, expiresAfter: duration, approval: approval) { target in
                target.value -= 1
                manager.registerUndo(withTarget: target, expiresAfter: duration) { target in
                    target.increment(manager, duration: duration, approval: approval)
                }
            }
        }
    }

    @Test(arguments: [false, true])
    func cancellationKeepsTheEntireExplicitGroupAndRedoHistory(nested: Bool) async throws {
        let manager = ExpiringUndoManager()
        manager.groupsByEvent = false
        let counter = Counter()
        let state = ApprovalState()
        manager.beginUndoGrouping()
        counter.increment(manager)
        if nested { manager.beginUndoGrouping() }
        counter.increment(manager, approval: { _ in state.requests += 1; return state.allowed })
        if nested { manager.endUndoGrouping() }
        manager.setActionName("Create")
        manager.endUndoGrouping()
        manager.undo()
        await manager.pendingApproval?.value
        #expect(counter.value == 2)
        #expect(manager.canUndo)
        #expect(!manager.canRedo)
        #expect(manager.undoActionName == "Create")
        #expect(state.requests == 1)
        state.allowed = true
        manager.undo()
        await manager.pendingApproval?.value
        #expect(counter.value == 0)
        #expect(!manager.canUndo)
        #expect(manager.canRedo)
        manager.redo()
        #expect(counter.value == 2)
        manager.undoNestedGroup()
        await manager.pendingApproval?.value
        #expect(counter.value == 0)
        #expect(state.requests == 3)
        manager.removeAllActions()
    }

    @Test func automaticEventGroupAlsoWaitsForApproval() async throws {
        let manager = ExpiringUndoManager()
        let counter = Counter()
        var response: CheckedContinuation<Bool, Never>?
        counter.increment(manager, approval: { _ in
            await withCheckedContinuation { response = $0 }
        })
        manager.undo()
        try await NativeTestWait.until("undo waits for permission", timeout: .seconds(2), polling: .milliseconds(5),
                                       diagnostics: { "pending=\(response != nil)" }, { response != nil })
        manager.undo()
        manager.redo()
        #expect(counter.value == 1)
        #expect(manager.canUndo)
        #expect(!manager.canRedo)
        response?.resume(returning: false)
        await manager.pendingApproval?.value
        #expect(counter.value == 1)
        #expect(manager.canUndo)
        manager.removeAllActions()
    }

    @Test func newHistoryWhileSheetIsOpenInvalidatesApproval() async throws {
        let manager = ExpiringUndoManager()
        manager.groupsByEvent = false
        let counter = Counter()
        var response: CheckedContinuation<Bool, Never>?
        manager.beginUndoGrouping()
        counter.increment(manager, approval: { _ in
            await withCheckedContinuation { response = $0 }
        })
        manager.endUndoGrouping()
        manager.undo()
        try await NativeTestWait.until("confirmation starts", timeout: .seconds(2), polling: .milliseconds(5),
                                       diagnostics: { "pending=\(response != nil)" }, { response != nil })
        manager.beginUndoGrouping()
        counter.increment(manager)
        manager.endUndoGrouping()
        response?.resume(returning: true)
        await manager.pendingApproval?.value
        #expect(counter.value == 2)
        #expect(!manager.canRedo)
        manager.undo()
        #expect(counter.value == 1)
        manager.removeAllActions()
    }

    @Test func expirationAndTargetRemovalCannotApproveAnotherGroup() async throws {
        let manager = ExpiringUndoManager()
        manager.groupsByEvent = false
        let first = Counter()
        let expiring = Counter()
        var response: CheckedContinuation<Bool, Never>?
        manager.beginUndoGrouping()
        first.increment(manager)
        manager.endUndoGrouping()
        manager.beginUndoGrouping()
        expiring.increment(manager, duration: .milliseconds(40), approval: { _ in
            await withCheckedContinuation { response = $0 }
        })
        manager.endUndoGrouping()
        manager.undo()
        try await NativeTestWait.until("confirmation starts", timeout: .seconds(2), polling: .milliseconds(1),
                                       diagnostics: { "pending=\(response != nil)" }, { response != nil })
        try await Task.sleep(for: .milliseconds(80))
        response?.resume(returning: true)
        await manager.pendingApproval?.value
        #expect(first.value == 1)
        #expect(expiring.value == 1)
        manager.removeAllActions(withTarget: first)
        #expect(!manager.canUndo)
        #expect(!manager.canRedo)
    }

    @Test func limitedHistoryTracksInverseGroups() async throws {
        let manager = ExpiringUndoManager()
        manager.groupsByEvent = false
        manager.levelsOfUndo = 2
        let counter = Counter()
        var requests = 0
        for _ in 0..<3 {
            manager.beginUndoGrouping()
            counter.increment(manager, approval: { _ in requests += 1; return true })
            manager.endUndoGrouping()
        }
        for _ in 0..<2 {
            manager.undo()
            await manager.pendingApproval?.value
        }
        #expect(counter.value == 1)
        #expect(requests == 2)
        #expect(!manager.canUndo)
        manager.redo()
        manager.redo()
        #expect(counter.value == 3)
        manager.undo()
        await manager.pendingApproval?.value
        #expect(counter.value == 2)
        #expect(requests == 3)
        manager.removeAllActions()
    }
}
