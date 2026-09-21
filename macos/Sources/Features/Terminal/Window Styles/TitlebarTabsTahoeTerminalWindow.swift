import AppKit
import SwiftUI
import Observation

/// Native titlebar tabs for `macos-titlebar-style = tabs`.
///
/// This inherits from transparent styling so that the titlebar matches the background color
/// of the window.
class TitlebarTabsTahoeTerminalWindow: TransparentTitlebarTerminalWindow, NSToolbarDelegate {
    /// The view model for SwiftUI views
    private var viewModel = ViewModel()

    private var tabLayout: NativeTitlebarTabLayout?
    private var layoutObservers: [NSObjectProtocol] = []
    private var layoutUpdateScheduled = false

    isolated deinit {
        for observer in layoutObservers { NotificationCenter.default.removeObserver(observer) }
        tabLayout?.deactivate()
    }

    override var usesToolbarForAccessories: Bool { true }

    // MARK: NSWindow

    override var titlebarFont: NSFont? {
        didSet {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.viewModel.titleFont = self.titlebarFont
            }
        }
    }

    override var title: String {
        didSet {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.viewModel.title = self.title
            }
        }
    }

    override func configure(for app: Ghostty.App) {
        super.configure(for: app)

        // We must hide the title since we're going to be moving tabs into
        // the titlebar which have their own title.
        titleVisibility = .hidden

        // Create a toolbar
        let toolbar = NSToolbar(identifier: "TerminalToolbar")
        toolbar.delegate = self
        toolbar.centeredItemIdentifiers.insert(.title)
        self.toolbar = toolbar
        toolbarStyle = .unifiedCompact
    }
    override func syncAppearance(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        super.syncAppearance(surfaceConfig)
        scheduleTabBarLayout()
    }

    override func becomeMain() {
        super.becomeMain()

        // Check if we have a tab bar and set it up if we have to. See the comment
        // on this function to learn why we need to check this here.
        setupTabBar()

        viewModel.isMainWindow = true
    }

    override func resignMain() {
        super.resignMain()

        viewModel.isMainWindow = false
    }
    override func addTitlebarAccessoryViewController(_ childViewController: NSTitlebarAccessoryViewController) {
        guard isTabBar(childViewController) else {
            super.addTitlebarAccessoryViewController(childViewController)
            return
        }

        // Release our constraints before AppKit transfers the accessory to this window.
        releaseTabBarLayout()
        childViewController.layoutAttribute = .right
        super.addTitlebarAccessoryViewController(childViewController)
        scheduleTabBarLayout()
    }

    override func removeTitlebarAccessoryViewController(at index: Int) {
        if let accessory = titlebarAccessoryViewControllers[safe: index], isTabBar(accessory) {
            // AppKit must be free to remove or resize its views during a tab transition.
            releaseTabBarLayout()
            viewModel.hasTabBar = false
        }
        super.removeTitlebarAccessoryViewController(at: index)
    }

    override func close() {
        releaseTabBarLayout()
        super.close()
    }

    // MARK: Tab Bar Layout

    /// Coalesce AppKit attachment and geometry events into one layout pass.
    /// No polling or fixed delay: subsequent frame changes request another pass.
    private func scheduleTabBarLayout() {
        guard !layoutUpdateScheduled else { return }
        layoutUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.layoutUpdateScheduled = false
            self.setupTabBar()
        }
    }

    private func setupTabBar() {
        guard let titlebarView,
              let tabBar = tabBarView,
              let container = titlebarView.firstDescendant(withClassName: "NSToolbarView"),
              let clipView = tabBar.firstSuperview(withClassName: "NSTitlebarAccessoryContainerView")
                ?? tabBar.firstSuperview(withClassName: "NSTitlebarAccessoryClipView"),
              let accessoryView = clipView.subviews.first else {
            releaseTabBarLayout()
            viewModel.hasTabBar = false
            return
        }

        if tabLayout?.matches(tabBar: tabBar, clipView: clipView, accessoryView: accessoryView, container: container) != true {
            releaseTabBarLayout()
            tabLayout = NativeTitlebarTabLayout(
                tabBar: tabBar, clipView: clipView, accessoryView: accessoryView, container: container)
            // AppKit may attach the tab bar before the toolbar has its final size.
            for view in [tabBar, container] {
                view.postsFrameChangedNotifications = true
                layoutObservers.append(NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification, object: view, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleTabBarLayout() }
                })
            }
        }

        let leadingInset: CGFloat = derivedConfig.macosWindowButtons == .hidden ? 0 : 70
        if tabLayout?.update(leadingInset: leadingInset) == true,
           let newTabButton = tabBar.firstDescendant(withClassName: "NSTabBarNewTabButton"),
           newTabButton.frame.width > 0,
           tabBar.frame.height != newTabButton.frame.width {
            // AppKit's tab row follows its square add button, independently of
            // the toolbar item's content height when switching selected tabs.
            tabBar.setFrameSize(NSSize(width: tabBar.frame.width, height: newTabButton.frame.width))
        }
        viewModel.hasTabBar = true
    }

    private func releaseTabBarLayout() {
        for observer in layoutObservers { NotificationCenter.default.removeObserver(observer) }
        layoutObservers.removeAll()
        tabLayout?.deactivate()
        tabLayout = nil
    }

    // MARK: NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [.title, .resetSplitZoom, .flexibleSpace, .space]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [.flexibleSpace, .title, .flexibleSpace, .resetSplitZoom]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .title:
            let item = NSToolbarItem(itemIdentifier: .title)
            item.view = ClickThroughHostingView(rootView: TitleItem(viewModel: viewModel))
            // Fix: https://github.com/ghostty-org/ghostty/discussions/9027
            item.view?.setContentCompressionResistancePriority(.required, for: .horizontal)
            item.visibilityPriority = .user
            item.isEnabled = false

            // This is the documented way to avoid the glass view on an item.
            // We don't want glass on our title.
            item.isBordered = false

            return item
        case .resetSplitZoom:
            let item = NSToolbarItem(itemIdentifier: .resetSplitZoom)
            item.view = makeResetZoomView(inToolbar: true)
            item.isBordered = false
            return item
        default:
            return NSToolbarItem(itemIdentifier: itemIdentifier)
        }
    }

    // MARK: SwiftUI

    @MainActor @Observable final class ViewModel {
        var titleFont: NSFont?
        var title: String = "cghostty"
        var hasTabBar: Bool = false
        var isMainWindow: Bool = true
    }
}

extension NSToolbarItem.Identifier {
    /// Displays the title of the window
    static let title = NSToolbarItem.Identifier("Title")
    static let resetSplitZoom = NSToolbarItem.Identifier("ResetSplitZoom")
}

extension TitlebarTabsTahoeTerminalWindow {
    /// Displays the window title
    struct TitleItem: View {
        let viewModel: ViewModel

        var title: String {
            // An empty title makes this view zero-sized and NSToolbar on macOS
            // tahoe just deletes the item when that happens. So we use a space
            // instead to ensure there's always some size.
            return viewModel.title.isEmpty ? " " : viewModel.title
        }

        var body: some View {
            if !viewModel.hasTabBar {
                titleText
            } else {
                // 1x1.gif strikes again! For real: if we render a zero-sized
                // view here then the toolbar just disappears our view. I don't
                // know. On macOS 26.1+ the view no longer disappears, but the
                // toolbar still logs an ambiguous content size warning.
                Color.clear.frame(width: 1, height: 1)
            }
        }

        @ViewBuilder
        var titleText: some View {
            Text(title)
                .font(viewModel.titleFont.flatMap(Font.init(_:)))
                .foregroundStyle(viewModel.isMainWindow ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .greatestFiniteMagnitude, alignment: .center)
                .opacity(viewModel.hasTabBar ? 0 : 1) // hide when in fullscreen mode, where title bar will appear in the leading area under window buttons
        }
    }
}

/// A "Ghosting" Hosting View, that acts like it's not there
private class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
