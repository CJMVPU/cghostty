import AppKit

/// Handler for the `send mouse position` AppleScript command defined in `Ghostty.sdef`.
///
/// Cocoa scripting instantiates this class because the command's `<cocoa>` element
/// specifies `class="GhosttyScriptMousePosCommand"`. The runtime calls
/// `performDefaultImplementation()` to execute the command.
@MainActor
@objc(GhosttyScriptMousePosCommand)
final class ScriptMousePosCommand: NSScriptCommand {
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

        guard let x = evaluatedArguments?["x"] as? Double else {
            scriptErrorNumber = errAEParamMissed
            scriptErrorString = "Missing x position."
            return
        }

        guard let y = evaluatedArguments?["y"] as? Double else {
            scriptErrorNumber = errAEParamMissed
            scriptErrorString = "Missing y position."
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

        let mods: Ghostty.Input.Mods
        if let modsString = evaluatedArguments?["modifiers"] as? String {
            guard let parsed = Ghostty.Input.Mods(scriptModifiers: modsString) else {
                scriptErrorNumber = errAECoercionFail
                scriptErrorString = "Unknown modifier in: \(modsString)"
                return
            }
            mods = parsed
        } else {
            mods = []
        }

        let mousePosEvent = Ghostty.Input.MousePosEvent(
            x: x,
            y: y,
            mods: mods
        )
        surface.sendMousePos(mousePosEvent)

        return
    }
}
