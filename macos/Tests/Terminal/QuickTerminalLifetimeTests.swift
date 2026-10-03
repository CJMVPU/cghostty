import AppKit
import Testing
@testable import Ghostty

@MainActor struct QuickTerminalLifetimeTests {
    @Test(arguments: [BaseTerminalController.CloseConfirmationResult.cancelled, .inFlight, .allowed])
    func quitReviewDoesNotDestroyQuickTerminalBeforeAllApprovals(
        result: BaseTerminalController.CloseConfirmationResult
    ) async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        let quick = QuickTerminalController(app)
        let quickWindow = try #require(quick.window)
        let normal = TerminalController(app)
        let normalWindow = try #require(normal.window)
        let contentView = try #require(quickWindow.contentView)
        defer { quickWindow.close(); normalWindow.close() }
        var count = 0
        let approved = await AppDelegate.approveTerminationReview([quick, normal], confirm: { _ in
            count += 1
            return count == 1 ? .allowed : result
        })
        #expect(approved == (result == .allowed))
        #expect(count == 2)
        #expect(quickWindow.contentView === contentView)
        #expect(app.windowRegistry.registeredControllers.contains { $0 === quick })
        #expect(app.windowRegistry.registeredControllers.contains { $0 === normal })
    }

    @Test func scriptCloseCanReuseQuickTerminalContentAndRegistry() throws {
        // Scripting object access is enabled without a host AppDelegate. Restore
        // the host immediately after exercising these synchronous entry points.
        let previousDelegate = NSApp.delegate
        NSApp.delegate = nil
        defer { NSApp.delegate = previousDelegate }
        let app = Ghostty.App(configPath: "/dev/null")
        let quick = QuickTerminalController(app)
        let window = try #require(quick.window)
        let contentView = try #require(window.contentView)
        defer { window.close() }
        let scriptWindow = ScriptWindow(primaryController: quick)
        let scriptTab = ScriptTab(window: scriptWindow, controller: quick)
        let description = try #require(NSScriptCommandDescription(
            suiteName: "Ghostty", commandName: "close",
            dictionary: ["CommandClass": "NSScriptCommand", "AppleEventCode": "clos", "AppleEventClass": "core"]
        ))
        let command = NSScriptCommand(commandDescription: description)
        _ = scriptWindow.handleCloseWindow(command)
        _ = scriptTab.handleCloseTab(command)
        #expect(command.scriptErrorNumber == 0)
        #expect(window.contentView === contentView)
        #expect(app.windowRegistry.registeredControllers.contains { $0 === quick })
        #expect(quick.window === window)
    }
}
