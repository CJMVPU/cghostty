import Foundation
import os

// Shared namespace and logging for the native application and its core bridge.
enum Ghostty {
    // The primary logger used by the GhosttyKit libraries.
    nonisolated static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "ghostty"
    )

}
