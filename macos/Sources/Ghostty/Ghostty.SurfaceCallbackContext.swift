import Foundation

extension Ghostty {
    /// Core userdata outlives its view when a pending operation retains Surface.
    /// The handle owns this context through ghostty_surface_free; neither back
    /// reference owns the view or handle.
    @MainActor final class SurfaceCallbackContext {
        weak var view: SurfaceView?
        weak var surface: Surface?

        init(view: SurfaceView) {
            self.view = view
        }
    }
}
