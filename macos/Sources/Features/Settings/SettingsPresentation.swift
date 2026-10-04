import AppKit

/// UI policy is centralized here; parsing and final validation stay in the core.
struct SettingsPresentation {
    enum Editor { case scalar, theme, fontFamily, fontStyle, color, path, duration, limit, quickSize, blur, flags, list }

    let editor: Editor
    let inline: Bool
    let width: CGFloat?
    let unit: String?
    let section: String
    let visible: Bool
    let pairList: Bool
    let directory: Bool
    let colorModes: [String]

    private static let colors: Set<String> = [
        "background", "foreground", "cursor-color", "cursor-text", "selection-foreground", "selection-background",
        "search-foreground", "search-background", "search-selected-foreground", "search-selected-background",
        "unfocused-split-fill", "split-divider-color", "bold-color"
    ]
    private static let specialized: [String: Editor] = [
        "theme": .theme,
        "working-directory": .path, "background-image": .path, "bell-audio-path": .path, "render-trace-directory": .path,
        "undo-timeout": .duration, "resize-overlay-duration": .duration, "notify-on-command-finish-after": .duration,
        "scrollback-limit-bytes": .limit, "scrollback-limit-lines": .limit, "clipboard-write-limit-bytes": .limit,
        "quick-terminal-size": .quickSize, "background-blur": .blur
    ]
    private static let units = [
        "window-width": "columns", "window-height": "rows", "font-size": "pt",
        "abnormal-command-exit-runtime": "ms", "click-repeat-interval": "ms",
        "quick-terminal-animation-duration": "seconds", "image-storage-limit": "bytes"
    ]

    init(_ field: SettingsField) {
        let key = field.key
        pairList = ["env", "keybind", "key-remap", "clipboard-codepoint-map", "font-codepoint-map"].contains(key) || key.hasPrefix("font-variation")
        if key == "window-title-font-family" || key == "font-family" || key.hasPrefix("font-family-") { editor = .fontFamily } else if !field.flags.isEmpty { editor = .flags } else if key == "font-style" || key.hasPrefix("font-style-") { editor = .fontStyle } else if Self.colors.contains(key) { editor = .color } else if let specialized = Self.specialized[key] { editor = specialized } else if field.multiline || pairList { editor = .list } else { editor = .scalar }
        inline = [.fontStyle, .color, .duration, .limit, .blur].contains(editor)
        width = editor == .scalar && (field.kind == "integer" || field.kind == "number" || key.hasPrefix("adjust-") ||
            ["window-padding-x", "window-padding-y"].contains(key)) ? 160 : nil
        unit = Self.units[key]
        visible = !["maximize", "fullscreen"].contains(key)
        directory = key == "working-directory" || key == "render-trace-directory"
        if key == "bold-color" { colorModes = ["", "bright"] } else if key.hasPrefix("cursor-") || key.hasPrefix("selection-") || key.hasPrefix("search-") {
            colorModes = ["", "cell-foreground", "cell-background"]
        } else { colorModes = [""] }
        if field.group != 2 { section = "" } else if key.hasPrefix("cursor-") { section = "Cursor" } else if key == "font-family" || key == "font-size" || key.hasPrefix("font-thicken") { section = "Font" } else if key.hasPrefix("font-") || key.hasPrefix("adjust-") || key == "alpha-blending" { section = "Advanced Typography" } else { section = "Colors" }
    }
}

@MainActor extension SettingsField {
    static func visibleFields(category: Int, query: String) -> [SettingsField] {
        let pinned = ["initial-window", "quit-after-last-window-closed", "window-width", "window-height"]
        return catalog.filter {
            $0.isVisible && (query.isEmpty ? ($0.group == category || (category == 1 && pinned.contains($0.key))) : $0.matches(query))
        }.sorted {
            (pinned.firstIndex(of: $0.key) ?? 1000) < (pinned.firstIndex(of: $1.key) ?? 1000)
        }
    }

    @MainActor private static let presentations = Dictionary(uniqueKeysWithValues: catalog.map { ($0.key, SettingsPresentation($0)) })
    @MainActor var presentation: SettingsPresentation { Self.presentations[key] ?? SettingsPresentation(self) }
    var isVisible: Bool { presentation.visible }
    var isFontFamily: Bool { presentation.editor == .fontFamily }
    var isFontStyle: Bool { presentation.editor == .fontStyle }
    var isColor: Bool { presentation.editor == .color }
    var colorModes: [String] { presentation.colorModes }
    var isPath: Bool { presentation.editor == .path }
    var isDirectory: Bool { presentation.directory }
    var isDuration: Bool { presentation.editor == .duration }
    var isLimit: Bool { presentation.editor == .limit }
    var isPairList: Bool { presentation.pairList }
    var unitLabel: String? { presentation.unit }
    var section: String { presentation.section }
    @MainActor private static let searchIndex = Dictionary(uniqueKeysWithValues: catalog.map { ($0.key, $0.searchText) })
    @MainActor private var searchText: String {
        "\(title) \(key) \(help) \(choices.map(Self.choiceTitle).joined(separator: " ")) \(flags.joined(separator: " "))"
    }
    @MainActor func matches(_ query: String) -> Bool {
        let searchable = Self.searchIndex[key] ?? searchText
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
    input.focusRingType = .none
    input.isEditable = true
    input.isSelectable = true
    input.isBezeled = true
    input.drawsBackground = true
    input.delegate = delegate
    input.heightAnchor.constraint(equalToConstant: 30).isActive = true
    input.setAccessibilityIdentifier(id)
    return input
}

final class SettingsComboBox: NSComboBox {
    override init(frame: NSRect) { super.init(frame: frame); focusRingType = .none }
    required init?(coder: NSCoder) { super.init(coder: coder); focusRingType = .none }
    override func draw(_ dirtyRect: NSRect) { SettingsTypography.draw { super.draw(dirtyRect) } }
}

/// These editors serialize through the existing configuration parser. Opening an
/// editor never normalizes or writes its value; only an explicit edit does.
class SettingsValueEditor: NSStackView {
    var controls: [NSControl] = []
    var headingControl: NSControl? { nil }
    func setEnabled(_ enabled: Bool) { controls.forEach { $0.isEnabled = enabled; $0.focusRingType = .none } }
    func refresh(context: [String: String]) {}
}
