import AppKit

/// Handler for the `input text` AppleScript command defined in `Ghostty.sdef`.
///
/// Cocoa scripting instantiates this class because the command's `<cocoa>` element
/// specifies `class="GhosttyScriptInputTextCommand"`. The runtime calls
/// `performDefaultImplementation()` to execute the command.
@MainActor
@objc(GhosttyScriptInputTextCommand)
final class ScriptInputTextCommand: NSScriptCommand {
    nonisolated override init(commandDescription: NSScriptCommandDescription) {
        super.init(commandDescription: commandDescription)
    }

    nonisolated override func performDefaultImplementation() -> Any? {
        // Cocoa scripting dispatches application commands on the main thread.
        // NSScriptCommand predates actor annotations; this reference stays synchronous.
        nonisolated(unsafe) let command = self
        MainActor.assumeIsolated { command.performOnMainActor() }
        return nil
    }

    @MainActor
    private func performOnMainActor() {
        guard NSApp.validateScript(command: self) else { return }

        guard let text = directParameter as? String else {
            scriptErrorNumber = errAEParamMissed
            scriptErrorString = "Missing text to input."
            return
        }

        guard let terminal = evaluatedArguments?["terminal"] as? ScriptTerminal else {
            scriptErrorNumber = errAEParamMissed
            scriptErrorString = "Missing terminal target."
            return
        }

        guard let surfaceView = terminal.surfaceView else {
            scriptErrorNumber = errAEEventFailed
            scriptErrorString = "Terminal surface is no longer available."
            return
        }

        guard let surface = surfaceView.surfaceModel else {
            scriptErrorNumber = errAEEventFailed
            scriptErrorString = "Terminal surface model is not available."
            return
        }

        surface.sendText(text)
        return
    }
}
