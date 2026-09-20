import AppKit
import AppIntents

struct FocusTerminalIntent: AppIntent {
    static let title: LocalizedStringResource = "Focus Terminal"
    static let description = IntentDescription("Move focus to an existing terminal.")

    @Parameter(
        title: "Terminal",
        description: "The terminal to focus.",
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

        guard let controller = surfaceView.windowRegistry.owner(of: surfaceView) else {
            return .result()
        }

        controller.focusSurface(surfaceView)
        return .result()
    }
}
