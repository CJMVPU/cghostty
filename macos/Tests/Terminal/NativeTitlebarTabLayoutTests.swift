import AppKit
import Testing
@testable import Ghostty

@MainActor struct NativeTitlebarTabLayoutTests {
    @Test func repeatedUpdatesReuseConstraintsAndReleaseAppKitViews() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let root = try #require(window.contentView)
        let container = NSView(frame: root.bounds)
        let clip = NSView(frame: root.bounds)
        let accessory = NSView(frame: root.bounds)
        let tabBar = NSView(frame: root.bounds)
        root.addSubview(container)
        root.addSubview(clip)
        clip.addSubview(accessory)
        accessory.addSubview(tabBar)
        let layout = NativeTitlebarTabLayout(tabBar: tabBar, clipView: clip, accessoryView: accessory, container: container)
        #expect(layout.update(leadingInset: 70))
        root.layoutSubtreeIfNeeded()
        let initialConstraints = Set(ownedConstraints(in: root).map(ObjectIdentifier.init))
        #expect(!initialConstraints.isEmpty)
        #expect(clip.frame.width == container.bounds.width - 70)

        for width: CGFloat in [480, 900, 600] {
            container.setFrameSize(NSSize(width: width, height: 80))
            #expect(layout.update(leadingInset: 0))
            root.layoutSubtreeIfNeeded()
            #expect(clip.frame.width == width)
            #expect(Set(ownedConstraints(in: root).map(ObjectIdentifier.init)) == initialConstraints)
        }

        layout.deactivate()
        #expect(ownedConstraints(in: root).isEmpty)
        #expect(clip.translatesAutoresizingMaskIntoConstraints)
        #expect(accessory.translatesAutoresizingMaskIntoConstraints)
    }

    @Test func transientZeroSizeAndDetachedViewsReleaseConstraints() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let root = try #require(window.contentView)
        let container = NSView(frame: root.bounds)
        let clip = NSView(frame: root.bounds)
        let accessory = NSView(frame: root.bounds)
        let tabBar = NSView(frame: root.bounds)
        root.addSubview(container)
        root.addSubview(clip)
        clip.addSubview(accessory)
        accessory.addSubview(tabBar)
        let layout = NativeTitlebarTabLayout(tabBar: tabBar, clipView: clip, accessoryView: accessory, container: container)
        #expect(layout.update(leadingInset: 70))
        container.setFrameSize(.zero)
        #expect(!layout.update(leadingInset: 70))
        #expect(ownedConstraints(in: root).isEmpty)
        container.setFrameSize(NSSize(width: 600, height: 80))
        #expect(layout.update(leadingInset: 70))
        layout.deactivate()
        clip.removeFromSuperview()
        #expect(!layout.update(leadingInset: 70))
        #expect(ownedConstraints(in: root).isEmpty)
    }

    private func ownedConstraints(in view: NSView) -> [NSLayoutConstraint] {
        view.constraints.filter { $0.identifier == "cghostty.titlebar-tabs" }
            + view.subviews.flatMap { ownedConstraints(in: $0) }
    }
}
