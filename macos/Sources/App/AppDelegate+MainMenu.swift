import AppKit

extension AppDelegate {
    /// Native menus keep first-responder dispatch and config-driven shortcuts.
    func installMainMenu() {
        menuBindings.removeAll(keepingCapacity: true)
        func shortcut(_ action: String, _ item: NSMenuItem) -> NSMenuItem {
            menuBindings.append((action, item))
            return item
        }
        let main = NSMenu(title: "Main Menu")

        let cghosttyMenu = NSMenu(title: "cghostty")
        main.addItem(withTitle: "cghostty", action: nil, keyEquivalent: "").submenu = cghosttyMenu
        let menuAbout = cghosttyMenu.addItem(withTitle: "About cghostty", action: NSSelectorFromString("showAbout:"), keyEquivalent: "")
        self.menuAbout = menuAbout
        menuAbout.keyEquivalentModifierMask = []
        let menuCheckForUpdates = shortcut("check_for_updates", cghosttyMenu.addItem(withTitle: "Check for Updates...", action: NSSelectorFromString("checkForUpdates:"), keyEquivalent: ""))
        self.menuCheckForUpdates = menuCheckForUpdates
        menuCheckForUpdates.target = self
        menuCheckForUpdates.keyEquivalentModifierMask = []
        cghosttyMenu.addItem(.separator())
        let menuOpenConfig = shortcut("open_config", cghosttyMenu.addItem(withTitle: "Preferences…", action: NSSelectorFromString("openConfig:"), keyEquivalent: ","))
        self.menuOpenConfig = menuOpenConfig
        menuOpenConfig.target = self
        cghosttyMenu.addItem(.separator())
        let menuReloadConfig = shortcut("reload_config", cghosttyMenu.addItem(withTitle: "Reload Configuration", action: NSSelectorFromString("reloadConfig:"), keyEquivalent: ""))
        self.menuReloadConfig = menuReloadConfig
        menuReloadConfig.target = self
        menuReloadConfig.keyEquivalentModifierMask = []
        let menuSecureInput = shortcut("toggle_secure_input", cghosttyMenu.addItem(withTitle: "Secure Keyboard Entry", action: NSSelectorFromString("toggleSecureInput:"), keyEquivalent: ""))
        self.menuSecureInput = menuSecureInput
        menuSecureInput.target = self
        menuSecureInput.keyEquivalentModifierMask = []
        let menuSetAsDefaultTerminal = cghosttyMenu.addItem(withTitle: "Make cghostty the Default Terminal", action: NSSelectorFromString("setAsDefaultTerminal:"), keyEquivalent: "")
        self.menuSetAsDefaultTerminal = menuSetAsDefaultTerminal
        menuSetAsDefaultTerminal.target = self
        menuSetAsDefaultTerminal.keyEquivalentModifierMask = []
        cghosttyMenu.addItem(.separator())
        let item7 = cghosttyMenu.addItem(withTitle: "Services", action: nil, keyEquivalent: "")
        item7.keyEquivalentModifierMask = []
        let item7Submenu = NSMenu(title: "Services")
        item7.submenu = item7Submenu
        menuServices = item7Submenu
        cghosttyMenu.addItem(.separator())
        _ = cghosttyMenu.addItem(withTitle: "Hide cghostty", action: NSSelectorFromString("hide:"), keyEquivalent: "h")
        let item9 = cghosttyMenu.addItem(withTitle: "Hide Others", action: NSSelectorFromString("hideOtherApplications:"), keyEquivalent: "h")
        item9.keyEquivalentModifierMask = [.option, .command]
        let item10 = cghosttyMenu.addItem(withTitle: "Show All", action: NSSelectorFromString("unhideAllApplications:"), keyEquivalent: "")
        item10.keyEquivalentModifierMask = []
        cghosttyMenu.addItem(.separator())
        let menuQuit = shortcut("quit", cghosttyMenu.addItem(withTitle: "Quit cghostty", action: NSSelectorFromString("terminate:"), keyEquivalent: ""))
        menuQuit.keyEquivalentModifierMask = []

        let fileMenu = NSMenu(title: "File")
        main.addItem(withTitle: "File", action: nil, keyEquivalent: "").submenu = fileMenu
        let menuNewWindow = shortcut("new_window", fileMenu.addItem(withTitle: "New Window", action: NSSelectorFromString("newWindow:"), keyEquivalent: ""))
        self.menuNewWindow = menuNewWindow
        menuNewWindow.keyEquivalentModifierMask = []
        let menuNewTab = shortcut("new_tab", fileMenu.addItem(withTitle: "New Tab", action: NSSelectorFromString("newTab:"), keyEquivalent: ""))
        self.menuNewTab = menuNewTab
        menuNewTab.keyEquivalentModifierMask = []
        fileMenu.addItem(.separator())
        let menuSplitRight = shortcut("new_split:right", fileMenu.addItem(withTitle: "Split Right", action: NSSelectorFromString("splitRight:"), keyEquivalent: ""))
        self.menuSplitRight = menuSplitRight
        menuSplitRight.keyEquivalentModifierMask = []
        let menuSplitLeft = shortcut("new_split:left", fileMenu.addItem(withTitle: "Split Left", action: NSSelectorFromString("splitLeft:"), keyEquivalent: ""))
        self.menuSplitLeft = menuSplitLeft
        menuSplitLeft.keyEquivalentModifierMask = []
        let menuSplitDown = shortcut("new_split:down", fileMenu.addItem(withTitle: "Split Down", action: NSSelectorFromString("splitDown:"), keyEquivalent: ""))
        self.menuSplitDown = menuSplitDown
        menuSplitDown.keyEquivalentModifierMask = []
        let menuSplitUp = shortcut("new_split:up", fileMenu.addItem(withTitle: "Split Up", action: NSSelectorFromString("splitUp:"), keyEquivalent: ""))
        self.menuSplitUp = menuSplitUp
        menuSplitUp.keyEquivalentModifierMask = []
        fileMenu.addItem(.separator())
        let menuClose = shortcut("close_surface", fileMenu.addItem(withTitle: "Close", action: NSSelectorFromString("close:"), keyEquivalent: ""))
        self.menuClose = menuClose
        menuClose.keyEquivalentModifierMask = []
        let menuCloseTab = shortcut("close_tab", fileMenu.addItem(withTitle: "Close Tab", action: NSSelectorFromString("closeTab:"), keyEquivalent: ""))
        menuCloseTab.keyEquivalentModifierMask = []
        let menuCloseWindow = shortcut("close_window", fileMenu.addItem(withTitle: "Close Window", action: NSSelectorFromString("closeWindow:"), keyEquivalent: ""))
        menuCloseWindow.keyEquivalentModifierMask = []
        let menuCloseAllWindows = shortcut("close_all_windows", fileMenu.addItem(withTitle: "Close All Windows", action: NSSelectorFromString("closeAllWindows:"), keyEquivalent: ""))
        menuCloseAllWindows.keyEquivalentModifierMask = []

        let editMenu = NSMenu(title: "Edit")
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = editMenu
        let menuUndo = shortcut("undo", editMenu.addItem(withTitle: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: ""))
        menuUndo.keyEquivalentModifierMask = []
        let menuRedo = shortcut("redo", editMenu.addItem(withTitle: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: ""))
        menuRedo.keyEquivalentModifierMask = []
        editMenu.addItem(.separator())
        let menuCopy = shortcut("copy_to_clipboard", editMenu.addItem(withTitle: "Copy", action: NSSelectorFromString("copy:"), keyEquivalent: ""))
        menuCopy.keyEquivalentModifierMask = []
        let menuPaste = shortcut("paste_from_clipboard", editMenu.addItem(withTitle: "Paste", action: NSSelectorFromString("paste:"), keyEquivalent: ""))
        menuPaste.keyEquivalentModifierMask = []
        let menuPasteSelection = shortcut("paste_from_selection", editMenu.addItem(withTitle: "Paste Selection", action: NSSelectorFromString("pasteSelection:"), keyEquivalent: ""))
        self.menuPasteSelection = menuPasteSelection
        menuPasteSelection.keyEquivalentModifierMask = []
        let menuSelectAll = shortcut("select_all", editMenu.addItem(withTitle: "Select All", action: NSSelectorFromString("selectAll:"), keyEquivalent: ""))
        menuSelectAll.keyEquivalentModifierMask = []
        editMenu.addItem(.separator())
        let menuFindParent = editMenu.addItem(withTitle: "Find", action: nil, keyEquivalent: "")
        self.menuFindParent = menuFindParent
        menuFindParent.keyEquivalentModifierMask = []
        let menuFindParentSubmenu = NSMenu(title: "Find")
        menuFindParent.submenu = menuFindParentSubmenu
        let menuFind = shortcut("start_search", menuFindParentSubmenu.addItem(withTitle: "Find...", action: NSSelectorFromString("find:"), keyEquivalent: ""))
        menuFind.keyEquivalentModifierMask = []
        let menuFindNext = shortcut("navigate_search:next", menuFindParentSubmenu.addItem(withTitle: "Find Next", action: NSSelectorFromString("findNext:"), keyEquivalent: ""))
        menuFindNext.keyEquivalentModifierMask = []
        let menuFindPrevious = shortcut("navigate_search:previous", menuFindParentSubmenu.addItem(withTitle: "Find Previous", action: NSSelectorFromString("findPrevious:"), keyEquivalent: ""))
        menuFindPrevious.keyEquivalentModifierMask = []
        menuFindParentSubmenu.addItem(.separator())
        let menuHideFindBar = shortcut("end_search", menuFindParentSubmenu.addItem(withTitle: "Hide Find Bar", action: NSSelectorFromString("findHide:"), keyEquivalent: ""))
        menuHideFindBar.keyEquivalentModifierMask = []
        menuFindParentSubmenu.addItem(.separator())
        let menuSelectionForFind = shortcut("search_selection", menuFindParentSubmenu.addItem(withTitle: "Use Selection for Find", action: NSSelectorFromString("selectionForFind:"), keyEquivalent: ""))
        menuSelectionForFind.keyEquivalentModifierMask = []
        let menuScrollToSelection = shortcut("scroll_to_selection", menuFindParentSubmenu.addItem(withTitle: "Jump to Selection", action: NSSelectorFromString("scrollToSelection:"), keyEquivalent: ""))
        menuScrollToSelection.keyEquivalentModifierMask = []
        editMenu.addItem(.separator())

        let viewMenu = NSMenu(title: "View")
        main.addItem(withTitle: "View", action: nil, keyEquivalent: "").submenu = viewMenu
        let menuResetFontSize = shortcut("reset_font_size", viewMenu.addItem(withTitle: "Reset Font Size", action: NSSelectorFromString("resetFontSize:"), keyEquivalent: ""))
        self.menuResetFontSize = menuResetFontSize
        menuResetFontSize.keyEquivalentModifierMask = []
        let menuIncreaseFontSize = shortcut("increase_font_size:1", viewMenu.addItem(withTitle: "Increase Font Size", action: NSSelectorFromString("increaseFontSize:"), keyEquivalent: ""))
        self.menuIncreaseFontSize = menuIncreaseFontSize
        menuIncreaseFontSize.keyEquivalentModifierMask = []
        let menuDecreaseFontSize = shortcut("decrease_font_size:1", viewMenu.addItem(withTitle: "Decrease Font Size", action: NSSelectorFromString("decreaseFontSize:"), keyEquivalent: ""))
        self.menuDecreaseFontSize = menuDecreaseFontSize
        menuDecreaseFontSize.keyEquivalentModifierMask = []
        viewMenu.addItem(.separator())
        let menuCommandPalette = shortcut("toggle_command_palette", viewMenu.addItem(withTitle: "Command Palette", action: NSSelectorFromString("toggleCommandPalette:"), keyEquivalent: ""))
        self.menuCommandPalette = menuCommandPalette
        menuCommandPalette.keyEquivalentModifierMask = []
        let menuChangeTabTitle = shortcut("prompt_tab_title", viewMenu.addItem(withTitle: "Change Tab Title...", action: NSSelectorFromString("changeTabTitle:"), keyEquivalent: ""))
        self.menuChangeTabTitle = menuChangeTabTitle
        menuChangeTabTitle.keyEquivalentModifierMask = []
        let menuChangeTitle = shortcut("prompt_surface_title", viewMenu.addItem(withTitle: "Change Terminal Title...", action: NSSelectorFromString("changeTitle:"), keyEquivalent: ""))
        menuChangeTitle.keyEquivalentModifierMask = []
        let menuReadonly = viewMenu.addItem(withTitle: "Terminal Read-only", action: NSSelectorFromString("toggleReadonly:"), keyEquivalent: "")
        self.menuReadonly = menuReadonly
        menuReadonly.keyEquivalentModifierMask = []
        viewMenu.addItem(.separator())
        let menuQuickTerminal = shortcut("toggle_quick_terminal", viewMenu.addItem(withTitle: "Quick Terminal", action: NSSelectorFromString("toggleQuickTerminal:"), keyEquivalent: ""))
        self.menuQuickTerminal = menuQuickTerminal
        menuQuickTerminal.target = self
        menuQuickTerminal.keyEquivalentModifierMask = []
        viewMenu.addItem(.separator())
        let menuTerminalInspector = shortcut("inspector:toggle", viewMenu.addItem(withTitle: "Terminal Inspector", action: NSSelectorFromString("toggleTerminalInspector:"), keyEquivalent: ""))
        self.menuTerminalInspector = menuTerminalInspector
        menuTerminalInspector.keyEquivalentModifierMask = []

        let windowMenu = NSMenu(title: "Window")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        _ = windowMenu.addItem(withTitle: "Minimize", action: NSSelectorFromString("performMiniaturize:"), keyEquivalent: "m")
        let item45 = windowMenu.addItem(withTitle: "Zoom", action: NSSelectorFromString("performZoom:"), keyEquivalent: "")
        item45.keyEquivalentModifierMask = []
        windowMenu.addItem(.separator())
        // Keep the macOS fullscreen equivalent; config bindings still work in the core.
        // Replacing this key equivalent disables the system fullscreen shortcut.
        let menuToggleFullScreen = windowMenu.addItem(withTitle: "Toggle Full Screen", action: NSSelectorFromString("toggleGhosttyFullScreen:"), keyEquivalent: "f")
        self.menuToggleFullScreen = menuToggleFullScreen
        menuToggleFullScreen.keyEquivalentModifierMask = [.control, .command]
        let menuToggleVisibility = shortcut("toggle_visibility", windowMenu.addItem(withTitle: "Show/Hide All Terminals", action: NSSelectorFromString("toggleVisibility:"), keyEquivalent: ""))
        self.menuToggleVisibility = menuToggleVisibility
        menuToggleVisibility.target = self
        menuToggleVisibility.keyEquivalentModifierMask = []
        windowMenu.addItem(.separator())
        let menuZoomSplit = shortcut("toggle_split_zoom", windowMenu.addItem(withTitle: "Zoom Split", action: NSSelectorFromString("splitZoom:"), keyEquivalent: ""))
        self.menuZoomSplit = menuZoomSplit
        menuZoomSplit.keyEquivalentModifierMask = []
        let menuPreviousSplit = shortcut("goto_split:previous", windowMenu.addItem(withTitle: "Select Previous Split", action: NSSelectorFromString("splitMoveFocusPrevious:"), keyEquivalent: ""))
        self.menuPreviousSplit = menuPreviousSplit
        menuPreviousSplit.keyEquivalentModifierMask = []
        let menuNextSplit = shortcut("goto_split:next", windowMenu.addItem(withTitle: "Select Next Split", action: NSSelectorFromString("splitMoveFocusNext:"), keyEquivalent: ""))
        self.menuNextSplit = menuNextSplit
        menuNextSplit.keyEquivalentModifierMask = []
        let item51 = windowMenu.addItem(withTitle: "Select Split", action: nil, keyEquivalent: "")
        item51.keyEquivalentModifierMask = []
        let item51Submenu = NSMenu(title: "Select Split")
        item51.submenu = item51Submenu
        let menuSelectSplitAbove = shortcut("goto_split:up", item51Submenu.addItem(withTitle: "Select Split Above", action: NSSelectorFromString("splitMoveFocusAbove:"), keyEquivalent: ""))
        self.menuSelectSplitAbove = menuSelectSplitAbove
        menuSelectSplitAbove.keyEquivalentModifierMask = []
        let menuSelectSplitBelow = shortcut("goto_split:down", item51Submenu.addItem(withTitle: "Select Split Below", action: NSSelectorFromString("splitMoveFocusBelow:"), keyEquivalent: ""))
        self.menuSelectSplitBelow = menuSelectSplitBelow
        menuSelectSplitBelow.keyEquivalentModifierMask = []
        let menuSelectSplitLeft = shortcut("goto_split:left", item51Submenu.addItem(withTitle: "Select Split Left", action: NSSelectorFromString("splitMoveFocusLeft:"), keyEquivalent: ""))
        self.menuSelectSplitLeft = menuSelectSplitLeft
        menuSelectSplitLeft.keyEquivalentModifierMask = []
        let menuSelectSplitRight = shortcut("goto_split:right", item51Submenu.addItem(withTitle: "Select Split Right", action: NSSelectorFromString("splitMoveFocusRight:"), keyEquivalent: ""))
        self.menuSelectSplitRight = menuSelectSplitRight
        menuSelectSplitRight.keyEquivalentModifierMask = []
        let item56 = windowMenu.addItem(withTitle: "Resize Split", action: nil, keyEquivalent: "")
        item56.keyEquivalentModifierMask = []
        let item56Submenu = NSMenu(title: "Resize Split")
        item56.submenu = item56Submenu
        let menuEqualizeSplits = shortcut("equalize_splits", item56Submenu.addItem(withTitle: "Equalize Splits", action: NSSelectorFromString("equalizeSplits:"), keyEquivalent: ""))
        self.menuEqualizeSplits = menuEqualizeSplits
        menuEqualizeSplits.keyEquivalentModifierMask = []
        item56Submenu.addItem(.separator())
        let menuMoveSplitDividerUp = shortcut("resize_split:up,10", item56Submenu.addItem(withTitle: "Move Divider Up", action: NSSelectorFromString("moveSplitDividerUp:"), keyEquivalent: ""))
        self.menuMoveSplitDividerUp = menuMoveSplitDividerUp
        menuMoveSplitDividerUp.keyEquivalentModifierMask = []
        let menuMoveSplitDividerDown = shortcut("resize_split:down,10", item56Submenu.addItem(withTitle: "Move Divider Down", action: NSSelectorFromString("moveSplitDividerDown:"), keyEquivalent: ""))
        self.menuMoveSplitDividerDown = menuMoveSplitDividerDown
        menuMoveSplitDividerDown.keyEquivalentModifierMask = []
        let menuMoveSplitDividerLeft = shortcut("resize_split:left,10", item56Submenu.addItem(withTitle: "Move Divider Left", action: NSSelectorFromString("moveSplitDividerLeft:"), keyEquivalent: ""))
        self.menuMoveSplitDividerLeft = menuMoveSplitDividerLeft
        menuMoveSplitDividerLeft.keyEquivalentModifierMask = []
        let menuMoveSplitDividerRight = shortcut("resize_split:right,10", item56Submenu.addItem(withTitle: "Move Divider Right", action: NSSelectorFromString("moveSplitDividerRight:"), keyEquivalent: ""))
        self.menuMoveSplitDividerRight = menuMoveSplitDividerRight
        menuMoveSplitDividerRight.keyEquivalentModifierMask = []
        windowMenu.addItem(.separator())
        let menuReturnToDefaultSize = shortcut("reset_window_size", windowMenu.addItem(withTitle: "Return To Default Size", action: NSSelectorFromString("returnToDefaultSize:"), keyEquivalent: ""))
        menuReturnToDefaultSize.keyEquivalentModifierMask = []
        windowMenu.addItem(.separator())
        let menuFloatOnTop = shortcut("toggle_window_float_on_top", windowMenu.addItem(withTitle: "Float on Top", action: NSSelectorFromString("floatOnTop:"), keyEquivalent: ""))
        self.menuFloatOnTop = menuFloatOnTop
        menuFloatOnTop.target = self
        menuFloatOnTop.keyEquivalentModifierMask = []
        let menuUseAsDefault = windowMenu.addItem(withTitle: "Use as Default", action: NSSelectorFromString("useAsDefault:"), keyEquivalent: "")
        self.menuUseAsDefault = menuUseAsDefault
        menuUseAsDefault.target = self
        menuUseAsDefault.keyEquivalentModifierMask = []
        windowMenu.addItem(.separator())
        let menuBringAllToFront = windowMenu.addItem(withTitle: "Bring All to Front", action: NSSelectorFromString("arrangeInFront:"), keyEquivalent: "")
        self.menuBringAllToFront = menuBringAllToFront
        menuBringAllToFront.keyEquivalentModifierMask = []

        let helpMenu = NSMenu(title: "Help")
        main.addItem(withTitle: "Help", action: nil, keyEquivalent: "").submenu = helpMenu
        NSApp.helpMenu = helpMenu
        let item66 = helpMenu.addItem(withTitle: "cghostty Help", action: NSSelectorFromString("showHelp:"), keyEquivalent: "?")
        item66.target = self

        NSApp.mainMenu = main
        NSApp.servicesMenu = menuServices
    }
}
