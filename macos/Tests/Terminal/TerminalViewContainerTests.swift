//
//  TerminalViewContainerTests.swift
//  Ghostty
//
//  Created by Lukas on 26.02.2026.
//

import SwiftUI
import Testing
@testable import Ghostty

class MockTerminalViewContainer: TerminalViewContainer {
    var _windowCornerRadius: CGFloat?
    override var windowThemeFrameView: NSView? {
        NSView()
    }

    override var windowCornerRadius: CGFloat? {
        _windowCornerRadius
    }
}

@MainActor
struct TerminalViewContainerTests {
    @Test func glassIsAttachedSynchronously() throws {
        let view = MockTerminalViewContainer {
            EmptyView()
        }

        let config = try TemporaryConfig("background-blur = macos-glass-regular\nbackground-opacity = 1")
        view.ghosttyConfigDidChange(config, preferredBackgroundColor: nil)
        #expect(view.glassEffectView != nil)
    }
}
