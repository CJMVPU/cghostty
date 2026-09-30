import AppKit
import Foundation
@testable import Ghostty

/// Evaluate first, then enforce the deadline and sleep, as the original waits did.
/// Diagnostics run only on timeout; predicate errors and cancellation propagate.
@MainActor enum NativeTestWait {
    nonisolated struct Timeout: Error, CustomStringConvertible {
        let stage: String
        let state: String
        let fileID: String
        let line: Int
        var description: String { "Timed out waiting for \(stage) at \(fileID):\(line).\n\(state)" }
    }

    static func until(
        _ stage: String, timeout: Duration, polling: Duration,
        diagnostics: () -> String, fileID: String = #fileID, line: Int = #line,
        _ predicate: () throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while try !predicate() {
            guard ContinuousClock.now < deadline else {
                throw Timeout(stage: stage, state: diagnostics(), fileID: fileID, line: line)
            }
            try await Task.sleep(for: polling)
        }
    }

    static func surfaceState(
        _ surface: Ghostty.Surface?, view: Ghostty.SurfaceView? = nil, expectedText: String? = nil
    ) -> String {
        guard let surface else { return "surfaceAvailable=false" }
        let contents = surface.readContents(viewport: false)
        let text = expectedText.map { "expectedText=\(String(reflecting: $0)), textReady=\(contents.contains($0))" } ?? ""
        return """
        surfaceAvailable=true, \(text), grid=\(surface.size.columns)x\(surface.size.rows),
        exited=\(surface.processExited), revision=\(surface.renderRevision),
        healthy=\(String(describing: view?.healthy)), bounds=\(String(describing: view?.bounds)),
        windowVisible=\(String(describing: view?.window?.isVisible)), focused=\(String(describing: view?.focused)),
        output=\(String(reflecting: String(contents.suffix(2048))))
        """
    }

    static func compositorState(_ worker: WindowCompositorWorker) -> String {
        "panes=\(worker.paneCount), idle=\(worker.isIdle), statistics=\(worker.statistics)\n" + worker.stateForTesting
    }
}
