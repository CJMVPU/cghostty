import AppKit

/// Cocoa scripting calls synchronously on the main thread. Keep that legacy
/// boundary in one place, with validation before any terminal mutation.
@MainActor
class ScriptSurfaceCommand: NSScriptCommand {
    nonisolated override init(commandDescription: NSScriptCommandDescription) {
        super.init(commandDescription: commandDescription)
    }

    nonisolated override func performDefaultImplementation() -> Any? {
        nonisolated(unsafe) let command = self
        MainActor.assumeIsolated {
            guard NSApp.validateScript(command: command) else { return }
            command.performOnMainActor()
        }
        return nil
    }

    func performOnMainActor() {
        preconditionFailure("A script command must implement its operation")
    }

    final func resolveSurface() -> Ghostty.Surface? {
        guard let terminal = evaluatedArguments?["terminal"] as? ScriptTerminal else {
            scriptErrorNumber = errAEParamMissed
            scriptErrorString = "Missing terminal target."
            return nil
        }
        guard let surfaceView = terminal.surfaceView else {
            scriptErrorNumber = errAEEventFailed
            scriptErrorString = "Terminal surface is no longer available."
            return nil
        }
        guard let surface = surfaceView.surfaceModel else {
            scriptErrorNumber = errAEEventFailed
            scriptErrorString = "Terminal surface model is not available."
            return nil
        }
        return surface
    }
}
