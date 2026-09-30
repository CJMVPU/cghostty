/// Tracks who may recycle a compositor slot. GPU resources remain with the
/// slot until partial submissions are drained or final feedback retires it.
nonisolated struct WindowFrameTransaction {
    enum Cleanup { case none, release, drainAndRelease }
    private enum State { case acquired, submitted, completionOwned, released }
    private var state: State = .acquired

    mutating func didSubmit() {
        precondition(state == .acquired || state == .submitted)
        state = .submitted
    }

    /// Call immediately before the final nonthrowing queue commit. Feedback
    /// owns retirement from here, including when it runs before present().
    mutating func handoffToCompletion() {
        precondition(state == .submitted)
        state = .completionOwned
    }

    mutating func abort() -> Cleanup {
        switch state {
        case .acquired: state = .released; return .release
        case .submitted: state = .released; return .drainAndRelease
        case .completionOwned, .released: return .none
        }
    }
}
