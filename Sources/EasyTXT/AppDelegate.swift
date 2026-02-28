import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let mainViewController = MainViewController()
        let windowController = MainWindowController(mainViewController: mainViewController)
        self.windowController = windowController

        applyBundledIcon()
        buildMenu()
        windowController.showWindow(self)
        windowController.window?.makeKeyAndOrderFront(self)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowController?.mainViewController.flushSessionPersistence()
    }

    func applicationDidResignActive(_ notification: Notification) {
        windowController?.mainViewController.flushSessionPersistence()
    }

    private func applyBundledIcon() {
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let iconImage = NSImage(contentsOf: iconURL)
        else {
            return
        }
        NSApp.applicationIconImage = iconImage
        windowController?.window?.miniwindowImage = iconImage
    }

    private func buildMenu() {
        let main = NSMenu()
        NSApp.mainMenu = main

        let appMenuItem = NSMenuItem()
        main.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        let aboutItem = appMenu.addItem(withTitle: "About EasyTXT · 686f6c61", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        setMenuIcon(aboutItem, "info.circle")
        appMenu.addItem(.separator())
        let quitItem = appMenu.addItem(withTitle: "Quit EasyTXT", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        setMenuIcon(quitItem, "power")

        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        let newItem = fileMenu.addItem(withTitle: "New", action: #selector(newDocument), keyEquivalent: "n")
        setMenuIcon(newItem, "doc.badge.plus")
        let openItem = fileMenu.addItem(withTitle: "Open...", action: #selector(openDocument), keyEquivalent: "o")
        setMenuIcon(openItem, "folder")
        fileMenu.addItem(.separator())
        let saveItem = fileMenu.addItem(withTitle: "Save", action: #selector(saveDocument), keyEquivalent: "s")
        setMenuIcon(saveItem, "square.and.arrow.down")
        let saveAsItem = fileMenu.addItem(withTitle: "Save As...", action: #selector(saveDocumentAs), keyEquivalent: "S")
        setMenuIcon(saveAsItem, "square.and.arrow.down.on.square")
        fileMenu.addItem(.separator())
        let closeTabItem = fileMenu.addItem(withTitle: "Close Tab", action: #selector(closeTab), keyEquivalent: "w")
        setMenuIcon(closeTabItem, "xmark.circle")

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        let undoItem = editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        setMenuIcon(undoItem, "arrow.uturn.backward")
        let redoItem = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        setMenuIcon(redoItem, "arrow.uturn.forward")
        editMenu.addItem(.separator())
        let cutItem = editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        setMenuIcon(cutItem, "scissors")
        let copyItem = editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        setMenuIcon(copyItem, "doc.on.doc")
        let pasteItem = editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        setMenuIcon(pasteItem, "clipboard")
        editMenu.addItem(.separator())
        let findItem = editMenu.addItem(withTitle: "Find", action: #selector(showFind), keyEquivalent: "f")
        setMenuIcon(findItem, "magnifyingglass")
        let replaceItem = editMenu.addItem(withTitle: "Replace", action: #selector(showReplace), keyEquivalent: "F")
        setMenuIcon(replaceItem, "arrow.triangle.2.circlepath")
        editMenu.addItem(.separator())
        let insertImageItem = editMenu.addItem(withTitle: "Insert Image...", action: #selector(insertImage), keyEquivalent: "i")
        insertImageItem.keyEquivalentModifierMask = [.command, .shift]
        setMenuIcon(insertImageItem, "photo")
        let resizeImageItem = editMenu.addItem(withTitle: "Resize Selected Image...", action: #selector(resizeSelectedImage), keyEquivalent: "i")
        resizeImageItem.keyEquivalentModifierMask = [.command, .option]
        setMenuIcon(resizeImageItem, "arrow.up.left.and.arrow.down.right")
        editMenu.addItem(.separator())
        let duplicateItem = editMenu.addItem(withTitle: "Duplicate Line", action: #selector(duplicateLine), keyEquivalent: "d")
        setMenuIcon(duplicateItem, "plus.square.on.square")
        let moveUpItem = editMenu.addItem(withTitle: "Move Line Up", action: #selector(moveLineUp), keyEquivalent: "\u{F700}")
        moveUpItem.keyEquivalentModifierMask = [.command, .option]
        setMenuIcon(moveUpItem, "arrow.up")
        let moveDownItem = editMenu.addItem(withTitle: "Move Line Down", action: #selector(moveLineDown), keyEquivalent: "\u{F701}")
        moveDownItem.keyEquivalentModifierMask = [.command, .option]
        setMenuIcon(moveDownItem, "arrow.down")
        let toggleCommentItem = editMenu.addItem(withTitle: "Toggle Comment", action: #selector(toggleComment), keyEquivalent: "/")
        setMenuIcon(toggleCommentItem, "number")

        let snippetMenuItem = NSMenuItem(title: "Insert Snippet", action: nil, keyEquivalent: "")
        let snippetMenu = NSMenu(title: "Insert Snippet")
        snippetMenuItem.submenu = snippetMenu
        setMenuIcon(snippetMenuItem, "text.badge.plus")
        let todoSnippet = snippetMenu.addItem(withTitle: "TODO", action: #selector(insertSnippetTodo), keyEquivalent: "1")
        setMenuIcon(todoSnippet, "checklist")
        let stampSnippet = snippetMenu.addItem(withTitle: "Timestamp", action: #selector(insertSnippetTimestamp), keyEquivalent: "2")
        setMenuIcon(stampSnippet, "calendar")
        let mermaidSnippet = snippetMenu.addItem(withTitle: "Mermaid Flow", action: #selector(insertSnippetMermaid), keyEquivalent: "3")
        setMenuIcon(mermaidSnippet, "point.topleft.down.curvedto.point.bottomright.up")
        let markdownSnippet = snippetMenu.addItem(withTitle: "Markdown Note", action: #selector(insertSnippetMarkdown), keyEquivalent: "4")
        setMenuIcon(markdownSnippet, "textformat")
        editMenu.addItem(snippetMenuItem)

        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        let splitItem = viewMenu.addItem(withTitle: "Toggle Split", action: #selector(toggleSplit), keyEquivalent: "s")
        splitItem.keyEquivalentModifierMask = [.command, .option]
        setMenuIcon(splitItem, "rectangle.split.2x1")
        let projectItem = viewMenu.addItem(withTitle: "Toggle Project Search", action: #selector(toggleProjectSearch), keyEquivalent: "f")
        projectItem.keyEquivalentModifierMask = [.command, .shift]
        setMenuIcon(projectItem, "folder.badge.magnifyingglass")
        let lineNumberItem = viewMenu.addItem(withTitle: "Toggle Line Numbers", action: #selector(toggleLineNumbers), keyEquivalent: "l")
        lineNumberItem.keyEquivalentModifierMask = [.command, .option]
        setMenuIcon(lineNumberItem, "list.number")
        viewMenu.addItem(.separator())
        let textModeItem = viewMenu.addItem(withTitle: "Text Mode", action: #selector(textMode), keyEquivalent: "1")
        textModeItem.keyEquivalentModifierMask = [.command, .option]
        setMenuIcon(textModeItem, "text.alignleft")
        let splitPreviewItem = viewMenu.addItem(withTitle: "Split Preview Mode", action: #selector(renderedMode), keyEquivalent: "2")
        splitPreviewItem.keyEquivalentModifierMask = [.command, .option]
        setMenuIcon(splitPreviewItem, "rectangle.split.2x1.fill")

        let themeMenuItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        let themeMenu = NSMenu(title: "Theme")
        themeMenuItem.submenu = themeMenu
        setMenuIcon(themeMenuItem, "paintpalette")
        let lightThemeItem = themeMenu.addItem(withTitle: "Light", action: #selector(themeLight), keyEquivalent: "")
        setMenuIcon(lightThemeItem, "sun.max")
        let darkThemeItem = themeMenu.addItem(withTitle: "Dark", action: #selector(themeDark), keyEquivalent: "")
        setMenuIcon(darkThemeItem, "moon")
        viewMenu.addItem(themeMenuItem)

        let increaseFontItem = viewMenu.addItem(withTitle: "Increase Font", action: #selector(increaseFont), keyEquivalent: "+")
        setMenuIcon(increaseFontItem, "textformat.size.larger")
        let decreaseFontItem = viewMenu.addItem(withTitle: "Decrease Font", action: #selector(decreaseFont), keyEquivalent: "-")
        setMenuIcon(decreaseFontItem, "textformat.size.smaller")
        let fontFamilyItem = viewMenu.addItem(withTitle: "Working Font...", action: #selector(chooseWorkFont), keyEquivalent: "t")
        fontFamilyItem.keyEquivalentModifierMask = [.command, .option]
        setMenuIcon(fontFamilyItem, "textformat")

        let toolsItem = NSMenuItem()
        main.addItem(toolsItem)
        let toolsMenu = NSMenu(title: "Tools")
        toolsItem.submenu = toolsMenu
        let aiCorrectItem = toolsMenu.addItem(withTitle: "AI Correct", action: #selector(aiCorrect), keyEquivalent: "")
        setMenuIcon(aiCorrectItem, "checkmark.bubble")
        let aiExpandItem = toolsMenu.addItem(withTitle: "AI Expand", action: #selector(aiExpand), keyEquivalent: "")
        setMenuIcon(aiExpandItem, "arrow.up.left.and.arrow.down.right")
        let aiIdeaItem = toolsMenu.addItem(withTitle: "AI Idea", action: #selector(aiIdea), keyEquivalent: "")
        setMenuIcon(aiIdeaItem, "lightbulb")
        let aiSettingsItem = toolsMenu.addItem(withTitle: "AI Settings", action: #selector(aiSettings), keyEquivalent: ",")
        setMenuIcon(aiSettingsItem, "gearshape")
        toolsMenu.addItem(.separator())
        let macroCleanupItem = toolsMenu.addItem(withTitle: "Macro: Cleanup Whitespace", action: #selector(macroCleanup), keyEquivalent: "")
        setMenuIcon(macroCleanupItem, "eraser")
        let macroIdeasItem = toolsMenu.addItem(withTitle: "Macro: Ideas to Bullets", action: #selector(macroIdeas), keyEquivalent: "")
        setMenuIcon(macroIdeasItem, "list.bullet")
        toolsMenu.addItem(.separator())
        let restoreItem = toolsMenu.addItem(withTitle: "Restore Last Snapshot", action: #selector(restoreSnapshot), keyEquivalent: "")
        setMenuIcon(restoreItem, "clock.arrow.circlepath")
    }

    private func mainVC() -> MainViewController? {
        windowController?.mainViewController
    }

    @objc private func newDocument() { mainVC()?.newDocument() }
    @objc private func openDocument() { mainVC()?.openDocument() }
    @objc private func saveDocument() { mainVC()?.saveDocument() }
    @objc private func saveDocumentAs() { mainVC()?.saveDocumentAs() }
    @objc private func closeTab() { mainVC()?.closeCurrentTab() }

    @objc private func showFind() { mainVC()?.showFind() }
    @objc private func showReplace() { mainVC()?.showReplace() }
    @objc private func insertImage() { mainVC()?.insertImage() }
    @objc private func resizeSelectedImage() { mainVC()?.resizeSelectedImage() }
    @objc private func duplicateLine() { mainVC()?.duplicateLine() }
    @objc private func moveLineUp() { mainVC()?.moveLineUp() }
    @objc private func moveLineDown() { mainVC()?.moveLineDown() }
    @objc private func toggleComment() { mainVC()?.toggleComment() }

    @objc private func insertSnippetTodo() { mainVC()?.insertSnippet(at: 0) }
    @objc private func insertSnippetTimestamp() { mainVC()?.insertSnippet(at: 1) }
    @objc private func insertSnippetMermaid() { mainVC()?.insertSnippet(at: 2) }
    @objc private func insertSnippetMarkdown() { mainVC()?.insertSnippet(at: 3) }

    @objc private func toggleSplit() { mainVC()?.toggleSplitEditor() }
    @objc private func toggleProjectSearch() { mainVC()?.toggleProjectSearch() }
    @objc private func toggleLineNumbers() { mainVC()?.toggleLineNumbers() }
    @objc private func textMode() { mainVC()?.switchRenderMode(to: .text) }
    @objc private func renderedMode() { mainVC()?.switchRenderMode(to: .splitPreview) }

    @objc private func themeLight() { mainVC()?.setTheme(.light) }
    @objc private func themeDark() { mainVC()?.setTheme(.dark) }
    @objc private func increaseFont() { mainVC()?.increaseFontSize() }
    @objc private func decreaseFont() { mainVC()?.decreaseFontSize() }
    @objc private func chooseWorkFont() { mainVC()?.openFontPicker() }

    @objc private func aiCorrect() { mainVC()?.runAI(task: .correct) }
    @objc private func aiExpand() { mainVC()?.runAI(task: .expand) }
    @objc private func aiIdea() { mainVC()?.runAI(task: .ideate) }
    @objc private func aiSettings() { mainVC()?.openAISettings() }

    @objc private func macroCleanup() { mainVC()?.runMacroCleanupWhitespace() }
    @objc private func macroIdeas() { mainVC()?.runMacroIdeasList() }
    @objc private func restoreSnapshot() { mainVC()?.restoreLatestSnapshot() }

    private func setMenuIcon(_ item: NSMenuItem, _ symbol: String) {
        guard let image = symbolImage(symbol) else {
            return
        }
        item.image = image
    }

    private func symbolImage(_ symbol: String) -> NSImage? {
        let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        return base?.withSymbolConfiguration(config)
    }
}
