import AppKit

/// Independent of terminal preferences. The native face comes from the same
/// embedded font bytes; no installed font or terminal config is required.
@MainActor enum SettingsTypography {
    static let size: CGFloat = 16
    static let thicken = true
    static let strength: UInt8 = 255
    static let font = Ghostty.SettingsBridge.font(size: size)

    /// Match the CoreText thickening switch used by the terminal. At 255 the
    /// glyph coverage has full intensity; it is not an NSFont weight of 255.
    static func draw(_ body: () -> Void) {
        guard let context = NSGraphicsContext.current?.cgContext else { body(); return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setAllowsFontSmoothing(true)
        context.setShouldSmoothFonts(thicken)
        context.setAllowsFontSubpixelPositioning(true)
        context.setShouldSubpixelPositionFonts(true)
        context.setAllowsFontSubpixelQuantization(false)
        context.setShouldSubpixelQuantizeFonts(false)
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setAlpha(CGFloat(strength) / 255)
        body()
    }
}

final class SettingsTextCell: NSTextFieldCell {
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        SettingsTypography.draw { super.drawInterior(withFrame: cellFrame, in: controlView) }
    }
}

final class SettingsTextView: NSTextView {
    func configurePlainText() {
        isRichText = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        writingToolsBehavior = .none
        allowsUndo = true
    }

    override func draw(_ dirtyRect: NSRect) {
        SettingsTypography.draw { super.draw(dirtyRect) }
    }
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }
}

final class SettingsButtonCell: NSButtonCell {
    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        var result = frame
        SettingsTypography.draw { result = super.drawTitle(title, withFrame: frame, in: controlView) }
        return result
    }
}

final class SettingsButton: NSButton {
    var handler: () -> Void = {}
    init(_ title: String, handler: @escaping () -> Void) {
        super.init(frame: .zero)
        cell = SettingsButtonCell(textCell: title)
        self.title = title
        self.handler = handler
        font = SettingsTypography.font
        bezelStyle = .rounded
        target = self
        action = #selector(activate)
        setContentHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func activate() { handler() }
}

@MainActor func settingsLabel(_ text: String, muted: Bool = false) -> NSTextField {
    let label = NSTextField(frame: .zero)
    label.cell = SettingsTextCell(textCell: text)
    label.stringValue = text
    label.font = SettingsTypography.font
    label.textColor = muted ? NSColor(calibratedWhite: 0.67, alpha: 1) : .white
    label.isEditable = false
    label.isSelectable = true
    label.isBordered = false
    label.drawsBackground = false
    label.maximumNumberOfLines = 0
    label.lineBreakMode = .byWordWrapping
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
}
