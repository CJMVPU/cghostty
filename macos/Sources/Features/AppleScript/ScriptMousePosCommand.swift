import AppKit

/// Handler for the `send mouse position` AppleScript command defined in `Ghostty.sdef`.
///
/// Cocoa scripting instantiates this class because the command's `<cocoa>` element
/// specifies `class="GhosttyScriptMousePosCommand"`. The runtime calls
/// `performDefaultImplementation()` to execute the command.
@MainActor
@objc(GhosttyScriptMousePosCommand)
final class ScriptMousePosCommand: ScriptSurfaceCommand {
    // Swift requires this explicit nonisolated override on each Cocoa subclass.
    nonisolated override init(commandDescription: NSScriptCommandDescription) {
        super.init(commandDescription: commandDescription)
    }

    override func performOnMainActor() {
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

        guard let surface = resolveSurface() else { return }

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
