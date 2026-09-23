import AppKit

/// Handler for the `input text` AppleScript command defined in `Ghostty.sdef`.
///
/// Cocoa scripting instantiates this class because the command's `<cocoa>` element
/// specifies `class="GhosttyScriptInputTextCommand"`. The runtime calls
/// `performDefaultImplementation()` to execute the command.
@MainActor
@objc(GhosttyScriptInputTextCommand)
final class ScriptInputTextCommand: ScriptSurfaceCommand {
    // Swift requires this explicit nonisolated override on each Cocoa subclass.
    nonisolated override init(commandDescription: NSScriptCommandDescription) {
        super.init(commandDescription: commandDescription)
    }

    override func performOnMainActor() {
        guard let text = directParameter as? String else {
            scriptErrorNumber = errAEParamMissed
            scriptErrorString = "Missing text to input."
            return
        }

        guard let surface = resolveSurface() else { return }

        surface.sendText(text)
        return
    }
}
