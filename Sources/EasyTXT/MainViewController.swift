import AppKit
import Foundation

@MainActor
final class MainViewController: NSViewController, NSTabViewDelegate, EditorTabControllerDelegate, ProjectSearchViewControllerDelegate {
    private let settingsStore = SettingsStore()
    private let apiKeyStore = APIKeyStore()
    private let sessionStore = SessionStore()
    private let recoveryStore = RecoveryStore()
    private let historyStore = HistoryStore()
    private let fileService = FileService()

    private let tabView = ClickableTabView()
    private let projectSearch = ProjectSearchViewController()
    private var sidebarWidth: NSLayoutConstraint?
    private var watchers: [UUID: FileWatcher] = [:]
    private var pendingExternalReloadPrompt: Set<UUID> = []
    private var tabCloseMouseMonitor: Any?
    private var sessionPersistWorkItem: DispatchWorkItem?

    private let encodingOptions: [(title: String, value: String.Encoding)] = [
        ("UTF-8", .utf8),
        ("UTF-16", .utf16),
        ("Latin-1", .isoLatin1),
        ("Windows-1252", .windowsCP1252),
    ]

    private let encodingPopup = NSPopUpButton()
    private let lineEndingPopup = NSPopUpButton()
    private let aiPopup = NSPopUpButton()
    private let modePopup = NSPopUpButton()
    private let fontFamilyPopup = NSPopUpButton()
    private let fontSizeLabel = NSTextField(labelWithString: "")
    private let lineNumbersToggle = NSButton(checkboxWithTitle: "Line #", target: nil, action: nil)
    private let preferredWorkFonts: [String] = [
        "SF Mono",
        "Menlo",
        "Monaco",
        "JetBrains Mono",
        "Fira Code",
        "Source Code Pro",
        "IBM Plex Mono",
        "Courier Prime",
        "Courier New",
    ]
    private var availableWorkFonts: [String] = []
    private var compactToolbarButtons: [NSButton] = []
    private var isToolbarCompact = false

    override func loadView() {
        view = NSView()
        buildUI()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        AppPaths.ensureDirectories()
        restoreSessionOrCreateDefault()
        applyAppAppearance(settingsStore.preferences.theme)
        refreshFontSizeLabel()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        applyAppAppearance(settingsStore.preferences.theme)
        installTabCloseMonitorIfNeeded()
        updateToolbarCompactModeIfNeeded()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateToolbarCompactModeIfNeeded()
    }

    func persistSession() {
        var tabStates: [SessionTabState] = []

        for controller in allTabControllers() {
            let document = controller.document
            if document.isDirty || document.fileURL == nil {
                document.draftURL = recoveryStore.saveDraft(for: document)
            } else {
                recoveryStore.removeDraft(at: document.draftURL)
                document.draftURL = nil
            }

            let state = SessionTabState(
                filePath: document.fileURL?.path,
                draftPath: document.draftURL?.path,
                encodingRawValue: document.encoding.rawValue,
                lineEnding: document.lineEnding,
                customTitle: document.customTitle,
                format: document.format
            )
            tabStates.append(state)
        }

        let selected = tabView.selectedTabViewItem.map { max(tabView.indexOfTabViewItem($0), 0) } ?? 0
        sessionStore.save(SessionState(tabs: tabStates, selectedIndex: selected))
    }

    func flushSessionPersistence() {
        sessionPersistWorkItem?.cancel()
        sessionPersistWorkItem = nil
        persistSession()
    }

    func newDocument() {
        addTab(document: DocumentBuffer(), select: true)
    }

    func openDocument() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            openDocument(at: url, jumpTo: nil)
        }
    }

    func saveDocument() {
        guard let controller = selectedTabController() else {
            return
        }

        if controller.document.fileURL == nil {
            saveDocumentAs()
            return
        }

        do {
            controller.document.format = DocumentFormat.from(url: controller.document.fileURL)
            try fileService.saveDocument(controller.document)
            controller.document.markClean()
            historyStore.snapshot(document: controller.document)
            recoveryStore.removeDraft(at: controller.document.draftURL)
            updateTabTitle(for: controller)
            scheduleSessionPersistence(delay: 0.05)
        } catch {
            showError(error)
        }
    }

    func saveDocumentAs() {
        guard let controller = selectedTabController() else {
            return
        }

        let panel = NSSavePanel()
        panel.title = "Guardar como"
        panel.nameFieldStringValue = defaultSaveFilename(for: controller.document)
        panel.canSelectHiddenExtension = true

        let formatChoices = DocumentFormat.allCases
        let selectedFormat = controller.document.fileURL.map(DocumentFormat.from(url:)) ?? controller.document.format
        let formatPopup = NSPopUpButton()
        formatPopup.addItems(withTitles: formatChoices.map { "\($0.displayName) (.\($0.fileExtension))" })
        if let index = formatChoices.firstIndex(of: selectedFormat) {
            formatPopup.selectItem(at: index)
        }

        let accessory = NSStackView(views: [labelView("Formato"), formatPopup])
        accessory.orientation = .vertical
        accessory.spacing = 6
        accessory.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 0, right: 0)
        panel.accessoryView = accessory

        if panel.runModal() == .OK, let url = panel.url {
            let selectedIndex = formatPopup.indexOfSelectedItem
            let format = formatChoices.indices.contains(selectedIndex) ? formatChoices[selectedIndex] : selectedFormat
            let destination = saveURL(from: url, for: format)

            controller.document.fileURL = destination
            controller.document.format = format
            saveDocument()
            installWatcher(for: controller)
        }
    }

    func closeCurrentTab() {
        guard let selected = tabView.selectedTabViewItem else {
            return
        }
        closeTabViewItem(selected)
    }

    func showFind() {
        selectedTabController()?.showFindBar(replace: false)
    }

    func showReplace() {
        selectedTabController()?.showFindBar(replace: true)
    }

    func undoEdit() {
        selectedTabController()?.undoEdit()
    }

    func redoEdit() {
        selectedTabController()?.redoEdit()
    }

    func cutSelection() {
        selectedTabController()?.cutSelection()
    }

    func copySelection() {
        selectedTabController()?.copySelection()
    }

    func pasteClipboard() {
        selectedTabController()?.pasteClipboard()
    }

    func selectAllText() {
        selectedTabController()?.selectAllText()
    }

    func duplicateLine() {
        selectedTabController()?.duplicateLine()
    }

    func moveLineUp() {
        selectedTabController()?.moveLine(up: true)
    }

    func moveLineDown() {
        selectedTabController()?.moveLine(up: false)
    }

    func toggleComment() {
        selectedTabController()?.toggleComment()
    }

    func toggleSplitEditor() {
        selectedTabController()?.toggleSplit()
    }

    func toggleProjectSearch() {
        guard let sidebarWidth else {
            return
        }

        let isHidden = sidebarWidth.constant == 0
        sidebarWidth.constant = isHidden ? 360 : 0
        projectSearch.view.isHidden = !isHidden
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
    }

    func switchRenderMode(to mode: EditorRenderMode) {
        selectedTabController()?.setRenderMode(mode)
        refreshInspectorState()
    }

    func setTheme(_ theme: EditorTheme) {
        var prefs = settingsStore.preferences
        prefs.theme = theme
        settingsStore.preferences = prefs
        applyAppAppearance(theme)
        applyPreferencesToAllTabs()
    }

    func increaseFontSize() {
        var prefs = settingsStore.preferences
        prefs.fontSize = min(prefs.fontSize + 1, 30)
        settingsStore.preferences = prefs
        applyPreferencesToAllTabs()
        refreshFontSizeLabel()
    }

    func decreaseFontSize() {
        var prefs = settingsStore.preferences
        prefs.fontSize = max(prefs.fontSize - 1, 10)
        settingsStore.preferences = prefs
        applyPreferencesToAllTabs()
        refreshFontSizeLabel()
    }

    func toggleLineNumbers() {
        var prefs = settingsStore.preferences
        prefs.lineNumbersEnabled.toggle()
        settingsStore.preferences = prefs
        lineNumbersToggle.state = prefs.lineNumbersEnabled ? .on : .off
        allTabControllers().forEach { $0.setLineNumbersVisible(prefs.lineNumbersEnabled) }
    }

    func openFontPicker() {
        let prefs = settingsStore.preferences
        let options = resolvedWorkFonts(current: prefs.fontName)
        guard !options.isEmpty else {
            return
        }

        let alert = NSAlert()
        alert.messageText = "Fuente de trabajo"
        alert.informativeText = "Elige la fuente para editar texto."
        alert.addButton(withTitle: "Aplicar")
        alert.addButton(withTitle: "Cancelar")

        let popup = NSPopUpButton()
        popup.addItems(withTitles: options)
        if let index = options.firstIndex(of: prefs.fontName) {
            popup.selectItem(at: index)
        } else {
            popup.selectItem(at: 0)
        }
        popup.frame = NSRect(x: 0, y: 0, width: 260, height: 26)
        alert.accessoryView = popup

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        let selectedIndex = popup.indexOfSelectedItem
        guard options.indices.contains(selectedIndex) else {
            return
        }
        let selectedFont = options[selectedIndex]
        var updated = prefs
        updated.fontName = selectedFont
        settingsStore.preferences = updated
        configureFontFamilyPopup(using: updated)
        applyPreferencesToAllTabs()
    }

    func insertSnippet(at index: Int) {
        let snippets = settingsStore.snippets
        guard snippets.indices.contains(index) else {
            return
        }
        selectedTabController()?.insertSnippet(snippets[index])
    }

    func runMacroCleanupWhitespace() {
        selectedTabController()?.runMacroCleanupWhitespace()
    }

    func runMacroIdeasList() {
        selectedTabController()?.runMacroIdeasList()
    }

    func insertImage() {
        selectedTabController()?.insertImageFromPanel()
    }

    func resizeSelectedImage() {
        selectedTabController()?.resizeSelectedImage()
    }

    func restoreLatestSnapshot() {
        selectedTabController()?.restoreLastSnapshot(historyStore)
    }

    func runAI(task: AITask) {
        let provider = settingsStore.aiProvider
        let model = settingsStore.model(for: provider)
        let key = apiKeyStore.key(for: provider) ?? ""
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            openAISettings()
            showError(AIClientError.missingAPIKey(provider: provider))
            return
        }
        let config = AIConfiguration(provider: provider, model: model, apiKey: key)
        selectedTabController()?.runAI(task, configuration: config)
    }

    private func buildUI() {
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.delegate = self
        tabView.onSelectedTabClicked = { [weak self] in
            self?.renameCurrentUntitledIfNeeded()
        }
        tabView.onCloseTabRequested = { [weak self] item in
            self?.closeTabViewItem(item)
        }

        projectSearch.delegate = self
        addChild(projectSearch)
        projectSearch.view.translatesAutoresizingMaskIntoConstraints = false
        projectSearch.setFolder(settingsStore.preferredSearchFolder)

        let topBar = NSStackView()
        topBar.orientation = .horizontal
        topBar.spacing = 8
        topBar.translatesAutoresizingMaskIntoConstraints = false

        let newButton = makeToolbarButton(title: "New", symbol: "doc.badge.plus", action: #selector(newAction))
        let openButton = makeToolbarButton(title: "Open", symbol: "folder", action: #selector(openAction))
        let saveButton = makeToolbarButton(title: "Save", symbol: "square.and.arrow.down", action: #selector(saveAction))
        let undoButton = makeToolbarButton(title: "Undo", symbol: "arrow.uturn.backward", action: #selector(undoAction))
        let redoButton = makeToolbarButton(title: "Redo", symbol: "arrow.uturn.forward", action: #selector(redoAction))
        let findButton = makeToolbarButton(title: "Find", symbol: "magnifyingglass", action: #selector(findAction))
        let splitButton = makeToolbarButton(title: "Split", symbol: "rectangle.split.2x1", action: #selector(splitAction))
        let imageButton = makeToolbarButton(title: "Image", symbol: "photo", action: #selector(insertImageAction))
        let searchButton = makeToolbarButton(title: "Project", symbol: "folder.badge.magnifyingglass", action: #selector(projectAction))
        let aiSettingsButton = makeToolbarButton(title: "AI Settings", symbol: "sparkles", action: #selector(aiSettingsAction))
        let fontDownButton = makeToolbarButton(title: "A-", symbol: "textformat.size.smaller", action: #selector(fontDownAction))
        let fontUpButton = makeToolbarButton(title: "A+", symbol: "textformat.size.larger", action: #selector(fontUpAction))
        compactToolbarButtons = [
            newButton,
            openButton,
            saveButton,
            undoButton,
            redoButton,
            findButton,
            splitButton,
            imageButton,
            searchButton,
            aiSettingsButton,
            fontDownButton,
            fontUpButton,
        ]
        compactToolbarButtons.forEach {
            $0.alternateTitle = $0.title
            $0.toolTip = $0.title
        }

        modePopup.addItems(withTitles: ["Text", "Split Preview"])
        modePopup.target = self
        modePopup.action = #selector(modeChanged)
        setPopupItemIcon(modePopup, index: 0, symbol: "text.alignleft")
        setPopupItemIcon(modePopup, index: 1, symbol: "rectangle.split.2x1.fill")

        encodingPopup.addItems(withTitles: encodingOptions.map { $0.title })
        encodingPopup.target = self
        encodingPopup.action = #selector(encodingChanged)
        setPopupItemIcon(encodingPopup, index: 0, symbol: "doc.text")
        setPopupItemIcon(encodingPopup, index: 1, symbol: "doc.text")
        setPopupItemIcon(encodingPopup, index: 2, symbol: "doc.text")
        setPopupItemIcon(encodingPopup, index: 3, symbol: "doc.text")

        lineEndingPopup.addItems(withTitles: LineEnding.allCases.map { $0.rawValue })
        lineEndingPopup.target = self
        lineEndingPopup.action = #selector(lineEndingChanged)
        setPopupItemIcon(lineEndingPopup, index: 0, symbol: "arrow.down.to.line")
        setPopupItemIcon(lineEndingPopup, index: 1, symbol: "arrow.down.to.line")

        let prefs = settingsStore.preferences
        configureFontFamilyPopup(using: prefs)
        lineNumbersToggle.target = self
        lineNumbersToggle.action = #selector(toggleLineNumbersAction)
        lineNumbersToggle.state = prefs.lineNumbersEnabled ? .on : .off
        lineNumbersToggle.alternateTitle = "Line #"
        lineNumbersToggle.toolTip = "Toggle line numbers"
        lineNumbersToggle.image = symbolImage("list.number")
        lineNumbersToggle.imagePosition = .imageLeading
        fontSizeLabel.font = .systemFont(ofSize: 11, weight: .medium)
        fontSizeLabel.textColor = .secondaryLabelColor
        refreshFontSizeLabel()

        topBar.addArrangedSubview(newButton)
        topBar.addArrangedSubview(openButton)
        topBar.addArrangedSubview(saveButton)
        topBar.addArrangedSubview(undoButton)
        topBar.addArrangedSubview(redoButton)
        topBar.addArrangedSubview(findButton)
        topBar.addArrangedSubview(splitButton)
        topBar.addArrangedSubview(imageButton)
        topBar.addArrangedSubview(searchButton)
        topBar.addArrangedSubview(aiSettingsButton)
        topBar.addArrangedSubview(NSView())
        topBar.addArrangedSubview(lineNumbersToggle)
        topBar.addArrangedSubview(fontFamilyPopup)
        topBar.addArrangedSubview(fontDownButton)
        topBar.addArrangedSubview(fontSizeLabel)
        topBar.addArrangedSubview(fontUpButton)
        preserveToolbarItemSizing(for: topBar.arrangedSubviews)

        let contentRow = NSView()
        contentRow.translatesAutoresizingMaskIntoConstraints = false
        contentRow.addSubview(projectSearch.view)
        contentRow.addSubview(tabView)

        view.addSubview(topBar)
        view.addSubview(contentRow)

        sidebarWidth = projectSearch.view.widthAnchor.constraint(equalToConstant: 0)
        sidebarWidth?.isActive = true
        projectSearch.view.isHidden = true

        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            topBar.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),

            contentRow.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentRow.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentRow.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 10),
            contentRow.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            projectSearch.view.leadingAnchor.constraint(equalTo: contentRow.leadingAnchor),
            projectSearch.view.topAnchor.constraint(equalTo: contentRow.topAnchor),
            projectSearch.view.bottomAnchor.constraint(equalTo: contentRow.bottomAnchor),

            tabView.leadingAnchor.constraint(equalTo: projectSearch.view.trailingAnchor),
            tabView.trailingAnchor.constraint(equalTo: contentRow.trailingAnchor),
            tabView.topAnchor.constraint(equalTo: contentRow.topAnchor),
            tabView.bottomAnchor.constraint(equalTo: contentRow.bottomAnchor),
        ])
    }

    private func restoreSessionOrCreateDefault() {
        guard let session = sessionStore.load(), !session.tabs.isEmpty else {
            newDocument()
            scheduleSessionPersistence(delay: 0.05)
            return
        }

        for tab in session.tabs {
            let encoding = String.Encoding(rawValue: tab.encodingRawValue)
            let draftURL = tab.draftPath.map { URL(fileURLWithPath: $0) }
            let fileURL = tab.filePath.map { URL(fileURLWithPath: $0) }
            let storedFormat = fileURL.map(DocumentFormat.from(url:)) ?? tab.format
            var content = NSAttributedString(string: "")
            var isDirty = false

            if let draftURL, let draftText = recoveryStore.readDraft(at: draftURL) {
                content = draftText
                isDirty = true
            } else if let fileURL {
                switch storedFormat {
                case .richText:
                    if let data = try? Data(contentsOf: fileURL),
                       let richText = try? NSAttributedString(
                           data: data,
                           options: [.documentType: NSAttributedString.DocumentType.rtf],
                           documentAttributes: nil
                       )
                    {
                        content = richText
                    }
                case .plainText, .markdown:
                    if let data = try? Data(contentsOf: fileURL),
                       let decoded = String(data: data, encoding: encoding) ?? String(data: data, encoding: .utf8)
                    {
                        content = NSAttributedString(string: decoded)
                    }
                }
            }

            let document = DocumentBuffer(
                fileURL: fileURL,
                customTitle: tab.customTitle,
                attributedText: content,
                format: storedFormat,
                encoding: encoding,
                lineEnding: tab.lineEnding,
                isDirty: isDirty
            )
            document.draftURL = draftURL
            addTab(document: document, select: false)
        }

        let selectedIndex = min(max(session.selectedIndex, 0), tabView.numberOfTabViewItems - 1)
        tabView.selectTabViewItem(at: selectedIndex)
        refreshInspectorState()
        scheduleSessionPersistence(delay: 0.05)
    }

    private func addTab(document: DocumentBuffer, select: Bool) {
        let controller = EditorTabController(document: document, preferences: settingsStore.preferences)
        controller.delegate = self
        let item = NSTabViewItem(viewController: controller)
        item.label = tabLabel(for: document)
        tabView.addTabViewItem(item)

        if select {
            tabView.selectTabViewItem(item)
        }

        installWatcher(for: controller)
        refreshInspectorState()
        scheduleSessionPersistence(delay: 0.1)
    }

    private func allTabControllers() -> [EditorTabController] {
        tabView.tabViewItems.compactMap { $0.viewController as? EditorTabController }
    }

    private func selectedTabController() -> EditorTabController? {
        tabView.selectedTabViewItem?.viewController as? EditorTabController
    }

    private func updateTabTitle(for controller: EditorTabController) {
        guard let item = tabView.tabViewItems.first(where: { $0.viewController === controller }) else {
            return
        }
        item.label = tabLabel(for: controller.document)
    }

    private func closeTabViewItem(_ item: NSTabViewItem) {
        guard let controller = item.viewController as? EditorTabController else {
            return
        }

        if controller.document.isDirty {
            let alert = NSAlert()
            alert.messageText = "Hay cambios sin guardar"
            alert.informativeText = "¿Cerrar la pestaña igualmente?"
            alert.addButton(withTitle: "Cerrar")
            alert.addButton(withTitle: "Cancelar")
            if alert.runModal() != .alertFirstButtonReturn {
                return
            }
        }

        recoveryStore.removeDraft(at: controller.document.draftURL)
        watchers[controller.document.id] = nil
        tabView.removeTabViewItem(item)

        if tabView.numberOfTabViewItems == 0 {
            newDocument()
        }

        refreshInspectorState()
        scheduleSessionPersistence(delay: 0.05)
    }

    private func tabLabel(for document: DocumentBuffer) -> String {
        document.displayTitle() + "  ×"
    }

    private func installTabCloseMonitorIfNeeded() {
        guard tabCloseMouseMonitor == nil else {
            return
        }

        tabCloseMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self,
                  let window = self.view.window,
                  event.window === window
            else {
                return event
            }

            let pointInTabs = self.tabView.convert(event.locationInWindow, from: nil)
            guard let item = self.tabView.tabViewItem(at: pointInTabs) else {
                return event
            }

            if self.shouldCloseTab(item, at: pointInTabs, event: event) {
                self.closeTabViewItem(item)
                return nil
            }
            return event
        }
    }

    private func shouldCloseTab(_ item: NSTabViewItem, at point: NSPoint, event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.option) {
            return true
        }
        guard let tabRect = tabRect(of: item), tabRect.width > 24 else {
            return false
        }
        let closeWidth: CGFloat = min(22, max(14, tabRect.width * 0.26))
        let closeRect = NSRect(
            x: tabRect.maxX - closeWidth,
            y: tabRect.minY,
            width: closeWidth,
            height: tabRect.height
        )
        return closeRect.contains(point)
    }

    private func tabRect(of item: NSTabViewItem) -> NSRect? {
        if let buttonRect = tabButtonRect(of: item) {
            return buttonRect
        }

        let selectors = [
            "_tabRectForTabViewItem:",
            "rectOfTabViewItem:",
        ]
        for name in selectors {
            let selector = NSSelectorFromString(name)
            guard tabView.responds(to: selector), let imp = tabView.method(for: selector) else {
                continue
            }
            typealias Fn = @convention(c) (AnyObject, Selector, AnyObject) -> NSRect
            let function = unsafeBitCast(imp, to: Fn.self)
            let rect = function(tabView, selector, item)
            if rect.width > 0, rect.height > 0 {
                return rect
            }
        }
        return nil
    }

    private func tabButtonRect(of item: NSTabViewItem) -> NSRect? {
        let selector = NSSelectorFromString("_tabViewButtons")
        guard tabView.responds(to: selector),
              let imp = tabView.method(for: selector)
        else {
            return nil
        }

        typealias Fn = @convention(c) (AnyObject, Selector) -> AnyObject?
        let function = unsafeBitCast(imp, to: Fn.self)
        guard let rawButtons = function(tabView, selector) else {
            return nil
        }

        let index = tabView.indexOfTabViewItem(item)
        guard index != NSNotFound else {
            return nil
        }

        if let buttons = rawButtons as? [NSView], buttons.indices.contains(index) {
            return buttons[index].frame
        }
        if let buttons = rawButtons as? NSArray,
           index < buttons.count,
           let buttonView = buttons[index] as? NSView
        {
            return buttonView.frame
        }
        return nil
    }

    private func applyPreferencesToAllTabs() {
        let prefs = settingsStore.preferences
        lineNumbersToggle.state = prefs.lineNumbersEnabled ? .on : .off
        allTabControllers().forEach { $0.applyPreferences(prefs) }
    }

    private func openDocument(at url: URL, jumpTo: ProjectSearchMatch?) {
        if let existing = allTabControllers().first(where: { $0.document.fileURL == url }),
           let item = tabView.tabViewItems.first(where: { $0.viewController === existing })
        {
            tabView.selectTabViewItem(item)
            if let jumpTo {
                existing.setSelection(line: jumpTo.line, column: jumpTo.column)
            }
            return
        }

        fileService.loadDocument(from: url) { [weak self] result in
            guard let self else {
                return
            }

            switch result {
            case .failure(let error):
                self.showError(error)
            case .success(let loaded):
                if loaded.isLargeFile {
                    let alert = NSAlert()
                    alert.messageText = "Archivo grande"
                    alert.informativeText = "Este archivo pesa \(Self.formatBytes(loaded.fileSize)). Se abrirá en modo optimizado."
                    alert.runModal()
                }

                let document = DocumentBuffer(
                    fileURL: url,
                    attributedText: loaded.attributedText,
                    format: loaded.format,
                    encoding: loaded.encoding,
                    lineEnding: loaded.lineEnding,
                    isDirty: false
                )
                self.addTab(document: document, select: true)
                if let jumpTo {
                    self.selectedTabController()?.setSelection(line: jumpTo.line, column: jumpTo.column)
                }
            }
        }
    }

    private func installWatcher(for controller: EditorTabController) {
        watchers[controller.document.id] = nil

        guard let fileURL = controller.document.fileURL else {
            return
        }

        watchers[controller.document.id] = FileWatcher(url: fileURL) { [weak self, weak controller] in
            DispatchQueue.main.async {
                guard let self, let controller else {
                    return
                }
                self.promptExternalReloadIfNeeded(for: controller)
            }
        }
    }

    private func promptExternalReloadIfNeeded(for controller: EditorTabController) {
        let docID = controller.document.id
        if pendingExternalReloadPrompt.contains(docID) {
            return
        }

        pendingExternalReloadPrompt.insert(docID)
        defer { pendingExternalReloadPrompt.remove(docID) }

        let alert = NSAlert()
        alert.messageText = "El archivo cambió fuera de EasyTXT"
        alert.informativeText = "¿Quieres recargarlo ahora?"
        alert.addButton(withTitle: "Recargar")
        alert.addButton(withTitle: "Ignorar")

        if alert.runModal() != .alertFirstButtonReturn {
            return
        }

        guard let fileURL = controller.document.fileURL else {
            return
        }

        fileService.loadDocument(from: fileURL, preferredEncoding: controller.encoding()) { result in
            switch result {
            case .failure(let error):
                self.showError(error)
            case .success(let loaded):
                controller.updateEncoding(loaded.encoding)
                controller.updateLineEnding(loaded.lineEnding)
                controller.replaceContentFromDisk(loaded)
                self.updateTabTitle(for: controller)
                self.scheduleSessionPersistence(delay: 0.1)
            }
        }
    }

    private func refreshInspectorState() {
        guard let selected = selectedTabController() else {
            return
        }

        let prefs = settingsStore.preferences
        lineNumbersToggle.state = prefs.lineNumbersEnabled ? .on : .off
        refreshFontSizeLabel()

        let encoding = selected.encoding()
        if let index = encodingOptions.firstIndex(where: { $0.value == encoding }) {
            encodingPopup.selectItem(at: index)
        }

        if let lineEndingIndex = LineEnding.allCases.firstIndex(of: selected.lineEnding()) {
            lineEndingPopup.selectItem(at: lineEndingIndex)
        }

        modePopup.selectItem(at: selected.currentRenderMode() == .text ? 0 : 1)
    }

    func editorTabNeedsTitleUpdate(_ controller: EditorTabController) {
        updateTabTitle(for: controller)
        refreshInspectorState()
        scheduleSessionPersistence()
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        refreshInspectorState()
        scheduleSessionPersistence(delay: 0.2)
    }

    func projectSearch(_ controller: ProjectSearchViewController, didSelect result: ProjectSearchMatch) {
        settingsStore.preferredSearchFolder = controller.selectedFolderURL()
        openDocument(at: result.fileURL, jumpTo: result)
    }

    @objc private func newAction() { newDocument() }
    @objc private func openAction() { openDocument() }
    @objc private func saveAction() { saveDocument() }
    @objc private func undoAction() { undoEdit() }
    @objc private func redoAction() { redoEdit() }
    @objc private func findAction() { showFind() }
    @objc private func splitAction() { toggleSplitEditor() }
    @objc private func insertImageAction() { insertImage() }
    @objc private func projectAction() { toggleProjectSearch() }
    @objc private func aiSettingsAction() { openAISettings() }
    @objc private func fontDownAction() { decreaseFontSize() }
    @objc private func fontUpAction() { increaseFontSize() }
    @objc private func toggleLineNumbersAction() { toggleLineNumbers() }
    @objc private func fontFamilyChanged() {
        let index = fontFamilyPopup.indexOfSelectedItem
        guard availableWorkFonts.indices.contains(index) else {
            return
        }

        let selectedFont = availableWorkFonts[index]
        var prefs = settingsStore.preferences
        guard prefs.fontName != selectedFont else {
            return
        }
        prefs.fontName = selectedFont
        settingsStore.preferences = prefs
        applyPreferencesToAllTabs()
    }

    @objc private func modeChanged() {
        switch modePopup.indexOfSelectedItem {
        case 1:
            switchRenderMode(to: .splitPreview)
        default:
            switchRenderMode(to: .text)
        }
    }

    @objc private func encodingChanged() {
        guard let selected = selectedTabController() else {
            return
        }
        let index = encodingPopup.indexOfSelectedItem
        guard encodingOptions.indices.contains(index) else {
            return
        }
        selected.updateEncoding(encodingOptions[index].value)
        scheduleSessionPersistence(delay: 0.2)
    }

    @objc private func lineEndingChanged() {
        guard let selected = selectedTabController() else {
            return
        }
        let index = lineEndingPopup.indexOfSelectedItem
        guard LineEnding.allCases.indices.contains(index) else {
            return
        }
        selected.updateLineEnding(LineEnding.allCases[index])
        scheduleSessionPersistence(delay: 0.2)
    }

    @objc private func aiAction() {
        defer {
            aiPopup.selectItem(at: 0)
        }

        switch aiPopup.indexOfSelectedItem {
        case 1:
            runAI(task: .correct)
        case 2:
            runAI(task: .expand)
        case 3:
            runAI(task: .ideate)
        default:
            break
        }
    }

    func openAISettings() {
        let alert = NSAlert()
        alert.messageText = "AI Settings"
        alert.informativeText = "Configura proveedor, modelo y claves seguras por proveedor."
        alert.addButton(withTitle: "Guardar")
        alert.addButton(withTitle: "Cancelar")

        let currentProvider = settingsStore.aiProvider
        let anthropicOptions = AIProvider.anthropic.modelOptions
        let openAIOptions = AIProvider.openAI.modelOptions

        let providerPopup = NSPopUpButton()
        providerPopup.addItems(withTitles: AIProvider.allCases.map(\.displayName))
        if let selectedIndex = AIProvider.allCases.firstIndex(of: currentProvider) {
            providerPopup.selectItem(at: selectedIndex)
        }
        providerPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let anthropicModelPopup = NSPopUpButton()
        anthropicModelPopup.addItems(withTitles: anthropicOptions.map {
            "\($0.title)\($0.recommended ? " · recomendado" : "")"
        })
        let selectedAnthropicModel = settingsStore.model(for: .anthropic)
        if let idx = anthropicOptions.firstIndex(where: { $0.id == selectedAnthropicModel }) {
            anthropicModelPopup.selectItem(at: idx)
        } else {
            anthropicModelPopup.selectItem(at: 0)
        }
        anthropicModelPopup.itemArray.enumerated().forEach { index, item in
            guard anthropicOptions.indices.contains(index) else {
                return
            }
            let option = anthropicOptions[index]
            item.toolTip = "\(option.summary)\nID: \(option.id)"
        }
        anthropicModelPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let openAIModelPopup = NSPopUpButton()
        openAIModelPopup.addItems(withTitles: openAIOptions.map {
            "\($0.title)\($0.recommended ? " · recomendado" : "")"
        })
        let selectedOpenAIModel = settingsStore.model(for: .openAI)
        if let idx = openAIOptions.firstIndex(where: { $0.id == selectedOpenAIModel }) {
            openAIModelPopup.selectItem(at: idx)
        } else {
            openAIModelPopup.selectItem(at: 0)
        }
        openAIModelPopup.itemArray.enumerated().forEach { index, item in
            guard openAIOptions.indices.contains(index) else {
                return
            }
            let option = openAIOptions[index]
            item.toolTip = "\(option.summary)\nID: \(option.id)"
        }
        openAIModelPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let anthropicHint = labelView("Sonnet: equilibrado · Opus: máxima calidad · Haiku: rápido")
        anthropicHint.textColor = .tertiaryLabelColor
        let openAIHint = labelView("GPT-5: general · Mini/Nano: rápido · o3/o4-mini: razonamiento")
        openAIHint.textColor = .tertiaryLabelColor

        let anthropicKeyField = NSSecureTextField(string: "")
        anthropicKeyField.placeholderString = "Nueva key de Claude (vacío = no cambiar)"
        anthropicKeyField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let openAIKeyField = NSSecureTextField(string: "")
        openAIKeyField.placeholderString = "Nueva key de OpenAI (vacío = no cambiar)"
        openAIKeyField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let clearAnthropicKey = NSButton(checkboxWithTitle: "Eliminar clave guardada de Claude", target: nil, action: nil)
        let clearOpenAIKey = NSButton(checkboxWithTitle: "Eliminar clave guardada de OpenAI", target: nil, action: nil)

        let securityNote = labelView("Seguridad: claves en Keychain local y nunca visibles en texto plano.")
        securityNote.maximumNumberOfLines = 2
        securityNote.lineBreakMode = .byWordWrapping

        let stack = NSStackView(views: [
            labelView("Proveedor activo (AI Correct / Expand / Idea)"),
            providerPopup,
            labelView("Claude (Anthropic)"),
            anthropicModelPopup,
            anthropicHint,
            labelView("Clave de Claude"),
            anthropicKeyField,
            clearAnthropicKey,
            labelView("OpenAI"),
            openAIModelPopup,
            openAIHint,
            labelView("Clave de OpenAI"),
            openAIKeyField,
            clearOpenAIKey,
            securityNote,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 370))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            providerPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 340),
            anthropicModelPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 340),
            openAIModelPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 340),
            anthropicKeyField.widthAnchor.constraint(greaterThanOrEqualToConstant: 340),
            openAIKeyField.widthAnchor.constraint(greaterThanOrEqualToConstant: 340),
        ])

        alert.accessoryView = container

        if alert.runModal() != .alertFirstButtonReturn {
            return
        }

        let providerIndex = providerPopup.indexOfSelectedItem
        let provider = AIProvider.allCases.indices.contains(providerIndex) ? AIProvider.allCases[providerIndex] : .anthropic

        let selectedAnthropicIndex = min(max(anthropicModelPopup.indexOfSelectedItem, 0), max(anthropicOptions.count - 1, 0))
        let selectedOpenAIIndex = min(max(openAIModelPopup.indexOfSelectedItem, 0), max(openAIOptions.count - 1, 0))
        guard anthropicOptions.indices.contains(selectedAnthropicIndex), openAIOptions.indices.contains(selectedOpenAIIndex) else {
            return
        }

        let anthropicModel = anthropicOptions[selectedAnthropicIndex].id
        let openAIModel = openAIOptions[selectedOpenAIIndex].id

        settingsStore.aiProvider = provider
        settingsStore.setModel(anthropicModel, for: .anthropic)
        settingsStore.setModel(openAIModel, for: .openAI)

        let anthropicKey = anthropicKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !anthropicKey.isEmpty {
            apiKeyStore.save(anthropicKey, for: .anthropic)
        } else if clearAnthropicKey.state == .on {
            apiKeyStore.deleteKey(for: .anthropic)
        }

        let openAIKey = openAIKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !openAIKey.isEmpty {
            apiKeyStore.save(openAIKey, for: .openAI)
        } else if clearOpenAIKey.state == .on {
            apiKeyStore.deleteKey(for: .openAI)
        }
    }

    private func renameCurrentUntitledIfNeeded() {
        guard let controller = selectedTabController() else {
            return
        }
        guard controller.document.fileURL == nil else {
            return
        }

        let alert = NSAlert()
        alert.messageText = "Renombrar nota"
        alert.informativeText = "Este nombre es local para la pestaña hasta guardar el archivo."
        alert.addButton(withTitle: "Guardar")
        alert.addButton(withTitle: "Cancelar")

        let textField = NSTextField(string: controller.document.customTitle ?? "")
        textField.placeholderString = "Nombre de la nota"
        textField.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = textField

        if alert.runModal() != .alertFirstButtonReturn {
            return
        }

        let raw = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        controller.document.customTitle = raw.isEmpty ? nil : raw
        updateTabTitle(for: controller)
        scheduleSessionPersistence(delay: 0.1)
    }

    private func defaultSaveFilename(for document: DocumentBuffer) -> String {
        if let existing = document.fileURL?.lastPathComponent {
            return existing
        }

        let preferredFormat = document.format
        let base = document.displayName
        let cleaned = sanitizeFilename(base)
        if cleaned.isEmpty || cleaned == "Untitled" {
            return "note.\(preferredFormat.fileExtension)"
        }

        let ext = URL(fileURLWithPath: cleaned).pathExtension.lowercased()
        let knownExtensions = Set(DocumentFormat.allCases.map(\.fileExtension))
        if knownExtensions.contains(ext) {
            return cleaned
        }
        return cleaned + ".\(preferredFormat.fileExtension)"
    }

    private func saveURL(from chosenURL: URL, for format: DocumentFormat) -> URL {
        let current = chosenURL.pathExtension.lowercased()
        if current == format.fileExtension {
            return chosenURL
        }

        let knownExtensions = Set(DocumentFormat.allCases.map(\.fileExtension))
        let baseURL: URL
        if knownExtensions.contains(current) {
            baseURL = chosenURL.deletingPathExtension()
        } else {
            baseURL = chosenURL
        }
        return baseURL.appendingPathExtension(format.fileExtension)
    }

    private func sanitizeFilename(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let scalars = value.unicodeScalars.map { forbidden.contains($0) ? "_" : Character($0) }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func applyAppAppearance(_ theme: EditorTheme) {
        let appearance: NSAppearance?
        switch theme {
        case .light:
            appearance = NSAppearance(named: .aqua)
        case .dark:
            appearance = NSAppearance(named: .darkAqua)
        }
        view.appearance = appearance
        view.window?.appearance = appearance
    }

    private func refreshFontSizeLabel() {
        let size = Int(round(settingsStore.preferences.fontSize))
        fontSizeLabel.stringValue = "\(size)pt"
    }

    private func updateToolbarCompactModeIfNeeded() {
        let compact = view.bounds.width < 1260
        guard compact != isToolbarCompact else {
            return
        }
        isToolbarCompact = compact

        compactToolbarButtons.forEach { button in
            if compact {
                button.title = ""
                button.imagePosition = .imageOnly
            } else {
                button.title = button.alternateTitle
                button.imagePosition = .imageLeading
            }
        }

        if compact {
            lineNumbersToggle.title = ""
            lineNumbersToggle.imagePosition = .imageOnly
            fontFamilyPopup.isHidden = true
            fontSizeLabel.isHidden = true
        } else {
            lineNumbersToggle.title = lineNumbersToggle.alternateTitle
            lineNumbersToggle.imagePosition = .imageLeading
            fontFamilyPopup.isHidden = false
            fontSizeLabel.isHidden = false
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }

    private func scheduleSessionPersistence(delay: TimeInterval = 0.35) {
        sessionPersistWorkItem?.cancel()

        let item = DispatchWorkItem { [weak self] in
            self?.persistSession()
        }
        sessionPersistWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func labelView(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.textColor = .secondaryLabelColor
        field.font = .systemFont(ofSize: 11)
        return field
    }

    private func makeToolbarButton(title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        if let image = symbolImage(symbol) {
            button.image = image
            button.imagePosition = .imageLeading
        }
        return button
    }

    private func symbolImage(_ name: String) -> NSImage? {
        let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        return base?.withSymbolConfiguration(config)
    }

    private func setPopupItemIcon(_ popup: NSPopUpButton, index: Int, symbol: String) {
        guard let item = popup.item(at: index), let image = symbolImage(symbol) else {
            return
        }
        item.image = image
    }

    private func preserveToolbarItemSizing(for views: [NSView]) {
        views.forEach {
            if $0 is NSButton || $0 is NSPopUpButton || $0 is NSTextField {
                $0.setContentCompressionResistancePriority(.required, for: .horizontal)
                $0.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            }
        }
    }

    private func configureFontFamilyPopup(using preferences: EditorPreferences) {
        let available = resolvedWorkFonts(current: preferences.fontName)
        availableWorkFonts = available

        fontFamilyPopup.removeAllItems()
        fontFamilyPopup.addItems(withTitles: available)
        fontFamilyPopup.target = self
        fontFamilyPopup.action = #selector(fontFamilyChanged)
        fontFamilyPopup.toolTip = "Fuente de trabajo"
        fontFamilyPopup.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        fontFamilyPopup.setContentCompressionResistancePriority(.required, for: .horizontal)

        if let selectedIndex = available.firstIndex(of: preferences.fontName) {
            fontFamilyPopup.selectItem(at: selectedIndex)
        } else if !available.isEmpty {
            fontFamilyPopup.selectItem(at: 0)
            var updated = preferences
            updated.fontName = available[0]
            settingsStore.preferences = updated
            applyPreferencesToAllTabs()
        }
    }

    private func resolvedWorkFonts(current: String) -> [String] {
        var fonts = preferredWorkFonts.filter { NSFont(name: $0, size: 13) != nil }
        if NSFont(name: current, size: 13) != nil, !fonts.contains(current) {
            fonts.insert(current, at: 0)
        }
        if fonts.isEmpty {
            fonts = ["Menlo", NSFont.monospacedSystemFont(ofSize: 13, weight: .regular).fontName]
        }
        return Array(NSOrderedSet(array: fonts)) as? [String] ?? fonts
    }
}
