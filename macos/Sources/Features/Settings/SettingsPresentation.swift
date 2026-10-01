import AppKit

extension SettingsField {
    var isVisible: Bool { !["maximize", "fullscreen"].contains(key) }
    var isFontStyle: Bool { key == "font-style" || key.hasPrefix("font-style-") }
    var isColor: Bool {
        ["background", "foreground", "cursor-color", "cursor-text", "selection-foreground", "selection-background",
         "search-foreground", "search-background", "search-selected-foreground", "search-selected-background",
         "unfocused-split-fill", "split-divider-color", "bold-color"].contains(key)
    }
    var colorModes: [String] {
        if key == "bold-color" { return ["", "bright"] }
        if key.hasPrefix("cursor-") || key.hasPrefix("selection-") || key.hasPrefix("search-") {
            return ["", "cell-foreground", "cell-background"]
        }
        return [""]
    }
    var isPath: Bool { ["working-directory", "background-image", "bell-audio-path", "render-trace-directory"].contains(key) }
    var isDirectory: Bool { key == "working-directory" || key == "render-trace-directory" }
    var isDuration: Bool { ["undo-timeout", "resize-overlay-duration", "notify-on-command-finish-after"].contains(key) }
    var isLimit: Bool { ["scrollback-limit-bytes", "scrollback-limit-lines", "clipboard-write-limit-bytes"].contains(key) }
    var isPairList: Bool {
        ["env", "keybind", "key-remap", "clipboard-codepoint-map", "font-codepoint-map"].contains(key) || key.hasPrefix("font-variation")
    }
    var unitLabel: String? {
        switch key {
        case "window-width": return "columns"
        case "window-height": return "rows"
        case "font-size": return "pt"
        case "abnormal-command-exit-runtime", "click-repeat-interval": return "ms"
        case "quick-terminal-animation-duration": return "seconds"
        case "image-storage-limit": return "bytes"
        default: return nil
        }
    }
    var section: String {
        guard group == 2 else { return "" }
        if key.hasPrefix("cursor-") { return "Cursor" }
        if key == "font-family" || key == "font-size" || key.hasPrefix("font-thicken") { return "Font" }
        if key.hasPrefix("font-") || key.hasPrefix("adjust-") || key == "alpha-blending" { return "Advanced Typography" }
        return "Colors"
    }
    @MainActor func matches(_ query: String) -> Bool {
        let searchable = "\(title) \(key) \(help) \(choices.map(Self.choiceTitle).joined(separator: " ")) \(flags.joined(separator: " "))"
        return query.split(whereSeparator: \.isWhitespace).allSatisfy { searchable.localizedCaseInsensitiveContains($0) }
    }
}

/// Small controls share typography, sizing and accessibility conventions.
@MainActor func settingsInput(_ value: String, id: String, delegate: NSTextFieldDelegate) -> NSTextField {
    let input = NSTextField()
    input.cell = SettingsTextCell(textCell: "")
    input.stringValue = value
    input.font = SettingsTypography.font
    input.textColor = .white
    input.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 1)
    input.isEditable = true
    input.isSelectable = true
    input.isBezeled = true
    input.drawsBackground = true
    input.delegate = delegate
    input.heightAnchor.constraint(equalToConstant: 32).isActive = true
    input.setAccessibilityIdentifier(id)
    return input
}

final class SettingsComboBox: NSComboBox {
    override func draw(_ dirtyRect: NSRect) { SettingsTypography.draw { super.draw(dirtyRect) } }
}

/// These editors serialize through the existing configuration parser. Opening an
/// editor never normalizes or writes its value; only an explicit edit does.
class SettingsValueEditor: NSStackView {
    var controls: [NSControl] = []
    var headingControl: NSControl? { nil }
    func setEnabled(_ enabled: Bool) { controls.forEach { $0.isEnabled = enabled } }
    func refresh(context: [String: String]) {}
}
