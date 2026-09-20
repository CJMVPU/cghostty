import AppKit
import AppIntents

struct QuickTerminalIntent: AppIntent {
    static let title: LocalizedStringResource = "Open the Quick Terminal"
    static let description = IntentDescription("Open the Quick Terminal. If it is already open, then do nothing.")

    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[TerminalEntity]> {
        guard await requestIntentPermission() else {
            throw GhosttyIntentError.permissionDenied
        }

        guard let delegate = NSApp.delegate as? AppDelegate else {
            throw GhosttyIntentError.appUnavailable
        }

        let wasInitialized = delegate.quickControllerInitialized

        // This is safe to call even if it is already shown.
        let c = delegate.quickController

        c.animateIn()

        // Grab all our terminals
        var terminals: [TerminalEntity] = []
        for view in c.surfaceTree.root?.leaves() ?? [] {
            if wasInitialized {
                terminals.append(TerminalEntity(view))
            } else {
                terminals.append(await TerminalEntity(view: view))
            }
        }

        return .result(value: terminals)
    }
}
