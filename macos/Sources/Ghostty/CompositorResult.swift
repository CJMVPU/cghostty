import GhosttyKit

/// Typed flags for one pane transaction; the C bridge retains UInt32 storage.
nonisolated struct CompositorResult: OptionSet, Sendable {
    let rawValue: UInt32
    static let repaint = Self(rawValue: UInt32(GHOSTTY_COMPOSITOR_REPAINT.rawValue))
    static let needsFrame = Self(rawValue: UInt32(GHOSTTY_COMPOSITOR_NEEDS_FRAME.rawValue))
    static let geometryMismatch = Self(rawValue: UInt32(GHOSTTY_COMPOSITOR_GEOMETRY_MISMATCH.rawValue))
    static let failed = Self(rawValue: UInt32(GHOSTTY_COMPOSITOR_FAILED.rawValue))
    static let composed = Self(rawValue: UInt32(GHOSTTY_COMPOSITOR_COMPOSED.rawValue))
}
