import Observation

/// Presentation state owned by one window. Native surface identities survive
/// SwiftUI view recreation and moving splits between windows.
@MainActor @Observable final class TerminalWindowState {
    var surfaceTree: SplitTree<Ghostty.SurfaceView> = .init()
    var commandPaletteIsShowing = false
    var bell = false
}
