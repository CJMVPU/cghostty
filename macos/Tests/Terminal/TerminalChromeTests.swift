import AppKit
import Testing
@testable import Ghostty

@MainActor struct TerminalChromeTests {
    @Test func metricsKeepPhysicalBorderAndFixedControls() {
        #expect(TerminalChromeMetrics.border(scale: 1) == 4)
        #expect(TerminalChromeMetrics.border(scale: 2) == 2)
        #expect(TerminalChromeMetrics.buttonSize == NSSize(width: 25, height: 25))
    }

    @Test(arguments: [CGFloat(1), CGFloat(2)])
    func borderKeepsFourPixelWidthInsideNativeCorners(scale: CGFloat) {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let nativeMask = CGPath(roundedRect: bounds, cornerWidth: 16, cornerHeight: 16, transform: nil)
        let inset = TerminalChromeMetrics.edgeInset(scale: scale, windowRadius: 16)
        let outer = bounds.insetBy(dx: inset, dy: inset)
        let stroke = TerminalChromeMetrics.borderPath(in: outer, scale: scale)
            .copy(strokingWithWidth: 4 / scale, lineCap: .butt, lineJoin: .round, miterLimit: 10)
        let center = CGPoint(x: outer.minX + 12, y: outer.minY + 12)
        let tolerance = 0.3 / scale
        for degrees in stride(from: 0, through: 90, by: 5) {
            let angle = CGFloat(degrees) * .pi / 180
            func point(_ radius: CGFloat) -> CGPoint {
                CGPoint(x: center.x - radius * cos(angle), y: center.y - radius * sin(angle))
            }
            for flipX in [false, true] {
                for flipY in [false, true] {
                    func reflect(_ point: CGPoint) -> CGPoint {
                        CGPoint(x: flipX ? bounds.maxX - point.x : point.x,
                                y: flipY ? bounds.maxY - point.y : point.y)
                    }
                    #expect(nativeMask.contains(reflect(point(12))))
                    #expect(stroke.contains(reflect(point(12 - tolerance))))
                    #expect(!stroke.contains(reflect(point(12 + tolerance))))
                    #expect(stroke.contains(reflect(point(12 - 4 / scale + tolerance))))
                    #expect(!stroke.contains(reflect(point(12 - 4 / scale - tolerance))))
                }
            }
        }
    }

    @Test func hiddenTabsPreserveGridAndEnforceFiveTabLimit() async throws {
        let config = try TemporaryConfig("""
        macos-titlebar-style = hidden
        window-width = 50
        window-height = 12
        initial-window = false
        confirm-close-surface = false
        """)
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        var base = Ghostty.SurfaceConfiguration()
        base.command = "/bin/cat"
        base.workingDirectory = FileManager.default.temporaryDirectory.path
        let first = TerminalController(app, withBaseConfig: base)
        var controllers = [first]
        defer { controllers.forEach { $0.window?.close() } }
        let window = try #require(first.window as? HiddenTitlebarTerminalWindow)
        let chrome = try #require(window.chrome)
        first.showWindow(nil)
        for _ in 0..<4 {
            let next = try #require(TerminalController.newTab(app, from: window, withBaseConfig: base))
            controllers.append(next)
        }
        let group = try #require(window.tabGroup)
        #expect(group.windows.count == 5)
        #expect(TerminalController.newTab(app, from: window, withBaseConfig: base) == nil)
        #expect(group.windows.count == 5)
        group.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
        first.relabelTabs()
        chrome.layoutSubtreeIfNeeded()
        #expect(chrome.buttons.count == 8)
        #expect(chrome.buttons.allSatisfy { $0.frame.size == TerminalChromeMetrics.buttonSize })
        #expect(chrome.buttons[1].frame.minX - chrome.buttons[0].frame.maxX == 10)
        #expect(chrome.buttons[2].frame.minX - chrome.buttons[1].frame.maxX == 10)
        #expect(chrome.buttons[3].frame.minX - chrome.buttons[2].frame.maxX == 10)
        #expect(chrome.buttons[4].frame.minX - chrome.buttons[3].frame.maxX == 5)
        #expect(chrome.terminalContent.frame.size == window.fixedContentSize)
        #expect(chrome.buttons[3].active)
        let second = group.windows[1]
        second.title = "A full terminal title"
        #expect(chrome.buttons[4].toolTip == "A full terminal title")
        chrome.buttons[4].performClick(nil)
        #expect(group.selectedWindow === second)
        controllers.last?.window?.close()
        try await NativeTestWait.until("closed tab removed", timeout: .seconds(3), polling: .milliseconds(5),
                                       diagnostics: { "\(group.windows.count) tabs" }, { group.windows.count == 4 })
        #expect(TerminalWindow.canAddTab(to: window))
        window.refreshChrome()
        #expect(chrome.buttons.count == 7)
        let menu = NSMenuItem(title: "New Tab", action: #selector(TerminalController.newTab(_:)), keyEquivalent: "")
        #expect(first.validateMenuItem(menu))
        let extra = TerminalController(app, withBaseConfig: base)
        controllers.append(extra)
        extra.showWindow(nil)
        window.mergeAllWindows(nil)
        #expect(group.windows.count == 5)
        #expect(group.windows.contains { $0 === extra.window })
        #expect(!first.validateMenuItem(menu))
        let overflow = TerminalController(app, withBaseConfig: base)
        controllers.append(overflow)
        overflow.showWindow(nil)
        window.mergeAllWindows(nil)
        #expect(group.windows.count == 5)
        #expect(!group.windows.contains { $0 === overflow.window })
        #expect(overflow.window?.isVisible == true)
        group.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
        chrome.buttons[2].performClick(nil)
        try await NativeTestWait.until("close control closes the entire tab group", timeout: .seconds(3), polling: .milliseconds(5),
                                       diagnostics: { "\(app.windowRegistry.all.count) windows remain" }, { app.windowRegistry.all.count == 1 })
        #expect(app.windowRegistry.all.first === overflow)
    }
}
