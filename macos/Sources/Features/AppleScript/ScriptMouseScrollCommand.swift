import AppKit

/// Handler for the `send mouse scroll` AppleScript command defined in `Ghostty.sdef`.
///
/// Cocoa scripting instantiates this class because the command's `<cocoa>` element
/// specifies `class="GhosttyScriptMouseScrollCommand"`. The runtime calls
/// `performDefaultImplementation()` to execute the command.
@MainActor
@objc(GhosttyScriptMouseScrollCommand)
final class ScriptMouseScrollCommand: ScriptSurfaceCommand {
    // Swift requires this explicit nonisolated override on each Cocoa subclass.
    nonisolated override init(commandDescription: NSScriptCommandDescription) {
        super.init(commandDescription: commandDescription)
    }

    override func performOnMainActor() {
        guard let x = evaluatedArguments?["x"] as? Double else {
            scriptErrorNumber = errAEParamMissed
            scriptErrorString = "Missing x scroll delta."
            return
        }

        guard let y = evaluatedArguments?["y"] as? Double else {
            scriptErrorNumber = errAEParamMissed
            scriptErrorString = "Missing y scroll delta."
            return
        }

        guard let surface = resolveSurface() else { return }

        let precision = evaluatedArguments?["precision"] as? Bool ?? false

        let momentum: Ghostty.Input.Momentum
        if let momentumCode = evaluatedArguments?["momentum"] as? UInt32 {
            switch momentumCode {
            case "SMno".fourCharCode: momentum = .none
            case "SMbg".fourCharCode: momentum = .began
            case "SMch".fourCharCode: momentum = .changed
            case "SMen".fourCharCode: momentum = .ended
            case "SMcn".fourCharCode: momentum = .cancelled
            case "SMmb".fourCharCode: momentum = .mayBegin
            case "SMst".fourCharCode: momentum = .stationary
            default: momentum = .none
            }
        } else {
            momentum = .none
        }

        let scrollEvent = Ghostty.Input.MouseScrollEvent(
            x: x,
            y: y,
            mods: .init(precision: precision, momentum: momentum)
        )
        surface.sendMouseScroll(scrollEvent)

        return
    }
}
