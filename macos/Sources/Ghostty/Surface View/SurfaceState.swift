import AppKit
import SwiftUI
import Observation

extension Ghostty {
    /// UI state for one stable native terminal. It never owns a core handle or view.
    @MainActor @Observable final class SurfaceState {
        var pwd: String?
        var cellSize: CGSize = .zero
        var windowFocused = true
        var scrollbar: Action.Scrollbar?
        var healthy: Bool = true
        var error: Error?
        var fault: SurfaceFault?
        var hoverUrl: String?
        var progressReport: Action.ProgressReport?
        var keyTables: [String] = []
        var searchState: SearchState?
        var focusInstant: ContinuousClock.Instant?
        var surfaceSize: Ghostty.Surface.Size?
        var readonly: Bool = false
        var highlighted: Bool = false
        var childExitedMessage: ChildExitedMessage?
        var title: String = ""
        var keySequence: [KeyboardShortcut] = []
        var pointerStyle: CursorStyle = .horizontalText
        var mouseOverSurface: Bool = false
        var mouseLocationInSurface: CGPoint?
        var cursorVisible: Bool = true
        var derivedConfig: SurfaceView.DerivedConfig
        var backgroundColor: Color?
        var bell: Bool = false
        var inspectorVisible: Bool = false

        init(derivedConfig: SurfaceView.DerivedConfig = .init()) {
            self.derivedConfig = derivedConfig
        }
    }
}
