import Testing
import AppKit
@testable import Ghostty

struct QuickTerminalScreenStateCacheTests {
    /// The UUID dictionary used an alternating key/value array, with CGRect/CGSize
    /// arrays and Date seconds relative to 2001. Keep decoding that format through
    /// the actual application restoration entry point without creating a terminal.
    @Test func legacyDisplayEntriesDecodeThroughActualRestorableState() throws {
        let displayID = try #require(UUID(uuidString: "FC4F30BB-A6E4-47F3-8B1F-25A00E03C992"))
        let surfaceID = "A582E508-5958-4A30-A217-1DDE607393BE"
        let json = """
        {"internalState":{
          "focusedSurface":"\(surfaceID)",
          "surfaceTree":{"version":1,"root":{"view":{"uuid":"\(surfaceID)","pwd":"/tmp"}}},
          "screenStateEntries":["\(displayID)",{
            "frame":[[-1920,180],[1920,420]],"screenSize":[1920,1080],
            "scale":2,"lastSeen":-978307200
          }]
        }}
        """
        let state = try JSONDecoder().decode(QuickTerminalRestorableState.self, from: Data(json.utf8))
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        state.encode(with: archiver)
        archiver.finishEncoding()
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
        unarchiver.requiresSecureCoding = true
        defer { unarchiver.finishDecoding() }
        let restored = try #require(QuickTerminalRestorableState(coder: unarchiver))
        let entry = try #require(restored.screenStateEntries[displayID])

        #expect(restored.screenStateEntries.count == 1)
        #expect(entry.frame == NSRect(x: -1920, y: 180, width: 1920, height: 420))
        #expect(entry.screenSize == CGSize(width: 1920, height: 1080))
        #expect(entry.scale == 2)
        #expect(entry.lastSeen == Date(timeIntervalSince1970: 0))
        #expect(restored.focusedSurface == surfaceID)
        #expect(restored.surfaceTree.leaves.map(\.id.uuidString) == [surfaceID])
        #expect(restored.baseConfig?.environmentVariables["GHOSTTY_QUICK_TERMINAL"] == "1")
    }

}
