import AppKit

/// Dimensions are points except the outer rim, which stays four backing pixels.
enum TerminalChromeMetrics {
    static let buttonSize = NSSize(width: 30, height: 24)
    static let typeGap: CGFloat = 10
    static let tabGap: CGFloat = 5
    static let borderPixels: CGFloat = 4
    static let leading: CGFloat = 12
    static func border(scale: CGFloat) -> CGFloat { borderPixels / max(1, scale) }
}

/// Chrome and terminal share one NSWindow, including the protruding controls.
final class TerminalChromeView: NSView {
    let terminalContent: TerminalViewContainer
    private(set) var buttons: [TerminalChromeButton] = []
    private var titleObservations: [NSKeyValueObservation] = []
    private var observedWindows: [ObjectIdentifier] = []
    private weak var host: HiddenTitlebarTerminalWindow?
    private var bodyFrame: NSRect { NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - TerminalChromeMetrics.buttonSize.height)) }

    init(content: TerminalViewContainer, window: HiddenTitlebarTerminalWindow) {
        terminalContent = content
        host = window
        super.init(frame: .zero)
        wantsLayer = true
        content.wantsLayer = true
        content.layer?.masksToBounds = true
        content.layer?.cornerRadius = 7
        addSubview(content)
        let drag = TerminalChromeButton(kind: .drag, label: "Move Window") { }
        let minimize = TerminalChromeButton(kind: .minimize, label: "Minimize Window") { [weak window] in window?.miniaturize(nil) }
        drag.setAccessibilityIdentifier("terminal.chrome.drag")
        minimize.setAccessibilityIdentifier("terminal.chrome.minimize")
        buttons = [drag, minimize]
        buttons.forEach(addSubview)
        setAccessibilityIdentifier("terminal.chrome")
        refreshTabs()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    func refreshTabs() {
        guard let host else { return }
        let windows = host.tabGroup?.windows ?? [host]
        let identities = windows.map(ObjectIdentifier.init)
        if identities != observedWindows {
            observedWindows = identities
            titleObservations = windows.map { window in
                window.observe(\.title) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.refreshTabs() }
                }
            }
            buttons.dropFirst(2).forEach { $0.removeFromSuperview() }
            buttons = Array(buttons.prefix(2))
            for (index, target) in windows.enumerated() {
                let button = TerminalChromeButton(kind: .tab(index + 1), label: "Tab \(index + 1)") { [weak host, weak target] in
                    guard let host, let target else { return }
                    host.tabGroup?.selectedWindow = target
                    target.makeKeyAndOrderFront(nil)
                    (target as? HiddenTitlebarTerminalWindow)?.refreshChrome()
                }
                button.setAccessibilityIdentifier("terminal.chrome.tab.\(index + 1)")
                buttons.append(button)
                addSubview(button)
            }
        }
        for (index, target) in windows.enumerated() {
            guard index + 2 < buttons.count else { continue }
            let button = buttons[index + 2]
            button.active = target === (host.tabGroup?.selectedWindow ?? host)
            button.toolTip = target.title
            button.setAccessibilityHelp(target.title)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let rim = TerminalChromeMetrics.border(scale: window?.backingScaleFactor ?? 2)
        terminalContent.frame = bodyFrame.insetBy(dx: rim, dy: rim)
        var x = TerminalChromeMetrics.leading
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(origin: NSPoint(x: x, y: bodyFrame.maxY), size: TerminalChromeMetrics.buttonSize)
            x += TerminalChromeMetrics.buttonSize.width + (index < 2 ? TerminalChromeMetrics.typeGap : TerminalChromeMetrics.tabGap)
        }
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let host, let size = host.fixedContentSize { host.fixContentSize(size) }
        needsLayout = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rim = TerminalChromeMetrics.border(scale: window?.backingScaleFactor ?? 2)
        let path = NSBezierPath(roundedRect: bodyFrame, xRadius: 9, yRadius: 9)
        path.append(NSBezierPath(roundedRect: bodyFrame.insetBy(dx: rim, dy: rim), xRadius: 7, yRadius: 7))
        path.windingRule = .evenOdd
        drawTerminalMetal(path, base: NSColor(calibratedWhite: 0.22, alpha: 1), bounds: bodyFrame)
    }
}

final class TerminalChromeButton: NSButton {
    enum Kind { case drag, minimize, tab(Int) }
    let kind: Kind
    private let actionHandler: () -> Void
    var active = false { didSet { if active != oldValue { needsDisplay = true } } }

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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func accessibilityValue() -> Any? {
        if case .tab = kind { return active ? "Selected" : "" }
        return super.accessibilityValue()
    }

    override func mouseDown(with event: NSEvent) {
        if case .drag = kind {
            // Let AppKit move the owning window and its entire tab group.
            window?.performDrag(with: event)
        } else { super.mouseDown(with: event) }
    }

    @objc private func activate() { actionHandler() }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        let isTab: Bool = if case .tab = kind { true } else { false }
        let base = isTab ? NSColor(calibratedRed: 0.12, green: 0.19, blue: 0.23, alpha: 1) : NSColor(calibratedWhite: 0.16, alpha: 1)
        drawTerminalMetal(shape, base: base, bounds: bounds)
        NSColor(calibratedWhite: 0.34, alpha: 1).setStroke()
        shape.lineWidth = 1 / max(1, window?.backingScaleFactor ?? 2)
        shape.stroke()
        let color = active ? NSColor(calibratedRed: 0.65, green: 0.88, blue: 0.32, alpha: 1) : NSColor(calibratedWhite: 0.75, alpha: 1)
        color.setFill()
        switch kind {
        case .drag:
            for row in 0..<2 {
                for column in 0..<3 {
                    NSBezierPath(ovalIn: NSRect(x: bounds.midX - 6 + CGFloat(column) * 5,
                                               y: bounds.midY - 4 + CGFloat(row) * 5, width: 2, height: 2)).fill()
                }
            }
        case .minimize:
            NSRect(x: bounds.midX - 5, y: bounds.midY - 0.75, width: 10, height: 1.5).fill()
        case .tab(let number):
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium), .foregroundColor: color]
            let text = NSAttributedString(string: String(number), attributes: attributes)
            let size = text.size()
            text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
        }
    }
}

/// Static subtle grain, with no texture files or animation on the rendering path.
private func drawTerminalMetal(_ path: NSBezierPath, base: NSColor, bounds: NSRect) {
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    path.addClip()
    base.setFill()
    bounds.fill()
    let scale = max(1, NSGraphicsContext.current?.cgContext.ctm.a ?? 2)
    for y in stride(from: bounds.minY, to: bounds.maxY, by: 2 / scale) {
        NSColor(white: 1, alpha: 0.035).setFill()
        NSRect(x: bounds.minX, y: y, width: bounds.width, height: 1 / scale).fill()
    }
}
