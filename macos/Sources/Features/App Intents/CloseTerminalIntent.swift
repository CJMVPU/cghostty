import AppKit
import AppIntents
import GhosttyKit

struct CloseTerminalIntent: AppIntent {
    static let title: LocalizedStringResource = "Close Terminal"
    static let description = IntentDescription("Close an existing terminal.")

    @Parameter(
        title: "Terminal",
        description: "The terminal to close.",
    )
    var terminal: TerminalEntity

    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult {
        guard await requestIntentPermission() else {
            throw GhosttyIntentError.permissionDenied
        }

        guard let surfaceView = terminal.surfaceView else {
            throw GhosttyIntentError.surfaceNotFound
        }

        guard let controller = BaseTerminalController.controller(owning: surfaceView) else {
            return .result()
        }

        controller.closeSurface(surfaceView, withConfirmation: false)
        return .result()
    }
}
