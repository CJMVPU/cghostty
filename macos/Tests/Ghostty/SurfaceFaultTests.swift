import AppKit
import GhosttyKit
import Testing
@testable import Ghostty

@MainActor struct SurfaceFaultTests {
    private func waitForFault(_ view: Ghostty.SurfaceView, app: Ghostty.App) async throws -> Ghostty.SurfaceFault {
        let deadline = ContinuousClock.now + .seconds(5)
        while view.state.fault == nil && ContinuousClock.now < deadline {
            app.appTick()
            await Task.yield()
        }
        return try #require(view.state.fault)
    }

    @Test func diagnosticsOwnTheCallbackString() async {
        var bytes = Array("CopiedError".utf8CString)
        let fault = bytes.withUnsafeBufferPointer {
            Ghostty.SurfaceFault(.init(kind: GHOSTTY_SURFACE_FAULT_IO_FAILED, error_code: $0.baseAddress))
        }
        bytes[0] = 88
        #expect(fault.errorCode == "CopiedError")
        #expect(fault.kind == .ioFailed)
        let code = await Task.detached { fault.errorCode }.value
        #expect(code == "CopiedError")
        #expect(Ghostty.SurfaceFault(.init(kind: GHOSTTY_SURFACE_FAULT_INPUT_FAILED, error_code: nil)).errorCode == "Unknown")
    }

    @Test(arguments: [false, true])
    func startupInputFailureReachesUnattachedNativeView(oversized: Bool) async throws {
        let input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: input) }
        if oversized {
            #expect(FileManager.default.createFile(atPath: input.path, contents: nil))
            let file = try FileHandle(forWritingTo: input)
            try file.truncate(atOffset: 11 * 1024 * 1024)
            try file.close()
        }
        let config = try TemporaryConfig("input = path:\(input.path)")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        var base = Ghostty.SurfaceConfiguration()
        base.command = "/bin/cat"
        base.workingDirectory = FileManager.default.temporaryDirectory.path
        let view = Ghostty.SurfaceView(app, baseConfig: base)
        #expect(view.window == nil)
        let surface = try #require(view.surfaceModel)
        let fault = try await waitForFault(view, app: app)
        #expect(fault.kind == .inputFailed)
        #expect(fault.errorCode == (oversized ? "InputFailed" : "InputNotFound"))
        #expect(view.state.childExitedMessage == nil)
        #expect(!surface.needsQuitConfirmation)
        // Exceed the 64-entry IO mailbox capacity. Failed startup still has to
        // dispose input and configuration messages without blocking the UI.
        for _ in 0..<200 { surface.sendText("input after failure") }
        surface.updateConfig(config)
        #expect(view.state.fault == fault)
        // Accepted native delivery must not write presentation prose into terminal contents.
        #expect(!surface.readContents(viewport: false).contains("Terminal IO failed"))
    }

    @Test func closingBeforeFaultDeliveryReleasesSurfaceAndApp() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let config = try TemporaryConfig("input = path:\(missing.path)")
        var app: Ghostty.App? = Ghostty.App(configPath: config.temporaryFile.path)
        weak let weakApp = app
        var base = Ghostty.SurfaceConfiguration()
        base.command = "/bin/cat"
        var view: Ghostty.SurfaceView? = Ghostty.SurfaceView(try #require(app), baseConfig: base)
        weak let weakView = view
        #expect(view?.surfaceModel != nil)
        view = nil
        app = nil
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(weakView == nil)
        #expect(weakApp == nil)
    }
}
