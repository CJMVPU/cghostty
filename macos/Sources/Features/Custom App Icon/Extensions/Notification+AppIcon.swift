import AppKit

extension Notification.Name {
    /// Distributed Notification for DockTilePlugin to update icon
    ///
    /// Ghostty -> DockTilePlugin
    nonisolated static let ghosttyIconDidChange = Notification.Name("com.cjmvpu.cghostty.iconDidChange")
}
