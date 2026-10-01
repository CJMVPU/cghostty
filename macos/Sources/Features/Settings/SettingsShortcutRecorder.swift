import AppKit

@MainActor protocol SettingsKeyCapture: AnyObject {
    func capture(_ event: NSEvent) -> Bool
}

final class SettingsShortcutRecorder: NSButton, SettingsKeyCapture {
    private let recorded: (String) -> Void
    private var recording = false
    private let status: (String) -> Void
    override var acceptsFirstResponder: Bool { true }

    init(recorded: @escaping (String) -> Void, status: @escaping (String) -> Void) {
        self.recorded = recorded
        self.status = status
        super.init(frame: .zero)
        cell = SettingsButtonCell(textCell: "Record")
        title = "Record"
        font = SettingsTypography.font
        bezelStyle = .rounded
        target = self
        action = #selector(beginRecording)
        setContentHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func beginRecording() {
        // Finish AppKit's button tracking before transferring keyboard focus.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isEnabled, self.window?.makeFirstResponder(self) == true else { return }
            self.stopRecording()
            self.recording = true
            self.title = "Press Keys"
            self.status("Press a shortcut. Escape cancels. Shortcuts reserved by other apps may interrupt recording.")
            NotificationCenter.default.addObserver(self, selector: #selector(self.recordingInterrupted), name: NSWindow.didResignKeyNotification, object: self.window)
            NotificationCenter.default.addObserver(self, selector: #selector(self.recordingInterrupted), name: NSApplication.didResignActiveNotification, object: NSApp)
        }
    }
    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }
    isolated deinit { NotificationCenter.default.removeObserver(self) }

    private func stopRecording() {
        recording = false
        title = "Record"
        toolTip = nil
        status("")
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSApplication.didResignActiveNotification, object: nil)
    }

    @objc private func recordingInterrupted() {
        guard recording else { return }
        stopRecording()
        status("Recording stopped because Settings lost focus. Try a shortcut that is not reserved by another app.")
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        capture(event) || super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if !capture(event) { super.keyDown(with: event) }
    }

    /// AppDelegate calls this before menu shortcuts. Otherwise combinations
    /// such as Command Shift K perform app actions instead of being recorded.
    func capture(_ event: NSEvent) -> Bool {
        guard recording, isEnabled, event.window == nil || event.window === window else { return false }
        record(event)
        return true
    }

    private func record(_ event: NSEvent) {
        if event.keyCode == 53 { stopRecording(); window?.makeFirstResponder(nil); return }
        guard let shortcut = SettingsShortcut.trigger(for: event) else {
            NSSound.beep()
            toolTip = "Enter this key in Advanced. Escape cancels recording."
            return
        }
        recorded(shortcut)
        stopRecording()
        window?.makeFirstResponder(nil)
    }
}

/// Key conversion has no recording or focus side effects.
enum SettingsShortcut {
    static func trigger(for event: NSEvent) -> String? {
        let specials: [UInt16: String] = [36: "enter", 48: "tab", 49: "space", 51: "backspace", 117: "delete",
                                         123: "left", 124: "right", 125: "down", 126: "up", 115: "home", 119: "end",
                                         116: "page_up", 121: "page_down",
                                         18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0"]
        let key = specials[event.keyCode] ?? event.charactersIgnoringModifiers?.lowercased() ?? ""
        guard specials[event.keyCode] != nil || (key.count == 1 && key.range(of: "^[a-z0-9]$", options: .regularExpression) != nil) else { return nil }
        var parts: [String] = []
        for (flag, name) in [(NSEvent.ModifierFlags.command, "super"), (.control, "ctrl"), (.option, "alt"), (.shift, "shift")] where event.modifierFlags.contains(flag) { parts.append(name) }
        parts.append(key)
        return parts.joined(separator: "+")
    }
}
