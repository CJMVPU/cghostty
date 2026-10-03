import AppKit
import Testing
@testable import Ghostty

@MainActor struct CloseConfirmationTests {
    private class ControlledTerminal: TerminalController {
        var requestCount = 0
        var finishedRequestCount = 0
        var presentationCount = 0
        var pendingResponse: CheckedContinuation<NSApplication.ModalResponse, Never>?

        override func confirmCloseAsync(
            messageText: String, informativeText: String, confirmButtonTitle: String = "Close"
        ) async -> CloseConfirmationResult {
            requestCount += 1
            let result = await super.confirmCloseAsync(
                messageText: messageText, informativeText: informativeText,
                confirmButtonTitle: confirmButtonTitle
            )
            finishedRequestCount += 1
            return result
        }

        override func presentCloseConfirmation(
            _ alert: NSAlert, for window: NSWindow
        ) async -> NSApplication.ModalResponse {
            presentationCount += 1
            return await withCheckedContinuation { pendingResponse = $0 }
        }

        func respond(_ response: NSApplication.ModalResponse) {
            let continuation = pendingResponse
            pendingResponse = nil
            continuation?.resume(returning: response)
        }
    }

    @Test(arguments: [true, false])
    func duplicateCloseCannotApprovePendingConfirmation(approve: Bool) async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/zsh -f"
        config.workingDirectory = FileManager.default.temporaryDirectory.path
        let controller = ControlledTerminal(app, withBaseConfig: config)
        let window = try #require(controller.window)
        let surface = try #require(controller.surfaceTree.first)
        defer {
            controller.respond(.alertSecondButtonReturn)
            window.close()
        }
        var completed = 0
        let requestClose = {
            controller.confirmClose(messageText: "Close?", informativeText: "Test") {
                completed += 1
                controller.closeWindowImmediately()
            }
        }
        requestClose()
        try await NativeTestWait.until(
            "first close is waiting for approval", timeout: .seconds(2), polling: .milliseconds(5),
            diagnostics: { "presentations=\(controller.presentationCount)" },
            { controller.pendingResponse != nil }
        )
        requestClose()
        try await NativeTestWait.until(
            "duplicate close has been processed", timeout: .seconds(2), polling: .milliseconds(5),
            diagnostics: { "requests=\(controller.requestCount)" },
            { controller.requestCount == 2 }
        )
        #expect(completed == 0)
        #expect(controller.presentationCount == 1)
        #expect(app.windowRegistry.all.contains { $0 === controller })
        #expect(app.windowRegistry.surface(id: surface.id) === surface)
        #expect(app.windowRegistry.owner(of: surface) === controller)
        #expect(await controller.confirmCloseAsync(messageText: "Duplicate", informativeText: "") == .inFlight)
        controller.respond(approve ? .alertFirstButtonReturn : .alertSecondButtonReturn)
        try await NativeTestWait.until(
            "all confirmation requests finish", timeout: .seconds(2), polling: .milliseconds(5),
            diagnostics: { "finished=\(controller.finishedRequestCount)" },
            { controller.finishedRequestCount == 3 }
        )
        if approve {
            try await NativeTestWait.until(
                "approved close finishes once", timeout: .seconds(2), polling: .milliseconds(5),
                diagnostics: { "completions=\(completed)" }, { completed == 1 }
            )
            #expect(app.windowRegistry.surface(id: surface.id) == nil)
            #expect(!app.windowRegistry.all.contains { $0 === controller })
        } else {
            #expect(completed == 0)
            #expect(app.windowRegistry.surface(id: surface.id) === surface)
            #expect(app.windowRegistry.owner(of: surface) === controller)
            requestClose()
            try await NativeTestWait.until(
                "cancelled close can be requested again", timeout: .seconds(2), polling: .milliseconds(5),
                diagnostics: { "presentations=\(controller.presentationCount)" },
                { controller.presentationCount == 2 }
            )
            controller.respond(.alertFirstButtonReturn)
            try await NativeTestWait.until(
                "new approval closes once", timeout: .seconds(2), polling: .milliseconds(5),
                diagnostics: { "completions=\(completed)" }, { completed == 1 }
            )
        }
    }
}
