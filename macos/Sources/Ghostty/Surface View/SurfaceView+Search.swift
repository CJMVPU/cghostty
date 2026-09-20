extension Ghostty.SurfaceView {
    func navigateSearchToNext() -> Bool {
        surfaceModel?.navigateSearch(.next) ?? false
    }

    func navigateSearchToPrevious() -> Bool {
        surfaceModel?.navigateSearch(.previous) ?? false
    }
}
