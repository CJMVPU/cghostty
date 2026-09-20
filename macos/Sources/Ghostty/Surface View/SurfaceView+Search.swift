import GhosttyKit

extension Ghostty.SurfaceView {

    func navigateSearchToNext() -> Bool {
        guard let surface = self.surface else { return false }
        let action = "navigate_search:next"
        if !ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8))) {
            AppDelegate.logger.warning("action failed action=\(action, privacy: .public)")
            return false
        }
        return true
    }

    func navigateSearchToPrevious() -> Bool {
        guard let surface = self.surface else { return false }
        let action = "navigate_search:previous"
        if !ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8))) {
            AppDelegate.logger.warning("action failed action=\(action, privacy: .public)")
            return false
        }
        return true
    }
}
