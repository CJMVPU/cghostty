import AppKit
import QuartzCore

/// A fixed hit target with an independently animated metal face.
final class TerminalChromeButton: NSButton {
    enum Kind { case drag, minimize, close, tab(Int) }
    let kind: Kind
    private let actionHandler: () -> Void
    private let base = CAGradientLayer()
    private let face = CAGradientLayer()
    private let grain = CAShapeLayer()
    private let bevel = CAShapeLayer()
    private let symbol = CAShapeLayer()
    private let number = CATextLayer()
    private var hoverArea: NSTrackingArea?
    private var hovered = false
    private var pressed = false
    var active = false { didSet { if active != oldValue { updateSymbol() } } }

    init(kind: Kind, label: String, action: @escaping () -> Void) {
        self.kind = kind
        actionHandler = action
        super.init(frame: .zero)
        title = label
        isBordered = false
        focusRingType = .none
        setAccessibilityLabel(label)
        toolTip = label
        target = self
        self.action = #selector(activate)
        wantsLayer = true
        layer?.addSublayer(base)
        layer?.addSublayer(face)
        base.cornerRadius = 4
        base.colors = [NSColor(white: 0.12, alpha: 1).cgColor, NSColor(white: 0.055, alpha: 1).cgColor]
        base.startPoint = CGPoint(x: 0.5, y: 1)
        base.endPoint = CGPoint(x: 0.5, y: 0)
        face.cornerRadius = 4
        face.startPoint = base.startPoint
        face.endPoint = base.endPoint
        face.shadowColor = NSColor.black.cgColor
        face.shadowOffset = CGSize(width: 0, height: -1)
        [grain, bevel, symbol, number].forEach(face.addSublayer)
        grain.strokeColor = NSColor(white: 1, alpha: 0.035).cgColor
        grain.fillColor = nil
        bevel.fillColor = nil
        number.alignmentMode = .center
        number.isHidden = true
        updateAppearance(duration: 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func accessibilityValue() -> Any? {
        if case .tab = kind { return active ? "Selected" : "" }
        return super.accessibilityValue()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let scale = window?.backingScaleFactor ?? 2
        [base, face, grain, bevel, symbol, number].forEach { $0.contentsScale = scale }
        base.frame = NSRect(x: 1, y: 1, width: bounds.width - 2, height: bounds.height - 3)
        // Two points of side wall and one point of hover travel fit inside 25 x 25.
        face.bounds = NSRect(x: 0, y: 0, width: bounds.width - 2, height: bounds.height - 5)
        face.position = NSPoint(x: bounds.midX, y: 3 + face.bounds.midY)
        face.borderWidth = 1 / scale
        face.shadowPath = CGPath(roundedRect: face.bounds, cornerWidth: 4, cornerHeight: 4, transform: nil)
        let lines = CGMutablePath()
        for y in stride(from: CGFloat(3), through: face.bounds.height - 3, by: 1.5) {
            lines.move(to: CGPoint(x: 3, y: y))
            lines.addLine(to: CGPoint(x: face.bounds.width - 3, y: y))
        }
        grain.path = lines
        grain.lineWidth = 1 / scale
        let edge = CGMutablePath()
        edge.move(to: CGPoint(x: 0.75, y: 4))
        edge.addLine(to: CGPoint(x: 0.75, y: face.bounds.height - 4))
        edge.addQuadCurve(to: CGPoint(x: 4, y: face.bounds.height - 0.75), control: CGPoint(x: 0.75, y: face.bounds.height - 0.75))
        edge.addLine(to: CGPoint(x: face.bounds.width - 4, y: face.bounds.height - 0.75))
        bevel.path = edge
        bevel.lineWidth = 1 / scale
        updateSymbol()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hovered = false
        pressed = false
        updateAppearance(duration: 0)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func resetCursorRects() {
        if case .drag = kind { addCursorRect(bounds, cursor: .openHand) }
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        updateAppearance(duration: 0.12)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        updateAppearance(duration: 0.16)
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        updateAppearance(duration: 0.07)
        defer {
            pressed = false
            hovered = window.map { bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
            updateAppearance(duration: 0.1)
        }
        if case .drag = kind {
            NSCursor.closedHand.push()
            defer { NSCursor.pop() }
            window?.performDrag(with: event)
        } else { super.mouseDown(with: event) }
    }

    @objc private func activate() { actionHandler() }

    // The face layers render the button; suppress NSButton's default cell drawing.
    override func draw(_ dirtyRect: NSRect) {}

    private func updateAppearance(duration: TimeInterval) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration = reduceMotion ? 0 : duration
        let isTab: Bool = if case .tab = kind { true } else { false }
        let color = isTab ? NSColor(calibratedRed: 0.12, green: 0.19, blue: 0.23, alpha: 1) : NSColor(white: 0.19, alpha: 1)
        let light = color.blended(withFraction: hovered ? 0.26 : 0.18, of: .white) ?? color
        let dark = color.blended(withFraction: 0.12, of: .black) ?? color
        animate(face, "colors", to: [light.cgColor, dark.cgColor], duration: duration)
        animate(face, "transform.translation.y", to: reduceMotion ? 0.0 : (pressed ? -1.0 : (hovered ? 1.0 : 0.0)), duration: duration)
        animate(face, "shadowOpacity", to: pressed ? 0.2 : (hovered ? 0.7 : 0.45), duration: duration)
        animate(face, "shadowRadius", to: pressed ? 0.5 : (hovered ? 2.0 : 1.0), duration: duration)
        animate(face, "borderColor", to: NSColor(white: hovered ? 0.48 : 0.34, alpha: 1).cgColor, duration: duration)
        animate(bevel, "strokeColor", to: NSColor(white: 1, alpha: hovered ? 0.5 : 0.3).cgColor, duration: duration)
        updateSymbol()
    }

    private func updateSymbol() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let color: NSColor
        if case .close = kind, hovered {
            color = NSColor(calibratedRed: 1, green: 0.55, blue: 0.48, alpha: 1)
        } else {
            color = active ? NSColor(calibratedRed: 0.65, green: 0.88, blue: 0.32, alpha: 1) : NSColor(white: 0.86, alpha: 1)
        }
        symbol.fillColor = color.cgColor
        let rect = face.bounds
        let path = CGMutablePath()
        switch kind {
        case .drag:
            for row in 0..<2 {
                for column in 0..<3 {
                    path.addEllipse(in: CGRect(x: rect.midX - 6 + CGFloat(column) * 5,
                                               y: rect.midY - 3.5 + CGFloat(row) * 5, width: 2, height: 2))
                }
            }
        case .minimize:
            path.addRect(CGRect(x: rect.midX - 5, y: rect.midY - 0.75, width: 10, height: 1.5))
        case .close:
            path.move(to: CGPoint(x: rect.midX - 3.5, y: rect.midY - 3.5))
            path.addLine(to: CGPoint(x: rect.midX + 3.5, y: rect.midY + 3.5))
            path.move(to: CGPoint(x: rect.midX - 3.5, y: rect.midY + 3.5))
            path.addLine(to: CGPoint(x: rect.midX + 3.5, y: rect.midY - 3.5))
            symbol.strokeColor = color.cgColor
            symbol.lineWidth = 1.5
            symbol.lineCap = .round
        case .tab(let index):
            let text = NSAttributedString(string: String(index), attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium), .foregroundColor: color])
            number.isHidden = false
            number.string = text
            number.frame = CGRect(x: 0, y: (rect.height - text.size().height) / 2, width: rect.width, height: text.size().height)
        }
        symbol.path = path
    }

    /// Replace transitions from their visible value, including rapid re-entry.
    private func animate(_ layer: CALayer, _ key: String, to value: Any, duration: TimeInterval) {
        let previous = layer.presentation()?.value(forKeyPath: key) ?? layer.value(forKeyPath: key)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: key)
        layer.removeAnimation(forKey: key)
        if duration > 0 {
            let animation = CABasicAnimation(keyPath: key)
            animation.fromValue = previous
            animation.toValue = value
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(animation, forKey: key)
        }
        CATransaction.commit()
    }
}
