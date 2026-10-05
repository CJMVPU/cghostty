import Cocoa

/// Geometry types retained for decoding Quick Terminal archives from earlier versions.
/// Current window placement comes from configuration rather than saved display geometry.
enum QuickTerminalScreenStateCache {
    typealias Entries = [UUID: DisplayEntry]

    struct DisplayEntry: Codable {
        var frame: NSRect
        var screenSize: CGSize
        var scale: CGFloat
        var lastSeen: Date
    }
}
