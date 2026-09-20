import GhosttyKit

extension Ghostty {
    /// Copied diagnostics, independent of core handles and callback lifetimes.
    nonisolated struct SurfaceFault: Equatable, Sendable {
        enum Kind: Sendable {
            case ptyUnavailable
            case inputFailed
            case ioFailed
        }

        let kind: Kind
        let errorCode: String

        init(_ value: ghostty_surface_fault_s) {
            switch value.kind {
            case GHOSTTY_SURFACE_FAULT_PTY_UNAVAILABLE: kind = .ptyUnavailable
            case GHOSTTY_SURFACE_FAULT_INPUT_FAILED: kind = .inputFailed
            default: kind = .ioFailed
            }
            errorCode = value.error_code.map { String(cString: $0) } ?? "Unknown"
        }

        var explanation: String {
            switch kind {
            case .ptyUnavailable:
                "No terminal devices are available. Close unused terminal sessions and try again."
            case .inputFailed:
                "A configured input file could not be opened, read, or sent to the terminal. Check the input setting and file permissions."
            case .ioFailed:
                "The terminal IO could not start or continue. Check available system resources and the error code below."
            }
        }
    }
}
