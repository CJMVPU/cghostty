import AppKit

/// Handler for the `send key` AppleScript command defined in `Ghostty.sdef`.
///
/// Cocoa scripting instantiates this class because the command's `<cocoa>` element
/// specifies `class="GhosttyScriptKeyEventCommand"`. The runtime calls
/// `performDefaultImplementation()` to execute the command.
@MainActor
@objc(GhosttyScriptKeyEventCommand)
final class ScriptKeyEventCommand: ScriptSurfaceCommand {
    // Swift requires this explicit nonisolated override on each Cocoa subclass.
    nonisolated override init(commandDescription: NSScriptCommandDescription) {
        super.init(commandDescription: commandDescription)
    }

    override func performOnMainActor() {
        guard let surface = resolveSurface() else { return }

        let keyEvent: Ghostty.Input.KeyEvent
        do {
            keyEvent = try Self.parse(
                directParameter: directParameter,
                evaluatedArguments: evaluatedArguments,
                translationMods: surface.keyTranslationMods,
            )
        } catch ArgumentError.missingKey {
            scriptErrorNumber = errAEParamMissed
            scriptErrorString = "Missing key name."
            return
        } catch let ArgumentError.unknownKey(keyName) {
            scriptErrorNumber = errAECoercionFail
            scriptErrorString = "Unknown key name: \(keyName)"
            return
        } catch let ArgumentError.unknownModifiers(modsString) {
            scriptErrorNumber = errAECoercionFail
            scriptErrorString = "Unknown modifier in: \(modsString)"
            return
        } catch {
            scriptErrorNumber = errAEEventFailed
            scriptErrorString = "Invalid key event."
            return
        }

        surface.sendKeyEvent(keyEvent)

        return
    }
}

extension ScriptKeyEventCommand {
    enum ArgumentError: Error, Equatable {
        case missingKey
        case unknownKey(String)
        case unknownModifiers(String)
    }

    /// Parse the scripting arguments for `send key` into the key event to
    /// deliver to the surface.
    ///
    /// - Parameters:
    ///   - directParameter: The command's direct parameter (the key name).
    ///   - evaluatedArguments: The command's evaluated arguments.
    ///   - translationMods: Maps the event's modifiers to the subset that
    ///     participates in text translation for the target surface.
    static func parse(
        directParameter: Any?,
        evaluatedArguments: [String: Any]?,
        translationMods: (Ghostty.Input.Mods) -> Ghostty.Input.Mods = { $0 },
    ) throws -> Ghostty.Input.KeyEvent {
        guard let keyName = directParameter as? String else {
            throw ArgumentError.missingKey
        }

        guard let key = Ghostty.Input.Key(rawValue: keyName) else {
            throw ArgumentError.unknownKey(keyName)
        }

        let action: Ghostty.Input.Action
        if let actionCode = evaluatedArguments?["action"] as? UInt32 {
            switch actionCode {
            case "GIpr".fourCharCode: action = .press
            case "GIrl".fourCharCode: action = .release
            default: action = .press
            }
        } else {
            action = .press
        }

        let mods: Ghostty.Input.Mods
        if let modsString = evaluatedArguments?["modifiers"] as? String {
            guard let parsed = Ghostty.Input.Mods(scriptModifiers: modsString) else {
                throw ArgumentError.unknownModifiers(modsString)
            }
            mods = parsed
        } else {
            mods = []
        }

        return Ghostty.Input.KeyEvent(
            synthesizing: key,
            action: action,
            mods: mods,
            translationMods: translationMods(mods),
        )
    }
}
