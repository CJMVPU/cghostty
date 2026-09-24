import Testing
import AppKit
@testable import Ghostty

@MainActor struct TransferablePasteboardTests {
    @Test func dragPayloadIsImmediatelyAvailableAndMatchesSurfaceID() {
        let id = UUID()
        let item = Ghostty.SurfaceView.dragPasteboardItem(id: id)
        var bytes = id.uuid
        let expected = withUnsafeBytes(of: &bytes) { Data($0) }
        #expect(item.types == [.ghosttySurfaceId])
        #expect(item.data(forType: .ghosttySurfaceId) == expected)
        #expect(expected.count == 16)
    }

    @Test func dragItemsOwnIndependentSnapshots() {
        let first = Ghostty.SurfaceView.dragPasteboardItem(id: UUID())
        let before = first.data(forType: .ghosttySurfaceId)
        let second = Ghostty.SurfaceView.dragPasteboardItem(id: UUID())
        #expect(before == first.data(forType: .ghosttySurfaceId))
        #expect(before != second.data(forType: .ghosttySurfaceId))
    }
}
