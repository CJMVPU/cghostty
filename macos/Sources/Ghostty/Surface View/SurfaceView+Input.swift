import AppKit

// Keyboard dispatch and NSTextInputClient share one native input boundary.
// Preserve ordering: key equivalents, IME interpretation, committed text, then core delivery.
extension Ghostty.SurfaceView {
    override func keyDown(with event: NSEvent) {
        guard let surface = self.surfaceModel else {
            self.interpretKeyEvents([event])
            return
        }

        // On any keyDown event we unset our bell state
        state.bell = false

        // We need to translate the mods (maybe) to handle configs such as option-as-alt
        let translationModsGhostty = surface.keyTranslationMods(.init(nsFlags: event.modifierFlags)).nsFlags

        // There are hidden bits set in our event that matter for certain dead keys
        // so we can't use translationModsGhostty directly. Instead, we just check
        // for exact states and set them.
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translationModsGhostty.contains(flag) {
                translationMods.insert(flag)
            } else {
                translationMods.remove(flag)
            }
        }

        // If the translation modifiers are not equal to our original modifiers
        // then we need to construct a new NSEvent. If they are equal we reuse the
        // old one. IMPORTANT: we MUST reuse the old event if they're equal because
        // this keeps things like Korean input working. There must be some object
        // equality happening in AppKit somewhere because this is required.
        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: translationMods,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            ) ?? event
        }

        let action: Ghostty.Input.Action = event.isARepeat ? .repeat : .press

        // By setting this to non-nil, we note that we're in a keyDown event. From here,
        // we call interpretKeyEvents so that we can handle complex input such as Korean
        // language.
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        // We need to know what the length of marked text was before this event to
        // know if these events cleared it.
        let markedTextBefore = markedText.length > 0

        // We need to know the keyboard layout before below because some keyboard
        // input events will change our keyboard layout and we don't want those
        // going to the terminal.
        let keyboardIdBefore: String? = if !markedTextBefore {
            KeyboardLayout.id
        } else {
            nil
        }

        // If we are in a keyDown then we don't need to redispatch a command-modded
        // key event (see docs for this field) so reset this to nil because
        // `interpretKeyEvents` may dispatch it.
        self.lastPerformKeyEvent = nil

        self.interpretKeyEvents([translationEvent])

        // If our keyboard changed from this we just assume an input method
        // grabbed it and do nothing.
        if !markedTextBefore && keyboardIdBefore != KeyboardLayout.id {
            return
        }

        // If we have marked text, we're in a preedit state. The order we
        // do this and the key event callbacks below doesn't matter since
        // we control the preedit state only through the preedit API.
        syncPreedit(clearIfNeeded: markedTextBefore)

        // We're composing if we have preedit (the obvious case). But we're also
        // composing if we don't have preedit and we had marked text before,
        // because this input probably just reset the preedit state. It shouldn't
        // be encoded. Example: Japanese begin composing, then press backspace
        // or ctrl+h. This should only cancel the composing state but not
        // actually delete the prior input characters (prior to the composing).
        let composing = markedText.length > 0 || markedTextBefore

        // The input method may commit all or part of the preedit text via
        // insertText while handling a key that should not itself be
        // encoded. Send that committed text separately, then only replay
        // keys that should still affect the terminal after committing.
        if markedTextBefore,
           let list = keyTextAccumulator,
           list.count > 0 {
            for text in list {
                if Ghostty.SurfaceView.shouldSuppressComposingControlInput(
                    text,
                    composing: composing
                ) {
                    continue
                }

                _ = committedTextAction(action, text: text)
            }

            if shouldReplayCommittedPreeditKey(translationEvent) {
                _ = keyAction(
                    action,
                    event: event,
                    translationEvent: translationEvent,
                    composing: false
                )
            }
            return
        }

        if let list = keyTextAccumulator, list.count > 0 {
            // Accumulated text from interpretKeyEvents (committed by the IME).
            for text in list {
                // Drop bare control characters the IME accumulated while
                // composing so they don't leak through to the terminal.
                if Ghostty.SurfaceView.shouldSuppressComposingControlInput(
                    text,
                    composing: composing
                ) {
                    continue
                }

                // We've composed a character; send it down. keyAction's
                // default composing=false applies because this is the
                // committed result of a composition, not in-progress preedit.
                _ = keyAction(
                    action,
                    event: event,
                    translationEvent: translationEvent,
                    text: text
                )
            }
        } else {
            // Raw control characters (e.g. ctrl+h) arriving during
            // composition belong to the IME, not the terminal.
            if Ghostty.SurfaceView.shouldSuppressComposingControlInput(
                event.characters,
                composing: composing
            ) {
                return
            }

            // We have no accumulated text so this is a normal key event.
            _ = keyAction(
                action,
                event: event,
                translationEvent: translationEvent,
                text: translationEvent.ghosttyCharacters,
                composing: composing
            )
        }
    }

    override func keyUp(with event: NSEvent) {
        _ = keyAction(.release, event: event)
    }

    /// Special case handling for some control keys
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // We only care about key down events. It might not even be possible
        // to receive any other event type here.
        guard event.type == .keyDown else { return false }

        // Only process events if we're focused. Some key events like C-/ macOS
        // appears to send to the first view in the hierarchy rather than the
        // the first responder (I don't know why). This prevents us from handling it.
        // Besides C-/, its important we don't process key equivalents if unfocused
        // because there are other event listeners for that (i.e. AppDelegate's
        // local event handler).
        if !focused {
            return false
        }

        // Get information about if this is a binding.
        let bindingFlags = surfaceModel?.keyIsBinding(
            event.terminalKeyEvent(.press, text: event.characters ?? ""))

        // If this is a binding then we want to perform it.
        if let bindingFlags {
            // Attempt to trigger a menu item for this key binding. We only do this if:
            //   - We're not in a key sequence or table (those are separate bindings)
            //   - The binding is NOT `all` (menu uses FirstResponder chain)
            //   - The binding is NOT `performable` (menu will always consume)
            //   - The binding is `consumed` (unconsumed bindings should pass through
            //     to the terminal, so we must not intercept them for the menu)
            if keySequence.isEmpty,
               keyTables.isEmpty,
               bindingFlags.isDisjoint(with: [.all, .performable]),
               bindingFlags.contains(.consumed) {
                if let appDelegate = windowRegistry.owner(of: self)?.ghostty.delegate as? AppDelegate,
                   appDelegate.performGhosttyBindingMenuKeyEquivalent(with: event) {
                    return true
                }
            }

            self.keyDown(with: event)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            // Pass C-<return> through verbatim
            // (prevent the default context menu equivalent)
            if !event.modifierFlags.contains(.control) {
                return false
            }

            equivalent = "\r"

        case "/":
            // Treat C-/ as C-_. We do this because C-/ makes macOS make a beep
            // sound and we don't like the beep sound.
            if !event.modifierFlags.contains(.control) ||
                !event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) {
                return false
            }

            equivalent = "_"

        default:
            // It looks like some part of AppKit sometimes generates synthetic NSEvents
            // with a zero timestamp. We never process these at this point. Concretely,
            // this happens for me when pressing Cmd+period with default bindings. This
            // binds to "cancel" which goes through AppKit to produce a synthetic "escape".
            //
            // Question: should we be ignoring all synthetic events? Should we be finding
            // synthetic escape and ignoring it? I feel like Cmd+period could map to a
            // escape binding by accident, but it hasn't happened yet...
            if event.timestamp == 0 {
                return false
            }

            // All of this logic here re: lastCommandEvent is to workaround some
            // nasty behavior. See the docs for lastCommandEvent for more info.

            // Ignore all other non-command events. This lets the event continue
            // through the AppKit event systems.
            if !event.modifierFlags.contains(.command) &&
                !event.modifierFlags.contains(.control) {
                // Reset since we got a non-command event.
                lastPerformKeyEvent = nil
                return false
            }

            // If we have a prior command binding and the timestamp matches exactly
            // then we pass it through to keyDown for encoding.
            if let lastPerformKeyEvent {
                self.lastPerformKeyEvent = nil
                if lastPerformKeyEvent == event.timestamp {
                    equivalent = event.characters ?? ""
                    break
                }
            }

            lastPerformKeyEvent = event.timestamp
            return false
        }

        let finalEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: equivalent,
            charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        )

        self.keyDown(with: finalEvent!)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = Ghostty.Input.Mods.caps.rawValue
        case 0x38, 0x3C: mod = Ghostty.Input.Mods.shift.rawValue
        case 0x3B, 0x3E: mod = Ghostty.Input.Mods.ctrl.rawValue
        case 0x3A, 0x3D: mod = Ghostty.Input.Mods.alt.rawValue
        case 0x37, 0x36: mod = Ghostty.Input.Mods.super.rawValue
        default: return
        }

        // If we're in the middle of a preedit, don't do anything with mods.
        if hasMarkedText() { return }

        // The keyAction function will do this AGAIN below which sucks to repeat
        // but this is super cheap and flagsChanged isn't that common.
        let mods = Ghostty.Input.Mods(nsFlags: event.modifierFlags)

        // If the key that pressed this is active, its a press, else release.
        var action: Ghostty.Input.Action = .release
        if mods.rawValue & mod != 0 {
            // If the key is pressed, its slightly more complicated, because we
            // want to check if the pressed modifier is the correct side. If the
            // correct side is pressed then its a press event otherwise its a release
            // event with the opposite modifier still held.
            let sidePressed: Bool
            switch event.keyCode {
            case 0x3C:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
            default:
                sidePressed = true
            }

            if sidePressed {
                action = .press
            }
        }

        _ = keyAction(action, event: event)
    }

    func keyAction(
        _ action: Ghostty.Input.Action,
        event: NSEvent,
        translationEvent: NSEvent? = nil,
        text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        guard let surface = self.surfaceModel else { return false }

        return surface.sendKeyEvent(event.terminalKeyEvent(
            action, translationMods: translationEvent?.modifierFlags,
            text: text?.keyEventText, composing: composing))
    }

    private func shouldReplayCommittedPreeditKey(_ event: NSEvent) -> Bool {
        guard let key = Ghostty.Input.Key(keyCode: event.keyCode) else { return false }
        switch key {
        case .arrowDown, .arrowRight, .arrowUp:
            return true
        case .arrowLeft:
            // Don't replay plain left-arrow because AppKit already leaves
            // the caret in place after Korean IMEs commit preedit text.
            return !event.modifierFlags.isDisjoint(with: [.shift, .control, .option, .command])
        default:
            return false
        }
    }

    private func committedTextAction(
        _ action: Ghostty.Input.Action,
        text: String
    ) -> Bool {
        guard let surface = self.surfaceModel else { return false }

        return surface.sendKeyEvent(.init(keyCode: 0, action: action, text: text))
    }

}

// MARK: - NSTextInputClient

extension Ghostty.SurfaceView: NSTextInputClient {
    func hasMarkedText() -> Bool {
        return markedText.length > 0
    }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange() }
        return NSRange(0...(markedText.length-1))
    }

    func selectedRange() -> NSRange {
        guard let surface = self.surfaceModel else { return NSRange() }

        // Get our range from the Ghostty API. There is a race condition between getting the
        // range and actually using it since our selection may change but there isn't a good
        // way I can think of to solve this for AppKit.
        guard let text = surface.selection else { return NSRange() }
        return text.range
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString:
            self.markedText = NSMutableAttributedString(attributedString: v)

        case let v as String:
            self.markedText = NSMutableAttributedString(string: v)

        default:
            print("unknown marked text: \(string)")
        }

        // If we're not in a keyDown event, then we want to update our preedit
        // text immediately. This can happen due to external events, for example
        // changing keyboard layouts while composing: (1) set US intl (2) type '
        // to enter dead key state (3)
        if keyTextAccumulator == nil {
            syncPreedit()
        }
    }

    func unmarkText() {
        if self.markedText.length > 0 {
            self.markedText.mutableString.setString("")
            syncPreedit()
        }
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        return []
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        // Ghostty.logger.warning("pressure substring range=\(range) selectedRange=\(self.selectedRange())")
        guard let surface = self.surfaceModel else { return nil }

        // If the range is empty then we don't need to return anything
        guard range.length > 0 else { return nil }

        // I used to do a bunch of testing here that the range requested matches the
        // selection range or contains it but a lot of macOS system behaviors request
        // bogus ranges I truly don't understand so we just always return the
        // attributed string containing our selection which is... weird but works?

        // Get our selection text
        guard let text = surface.selection else { return nil }

        // If we can get a font then we use the font. This should always work
        // since we always have a primary font. The only scenario this doesn't
        // work is if someone is using a non-CoreText build which would be
        // unofficial.
        var attributes: [ NSAttributedString.Key: Any ] = [:]
        if let font = surface.font {
            attributes[.font] = font
        }

        return .init(string: text.text, attributes: attributes)
    }

    func characterIndex(for point: NSPoint) -> Int {
        return 0
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface = self.surfaceModel else {
            return NSRect(x: frame.origin.x, y: frame.origin.y, width: 0, height: 0)
        }

        // Ghostty will tell us where it thinks an IME keyboard should render.
        var x: Double = 0
        var y: Double = 0
        var width: Double = cellSize.width
        var height: Double = cellSize.height

        // QuickLook never gives us a matching range to our selection so if we detect
        // this then we return the top-left selection point rather than the cursor point.
        // This is hacky but I can't think of a better way to get the right IME vs. QuickLook
        // point right now. I'm sure I'm missing something fundamental...
        if range.length > 0 && range != self.selectedRange() {
            // QuickLook
            if let text = surface.selection {
                // The -2/+2 here is subjective. QuickLook seems to offset the rectangle
                // a bit and I think these small adjustments make it look more natural.
                x = text.topLeft.x - 2
                y = text.topLeft.y + 2
            } else {
                let point = surface.imePoint
                (x, y, width, height) = (point.origin.x, point.origin.y, point.width, point.height)
            }
        } else {
            let point = surface.imePoint
            (x, y, width, height) = (point.origin.x, point.origin.y, point.width, point.height)
        }
        if range.length == 0, width > 0 {
            // This fixes #8493 while speaking
            // My guess is that positive width doesn't make sense
            // for the dictation microphone indicator
            width = 0
            x += cellSize.width * Double(range.location + range.length)
        }
        // Ghostty coordinates are in top-left (0, 0) so we have to convert to
        // bottom-left since that is what AppKit expects
        // when there's is no characters selected,
        // width should be 0 so that dictation indicator
        // can start in the right place
        let viewRect = NSRect(
            x: x,
            y: frame.size.height - y,
            width: width,
            height: max(height, cellSize.height))

        // Convert the point to the window coordinates
        let winRect = self.convert(viewRect, to: nil)

        // Convert from view to screen coordinates
        guard let window = self.window else { return winRect }
        return window.convertToScreen(winRect)
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        // We must have an associated event
        guard NSApp.currentEvent != nil else { return }

        // We want the string view of the any value
        var chars = ""
        switch string {
        case let v as NSAttributedString:
            chars = v.string
        case let v as NSString:
            if let leadSurrogate = LeadSurrogate(v) {
                self.leadSurrogate = leadSurrogate
                chars = ""
            } else if let trail = TrailSurrogate(v) {
                // We ignore trail surrogate without a lead like Terminal.app.
                chars = leadSurrogate?.encode(trail: trail) ?? ""
                leadSurrogate = nil
            } else {
                chars = v as String
                // Clear whenever other text got inserted.
                // Ideally we should encode any adjacent lead and trail surrogate into one,
                // but getting the cursor position and reading could be rather expensive to do.
                leadSurrogate = nil
            }
        default:
            return
        }

        // If insertText is called, our preedit must be over.
        unmarkText()

        // If we have an accumulator we're in another key event so we just
        // accumulate and return.
        if var acc = keyTextAccumulator {
            acc.append(chars)
            keyTextAccumulator = acc
            return
        }

        // All committed text (IME, dictation, etc.) must be sent as key
        // events so programs treat it as typed input, never as a paste.
        if !chars.isEmpty {
            _ = committedTextAction(.press, text: chars)
        }
    }

    /// This function needs to exist for two reasons:
    /// 1. Prevents an audible NSBeep for unimplemented actions.
    /// 2. Allows us to properly encode super+key input events that we don't handle
    override func doCommand(by selector: Selector) {
        // If we are being processed by performKeyEquivalent with a command binding,
        // we send it back through the event system so it can be encoded.
        if let lastPerformKeyEvent,
           let current = NSApp.currentEvent,
           lastPerformKeyEvent == current.timestamp {
            NSApp.sendEvent(current)
        }
    }

    /// Sync the preedit state based on the markedText value to libghostty
    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface = surfaceModel else { return }

        if markedText.length > 0 {
            surface.setPreedit(markedText.string)
        } else if clearIfNeeded {
            surface.setPreedit(nil)
        }
    }

    /// True when `text` is a single C0 control character (U+0000-U+001F)
    /// arriving while the IME is composing. Such input belongs to the IME
    /// and must not be forwarded to the terminal.
    static func shouldSuppressComposingControlInput(
        _ text: String?,
        composing: Bool
    ) -> Bool {
        guard composing, let text else { return false }
        let scalars = text.unicodeScalars
        guard let scalar = scalars.first,
              scalars.index(after: scalars.startIndex) == scalars.endIndex else {
            return false
        }
        return scalar.value < 0x20
    }
}

