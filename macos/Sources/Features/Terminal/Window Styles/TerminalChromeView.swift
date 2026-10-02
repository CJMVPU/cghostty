import AppKit

/// Dimensions are points except the outer rim, which stays four backing pixels.
enum TerminalChromeMetrics {
    static let buttonSize = NSSize(width: 25, height: 25)
    static let typeGap: CGFloat = 10
    static let tabGap: CGFloat = 5
    static let borderPixels: CGFloat = 4
    static let leading: CGFloat = 12
    static let cornerRadius: CGFloat = 12
    static let windowControlCount = 3
    /// Keep our smaller circular corners inside AppKit's native window mask.
    /// The greatest difference is at 45 degrees. Round outwards to backing pixels
    /// and leave one more pixel for antialiasing.
    static func edgeInset(scale: CGFloat, windowRadius: CGFloat = cornerRadius) -> CGFloat {
        let scale = max(1, scale)
        let clearance = max(0, windowRadius - cornerRadius) * (1 - sqrt(0.5))
        return (ceil(clearance * scale) + 1) / scale
    }

    static func borderPath(in rect: CGRect, scale: CGFloat) -> CGPath {
        let halfWidth = border(scale: scale) / 2
        return CGPath(roundedRect: rect.insetBy(dx: halfWidth, dy: halfWidth),
                      cornerWidth: cornerRadius - halfWidth, cornerHeight: cornerRadius - halfWidth, transform: nil)
    }
    static func innerRadius(scale: CGFloat) -> CGFloat { cornerRadius - border(scale: scale) }
    static func border(scale: CGFloat) -> CGFloat { borderPixels / max(1, scale) }
}

/// Chrome and terminal share one NSWindow, including the protruding controls.
final class TerminalChromeView: NSView {
    let terminalContent: TerminalViewContainer
    private(set) var buttons: [TerminalChromeButton] = []
    private var titleObservations: [NSKeyValueObservation] = []
    private var observedWindows: [ObjectIdentifier] = []
    private weak var host: HiddenTitlebarTerminalWindow?
    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }
    private var bodyFrame: NSRect {
        let inset = host?.chromeEdgeInset ?? TerminalChromeMetrics.edgeInset(scale: scale)
        return NSRect(x: inset, y: inset, width: max(0, bounds.width - inset * 2),
                      height: max(0, bounds.height - TerminalChromeMetrics.buttonSize.height - inset * 2))
    }

    init(content: TerminalViewContainer, window: HiddenTitlebarTerminalWindow) {
        terminalContent = content
        host = window
        super.init(frame: .zero)
        wantsLayer = true
        content.wantsLayer = true
        content.layer?.masksToBounds = true
        content.layer?.cornerRadius = TerminalChromeMetrics.innerRadius(scale: window.backingScaleFactor)
        addSubview(content)
        let drag = TerminalChromeButton(kind: .drag, label: "Move Window") { }
        let minimize = TerminalChromeButton(kind: .minimize, label: "Minimize Window") { [weak window] in window?.miniaturize(nil) }
        let close = TerminalChromeButton(kind: .close, label: "Close Window") { [weak window] in
            window?.terminalController?.closeWindow(nil)
        }
        close.setAccessibilityIdentifier("terminal.chrome.close")
        close.setAccessibilityHelp("Close this window and all its tabs")
        drag.setAccessibilityIdentifier("terminal.chrome.drag")
        minimize.setAccessibilityIdentifier("terminal.chrome.minimize")
        buttons = [drag, minimize, close]
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
            buttons.dropFirst(TerminalChromeMetrics.windowControlCount).forEach { $0.removeFromSuperview() }
            buttons = Array(buttons.prefix(TerminalChromeMetrics.windowControlCount))
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
            guard index + TerminalChromeMetrics.windowControlCount < buttons.count else { continue }
            let button = buttons[index + TerminalChromeMetrics.windowControlCount]
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
        terminalContent.layer?.cornerRadius = TerminalChromeMetrics.innerRadius(scale: scale)
        var x = TerminalChromeMetrics.leading
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(origin: NSPoint(x: x, y: bodyFrame.maxY), size: TerminalChromeMetrics.buttonSize)
            x += TerminalChromeMetrics.buttonSize.width + (index < TerminalChromeMetrics.windowControlCount ? TerminalChromeMetrics.typeGap : TerminalChromeMetrics.tabGap)
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
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.addPath(TerminalChromeMetrics.borderPath(in: bodyFrame, scale: scale))
        context.setLineWidth(rim)
        context.replacePathWithStrokedPath()
        context.clip()
        drawTerminalMetal(base: NSColor(calibratedWhite: 0.22, alpha: 1), bounds: bodyFrame)
    }
}

/// Static subtle grain, with no texture files or animation on the rendering path.
private func drawTerminalMetal(base: NSColor, bounds: NSRect) {
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    base.setFill()
    bounds.fill()
    let scale = max(1, NSGraphicsContext.current?.cgContext.ctm.a ?? 2)
    for y in stride(from: bounds.minY, to: bounds.maxY, by: 2 / scale) {
        NSColor(white: 1, alpha: 0.035).setFill()
        NSRect(x: bounds.minX, y: y, width: bounds.width, height: 1 / scale).fill()
    }
}
