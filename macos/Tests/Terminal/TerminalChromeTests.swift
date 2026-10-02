import AppKit
import Testing
@testable import Ghostty

@MainActor struct TerminalChromeTests {
    @Test func metricsKeepPhysicalBorderAndFixedControls() {
        #expect(TerminalChromeMetrics.border(scale: 1) == 4)
        #expect(TerminalChromeMetrics.border(scale: 2) == 2)
        #expect(TerminalChromeMetrics.buttonSize == NSSize(width: 30, height: 24))
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
        #expect(chrome.buttons.count == 7)
        #expect(chrome.buttons.allSatisfy { $0.frame.size == TerminalChromeMetrics.buttonSize })
        #expect(chrome.buttons[1].frame.minX - chrome.buttons[0].frame.maxX == 10)
        #expect(chrome.buttons[2].frame.minX - chrome.buttons[1].frame.maxX == 10)
        #expect(chrome.buttons[3].frame.minX - chrome.buttons[2].frame.maxX == 5)
        #expect(chrome.terminalContent.frame.size == window.fixedContentSize)
        #expect(chrome.buttons[2].active)
        let second = group.windows[1]
        second.title = "A full terminal title"
        #expect(chrome.buttons[3].toolTip == "A full terminal title")
        chrome.buttons[3].performClick(nil)
        #expect(group.selectedWindow === second)
        controllers.last?.window?.close()
        try await NativeTestWait.until("closed tab removed", timeout: .seconds(3), polling: .milliseconds(5),
                                       diagnostics: { "\(group.windows.count) tabs" }, { group.windows.count == 4 })
        #expect(TerminalWindow.canAddTab(to: window))
        window.refreshChrome()
        #expect(chrome.buttons.count == 6)
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
    }
}
