#if CGHOSTTY_CORRECTED_CLOCK || CGHOSTTY_TESTING
/// Experimental feedback only. Every residual uses the *same frame's*
/// targetTimestamp, never a submission-relative delay added to another origin.
nonisolated struct WindowPresentationEstimate {
    private var residuals: [Double] = []
    private(set) var generation: UInt64 = 0

    var offset: Double {
        guard residuals.count >= 5 else { return 0 }
        let sorted = residuals.sorted()
        return sorted[sorted.count / 2]
    }

    mutating func reset() {
        residuals.removeAll(keepingCapacity: true)
        generation &+= 1
    }

    mutating func record(target: Double, presented: Double, generation: UInt64) {
        let residual = presented - target
        guard generation == self.generation, presented > 0, residual.isFinite,
              abs(residual) < 0.25 else { return }
        residuals.append(residual)
        if residuals.count > 31 { residuals.removeFirst() }
    }
}
#endif
