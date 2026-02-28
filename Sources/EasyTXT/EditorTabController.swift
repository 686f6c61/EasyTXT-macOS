import AppKit
import Foundation
import WebKit

@MainActor
protocol EditorTabControllerDelegate: AnyObject {
    func editorTabNeedsTitleUpdate(_ controller: EditorTabController)
}

enum EditorRenderMode {
    case text
    case splitPreview
}

private extension NSAttributedString.Key {
    static let easyTXTPNGData = NSAttributedString.Key("easytxt.pngData")
}

private final class ImagePasteTextView: NSTextView {
    var onImagePaste: ((NSImage) -> Void)?

    override func paste(_ sender: Any?) {
        if let image = Self.extractImage(from: NSPasteboard.general) {
            onImagePaste?(image)
            return
        }

        let beforeLength = textStorage?.length ?? 0
        let beforeSelection = selectedRange()
        super.paste(sender)

        guard let storage = textStorage else {
            return
        }
        let afterLength = storage.length
        guard afterLength > beforeLength else {
            return
        }

        let insertedLength = afterLength - beforeLength
        let insertedLocation = min(beforeSelection.location, max(afterLength - 1, 0))
        let safeLength = min(insertedLength, afterLength - insertedLocation)
        guard safeLength > 0 else {
            return
        }

        let insertedRange = NSRange(location: insertedLocation, length: safeLength)
        guard let pasted = Self.firstImageAttachment(in: storage, range: insertedRange) else {
            return
        }

        storage.beginEditing()
        storage.deleteCharacters(in: pasted.range)
        storage.endEditing()
        setSelectedRange(NSRange(location: pasted.range.location, length: 0))
        onImagePaste?(pasted.image)
    }

    private static func extractImage(from pasteboard: NSPasteboard) -> NSImage? {
        if let directImage = NSImage(pasteboard: pasteboard) {
            return directImage
        }

        if let imageObjects = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let first = imageObjects.first
        {
            return first
        }

        let fileURLReadOptions: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: fileURLReadOptions) as? [URL] {
            for url in urls {
                if let image = NSImage(contentsOf: url) {
                    return image
                }
            }
        }

        if let rawFileURL = pasteboard.string(forType: .fileURL),
           let url = URL(string: rawFileURL),
           url.isFileURL,
           let image = NSImage(contentsOf: url)
        {
            return image
        }

        if let strings = pasteboard.readObjects(forClasses: [NSString.self], options: nil) as? [String] {
            for raw in strings {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if let fileURL = URL(string: trimmed), fileURL.isFileURL, let image = NSImage(contentsOf: fileURL) {
                    return image
                }
                let pathURL = URL(fileURLWithPath: trimmed)
                if FileManager.default.fileExists(atPath: pathURL.path), let image = NSImage(contentsOf: pathURL) {
                    return image
                }
            }
        }

        if let tiff = pasteboard.data(forType: .tiff), let image = NSImage(data: tiff) {
            return image
        }
        if let png = pasteboard.data(forType: .png), let image = NSImage(data: png) {
            return image
        }

        for item in pasteboard.pasteboardItems ?? [] {
            for type in item.types {
                if let data = item.data(forType: type), let image = NSImage(data: data) {
                    return image
                }
                if type == .fileURL,
                   let value = item.string(forType: type),
                   let url = URL(string: value),
                   url.isFileURL,
                   let image = NSImage(contentsOf: url)
                {
                    return image
                }
            }
        }

        return nil
    }

    private static func firstImageAttachment(
        in storage: NSTextStorage,
        range: NSRange
    ) -> (image: NSImage, range: NSRange)? {
        var result: (image: NSImage, range: NSRange)?
        storage.enumerateAttribute(.attachment, in: range, options: []) { value, attachmentRange, stop in
            guard let attachment = value as? NSTextAttachment,
                  let image = imageFromAttachment(attachment)
            else {
                return
            }
            result = (image: image, range: attachmentRange)
            stop.pointee = true
        }
        return result
    }

    private static func imageFromAttachment(_ attachment: NSTextAttachment) -> NSImage? {
        if let data = attachment.fileWrapper?.regularFileContents,
           let image = NSImage(data: data)
        {
            return image
        }
        if let wrappers = attachment.fileWrapper?.fileWrappers {
            for wrapper in wrappers.values {
                if let data = wrapper.regularFileContents,
                   let image = NSImage(data: data)
                {
                    return image
                }
            }
        }
        if let imageCell = attachment.attachmentCell as? NSTextAttachmentCell {
            return imageCell.image
        }
        return nil
    }
}

@MainActor
final class EditorTabController: NSViewController, NSTextViewDelegate {
    let document: DocumentBuffer
    weak var delegate: EditorTabControllerDelegate?

    private var preferences: EditorPreferences
    private var renderMode: EditorRenderMode = .text
    private var splitEnabled = false
    private var isProgrammaticUpdate = false
    private var previewRefreshWorkItem: DispatchWorkItem?
    private let maxInlineImageWidth: CGFloat = 900
    private let maxInlineImageHeight: CGFloat = 900

    private let findField = NSSearchField(string: "")
    private let replaceField = NSTextField(string: "")
    private let regexButton = NSButton(checkboxWithTitle: "Regex", target: nil, action: nil)
    private let caseButton = NSButton(checkboxWithTitle: "Aa", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let modeControl = NSSegmentedControl(labels: ["Text", "Split Preview"], trackingMode: .selectOne, target: nil, action: nil)

    private let findBar = NSStackView()
    private let contentSplitView = NSSplitView()
    private let textSplitView = NSSplitView()
    private let previewContainer = NSView()
    private var previewMinWidthConstraint: NSLayoutConstraint?

    private lazy var primaryTextView = makeTextView()
    private lazy var secondaryTextView = makeTextView()
    private lazy var primaryScrollView = makeScrollView(for: primaryTextView)
    private lazy var secondaryScrollView = makeScrollView(for: secondaryTextView)

    private let previewWebView = WKWebView(frame: .zero)

    init(document: DocumentBuffer, preferences: EditorPreferences) {
        self.document = document
        self.preferences = preferences
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        buildUI()
        setEditorAttributedText(document.attributedText, markDirty: false)
        applyPreferences(preferences)
        updateStatus()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(primaryTextView)
        updateTextSplitLayout()
    }

    func applyPreferences(_ preferences: EditorPreferences) {
        self.preferences = preferences

        let font = NSFont(name: preferences.fontName, size: preferences.fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: preferences.fontSize, weight: .regular)

        [primaryTextView, secondaryTextView].forEach {
            $0.font = font
            $0.backgroundColor = preferences.theme.backgroundColor
            $0.textColor = preferences.theme.textColor
            $0.selectedTextAttributes = [
                .backgroundColor: preferences.theme.selectionColor,
                .foregroundColor: preferences.theme.textColor,
            ]
            $0.insertionPointColor = preferences.theme.textColor
        }

        statusLabel.textColor = preferences.theme.secondaryTextColor
        setLineNumbersVisible(preferences.lineNumbersEnabled)
        refreshPreview()
    }

    func setRenderMode(_ mode: EditorRenderMode) {
        renderMode = mode
        modeControl.selectedSegment = mode == .text ? 0 : 1
        previewMinWidthConstraint?.isActive = mode == .splitPreview
        previewContainer.isHidden = mode == .text
        if mode == .splitPreview {
            DispatchQueue.main.async {
                let width = self.contentSplitView.bounds.width
                if width > 100 {
                    self.contentSplitView.setPosition(width * 0.57, ofDividerAt: 0)
                }
            }
            refreshPreview()
        } else {
            view.window?.makeFirstResponder(primaryTextView)
        }
    }

    func setLineNumbersVisible(_ visible: Bool) {
        [primaryScrollView, secondaryScrollView].forEach {
            $0.hasVerticalRuler = visible
            $0.rulersVisible = visible
        }
    }

    func toggleSplit() {
        splitEnabled.toggle()
        if splitEnabled {
            secondaryTextView.textStorage?.setAttributedString(primaryTextView.attributedString())
        }
        updateTextSplitLayout()
    }

    func showFindBar(replace: Bool) {
        findBar.isHidden = false
        replaceField.isHidden = !replace
        findField.becomeFirstResponder()
    }

    func cutSelection() {
        guard let textView = activeTextView() else {
            return
        }
        textView.cut(nil)
    }

    func copySelection() {
        guard let textView = activeTextView() else {
            return
        }
        textView.copy(nil)
    }

    func pasteClipboard() {
        guard let textView = activeTextView() else {
            return
        }
        textView.paste(nil)
    }

    func selectAllText() {
        guard let textView = activeTextView() else {
            return
        }
        textView.selectAll(nil)
        view.window?.makeFirstResponder(textView)
        updateStatus()
    }

    func hideFindBar() {
        findBar.isHidden = true
        view.window?.makeFirstResponder(primaryTextView)
    }

    func duplicateLine() {
        guard let textView = activeTextView() else {
            return
        }

        let nsText = textView.string as NSString
        let selected = textView.selectedRange()
        let lineRange = nsText.lineRange(for: selected)
        let line = nsText.substring(with: lineRange)
        let insertRange = NSRange(location: NSMaxRange(lineRange), length: 0)

        textView.textStorage?.beginEditing()
        textView.textStorage?.replaceCharacters(in: insertRange, with: line)
        textView.textStorage?.endEditing()
        textView.setSelectedRange(NSRange(location: insertRange.location, length: lineRange.length))
        syncModelFromEditor(textView)
    }

    func moveLine(up: Bool) {
        guard let textView = activeTextView() else {
            return
        }

        let nsText = textView.string as NSString
        let selected = textView.selectedRange()
        let currentLineRange = nsText.lineRange(for: selected)

        if up {
            if currentLineRange.location == 0 {
                NSSound.beep()
                return
            }
            let previousCursor = NSRange(location: currentLineRange.location - 1, length: 0)
            let previousLineRange = nsText.lineRange(for: previousCursor)
            swapLines(in: textView, first: previousLineRange, second: currentLineRange)
        } else {
            if NSMaxRange(currentLineRange) >= nsText.length {
                NSSound.beep()
                return
            }
            let nextCursor = NSRange(location: NSMaxRange(currentLineRange), length: 0)
            let nextLineRange = nsText.lineRange(for: nextCursor)
            if nextLineRange.location == currentLineRange.location {
                NSSound.beep()
                return
            }
            swapLines(in: textView, first: currentLineRange, second: nextLineRange)
        }
    }

    func toggleComment() {
        guard let textView = activeTextView() else {
            return
        }

        let nsText = textView.string as NSString
        let selected = textView.selectedRange()
        let expanded = nsText.lineRange(for: selected)
        let chunk = nsText.substring(with: expanded)

        let lines = chunk.components(separatedBy: "\n")
        let shouldUncomment = lines
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }

        let transformed = lines.map { line -> String in
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                return line
            }
            if shouldUncomment {
                return line.replacingOccurrences(of: "# ", with: "", options: [], range: line.range(of: "# "))
                    .replacingOccurrences(of: "#", with: "", options: [], range: line.range(of: "#"))
            }
            return "# " + line
        }.joined(separator: "\n")

        textView.textStorage?.replaceCharacters(in: expanded, with: transformed)
        textView.setSelectedRange(NSRange(location: expanded.location, length: (transformed as NSString).length))
        syncModelFromEditor(textView)
    }

    func insertSnippet(_ snippet: Snippet) {
        guard let textView = activeTextView() else {
            return
        }
        textView.insertText(snippet.body, replacementRange: textView.selectedRange())
        syncModelFromEditor(textView)
    }

    func runMacroCleanupWhitespace() {
        guard let textView = activeTextView() else {
            return
        }

        let normalized = textView.string
            .components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
            .joined(separator: "\n")

        setEditorText(normalized)
    }

    func runMacroIdeasList() {
        guard let textView = activeTextView() else {
            return
        }

        let selected = textView.selectedRange()
        guard selected.length > 0 else {
            NSSound.beep()
            return
        }

        let nsText = textView.string as NSString
        let raw = nsText.substring(with: selected)
        let lines = raw.components(separatedBy: "\n")
        let bulletized = lines.map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                return line
            }
            if trimmed.hasPrefix("- ") {
                return line
            }
            return "- " + trimmed
        }.joined(separator: "\n")

        textView.textStorage?.replaceCharacters(in: selected, with: bulletized)
        textView.setSelectedRange(NSRange(location: selected.location, length: (bulletized as NSString).length))
        syncModelFromEditor(textView)
    }

    func insertImageFromPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .heic, .gif, .tiff, .bmp, .webP]

        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else {
            return
        }
        insertImage(image, into: activeTextView())
    }

    func resizeSelectedImage() {
        guard let textView = activeTextView(),
              let (attachment, range) = selectedAttachment(in: textView),
              let image = imageFromAttachment(attachment)
        else {
            NSSound.beep()
            return
        }

        let currentSize = displayedSize(for: attachment, fallbackImage: image)
        let alert = NSAlert()
        alert.messageText = "Resize image"
        alert.informativeText = "Ancho actual: \(Int(currentSize.width)) px"
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")

        let widthField = NSTextField(string: String(Int(currentSize.width)))
        widthField.placeholderString = "Width in px"
        widthField.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
        alert.accessoryView = widthField

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        let requestedWidth = max(16, CGFloat(widthField.doubleValue))
        guard requestedWidth > 0 else {
            NSSound.beep()
            return
        }

        let aspectRatio = max(currentSize.height / max(currentSize.width, 1), 0.01)
        let targetSize = NSSize(width: requestedWidth, height: requestedWidth * aspectRatio)
        let resizedImage = resizedImage(image, to: targetSize)
        let replacement = attachmentString(for: resizedImage)

        textView.textStorage?.replaceCharacters(in: range, with: replacement)
        textView.setSelectedRange(NSRange(location: range.location + replacement.length, length: 0))
        syncModelFromEditor(textView)
    }

    func runAI(_ task: AITask, configuration: AIConfiguration) {
        guard let textView = activeTextView() else {
            return
        }

        let selectedRange = textView.selectedRange()
        let nsText = textView.string as NSString
        let source: String
        let targetRange: NSRange?

        if selectedRange.length > 0 {
            source = nsText.substring(with: selectedRange)
            targetRange = selectedRange
        } else {
            source = textView.string
            targetRange = nil
        }

        statusLabel.stringValue = "IA: \(task.title.lowercased())..."
        AIClient.shared.run(task: task, input: source, configuration: configuration) { [weak self] result in
            guard let self else {
                return
            }

            switch result {
            case .success(let output):
                let normalized = Self.normalizedAIOutput(output)
                guard !normalized.isEmpty else {
                    self.statusLabel.stringValue = "IA sin cambios"
                    return
                }
                self.applyAIOutput(normalized, targetRange: targetRange)
                self.statusLabel.stringValue = "IA aplicada"
            case .failure(let error):
                self.statusLabel.stringValue = "Error IA"
                self.showError(error)
            }
        }
    }

    func restoreLastSnapshot(_ historyStore: HistoryStore) {
        guard let fileURL = document.fileURL,
              let snapshot = historyStore.latestSnapshot(for: fileURL)
        else {
            NSSound.beep()
            return
        }
        setEditorAttributedText(snapshot)
    }

    func setSelection(line: Int, column: Int) {
        guard line >= 1, column >= 1 else {
            return
        }

        let lines = primaryTextView.string.components(separatedBy: "\n")
        guard line <= lines.count else {
            return
        }

        let prefix = lines.prefix(line - 1).joined(separator: "\n")
        let offset = prefix.isEmpty ? 0 : (prefix as NSString).length + 1
        let lineLength = (lines[line - 1] as NSString).length
        let target = min(offset + column - 1, offset + lineLength)

        let range = NSRange(location: target, length: 0)
        primaryTextView.setSelectedRange(range)
        primaryTextView.scrollRangeToVisible(range)
        view.window?.makeFirstResponder(primaryTextView)
        updateStatus()
    }

    func updateEncoding(_ encoding: String.Encoding) {
        document.encoding = encoding
    }

    func updateLineEnding(_ lineEnding: LineEnding) {
        document.lineEnding = lineEnding
    }

    func replaceContentFromDisk(_ loaded: LoadedDocument) {
        setEditorAttributedText(loaded.attributedText, markDirty: false)
        document.format = loaded.format
        document.markClean()
    }

    func currentRenderMode() -> EditorRenderMode {
        renderMode
    }

    func encoding() -> String.Encoding {
        document.encoding
    }

    func lineEnding() -> LineEnding {
        document.lineEnding
    }

    func textDidChange(_ notification: Notification) {
        guard !isProgrammaticUpdate else {
            return
        }

        guard let textView = notification.object as? NSTextView else {
            return
        }

        syncModelFromEditor(textView)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        updateStatus()
    }

    private func buildUI() {
        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 8
        root.alignment = .leading
        root.translatesAutoresizingMaskIntoConstraints = false

        let modeLabel = NSTextField(labelWithString: "Mode")
        modeLabel.font = .systemFont(ofSize: 11)
        modeControl.target = self
        modeControl.action = #selector(changeRenderMode)
        modeControl.selectedSegment = 0

        let findToggle = NSButton(title: "Find", target: self, action: #selector(toggleFindBar))

        let header = NSStackView(views: [modeLabel, modeControl, NSView(), findToggle])
        header.orientation = .horizontal
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false

        buildFindBar()
        findBar.isHidden = true
        findBar.translatesAutoresizingMaskIntoConstraints = false

        contentSplitView.isVertical = true
        contentSplitView.dividerStyle = .thin
        contentSplitView.translatesAutoresizingMaskIntoConstraints = false

        textSplitView.isVertical = true
        textSplitView.dividerStyle = .thin
        textSplitView.translatesAutoresizingMaskIntoConstraints = false
        textSplitView.addArrangedSubview(primaryScrollView)
        textSplitView.addArrangedSubview(secondaryScrollView)
        secondaryScrollView.isHidden = true

        previewWebView.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(previewWebView)
        previewContainer.isHidden = true
        previewContainer.wantsLayer = true
        previewContainer.layer?.borderWidth = 1
        previewContainer.layer?.borderColor = NSColor.separatorColor.cgColor

        contentSplitView.addArrangedSubview(textSplitView)
        contentSplitView.addArrangedSubview(previewContainer)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.stringValue = "Ln 1, Col 1"
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        root.addArrangedSubview(header)
        root.addArrangedSubview(findBar)
        root.addArrangedSubview(contentSplitView)
        root.addArrangedSubview(statusLabel)

        view.addSubview(root)

        let findFieldMinWidth = findField.widthAnchor.constraint(greaterThanOrEqualToConstant: 140)
        findFieldMinWidth.priority = .defaultLow
        let replaceFieldMinWidth = replaceField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120)
        replaceFieldMinWidth.priority = .defaultLow

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),

            contentSplitView.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
            header.widthAnchor.constraint(equalTo: root.widthAnchor),
            findBar.widthAnchor.constraint(equalTo: root.widthAnchor),
            contentSplitView.widthAnchor.constraint(equalTo: root.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: root.widthAnchor),

            textSplitView.leadingAnchor.constraint(equalTo: contentSplitView.leadingAnchor),
            textSplitView.topAnchor.constraint(equalTo: contentSplitView.topAnchor),
            textSplitView.bottomAnchor.constraint(equalTo: contentSplitView.bottomAnchor),

            previewWebView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            previewWebView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            previewWebView.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            previewWebView.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),

            findFieldMinWidth,
            replaceFieldMinWidth,
        ])

        previewMinWidthConstraint = previewContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 300)
        previewMinWidthConstraint?.isActive = false

        updateTextSplitLayout()
    }

    private func buildFindBar() {
        findField.placeholderString = "Find"
        replaceField.placeholderString = "Replace"

        let nextButton = NSButton(title: "Next", target: self, action: #selector(findNext))
        let replaceButton = NSButton(title: "Replace", target: self, action: #selector(replaceOne))
        let allButton = NSButton(title: "Replace All", target: self, action: #selector(replaceAll))
        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeFindBar))

        findBar.orientation = .horizontal
        findBar.spacing = 8
        findBar.addArrangedSubview(findField)
        findBar.addArrangedSubview(replaceField)
        findBar.addArrangedSubview(regexButton)
        findBar.addArrangedSubview(caseButton)
        findBar.addArrangedSubview(nextButton)
        findBar.addArrangedSubview(replaceButton)
        findBar.addArrangedSubview(allButton)
        findBar.addArrangedSubview(closeButton)
    }

    private func makeTextView() -> NSTextView {
        let textView = ImagePasteTextView(frame: .zero)
        textView.isRichText = true
        textView.importsGraphics = true
        textView.allowsImageEditing = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.delegate = self
        textView.autoresizingMask = [.width, .height]
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.usesFindPanel = true
        textView.onImagePaste = { [weak self, weak textView] image in
            self?.insertImage(image, into: textView)
        }
        return textView
    }

    private func makeScrollView(for textView: NSTextView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.documentView = textView
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        scroll.verticalRulerView = LineNumberRulerView(textView: textView)
        return scroll
    }

    private func syncModelFromEditor(_ textView: NSTextView) {
        let snapshot = textView.attributedString().copy() as? NSAttributedString ?? NSAttributedString(string: textView.string)
        mirrorText(toPeerOf: textView, content: snapshot)
        document.updateAttributedText(snapshot)
        delegate?.editorTabNeedsTitleUpdate(self)

        if renderMode == .splitPreview {
            schedulePreviewRefresh()
        }
        updateStatus()
    }

    private func mirrorText(toPeerOf source: NSTextView, content: NSAttributedString) {
        guard splitEnabled else {
            return
        }

        let peer: NSTextView
        if source == primaryTextView {
            peer = secondaryTextView
        } else {
            peer = primaryTextView
        }

        let selected = peer.selectedRange()
        isProgrammaticUpdate = true
        peer.textStorage?.setAttributedString(content)
        let maxLocation = max(0, peer.string.utf16.count)
        peer.setSelectedRange(NSRange(location: min(selected.location, maxLocation), length: 0))
        isProgrammaticUpdate = false
    }

    private func updateTextSplitLayout() {
        secondaryScrollView.isHidden = !splitEnabled
        textSplitView.adjustSubviews()

        DispatchQueue.main.async {
            let width = self.textSplitView.bounds.width
            guard width > 1 else {
                return
            }
            if self.splitEnabled {
                self.textSplitView.setPosition(width * 0.5, ofDividerAt: 0)
            } else {
                self.textSplitView.setPosition(width - 1, ofDividerAt: 0)
            }
        }
    }

    private func setEditorText(_ value: String, markDirty: Bool = true) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: primaryTextView.font ?? NSFont.monospacedSystemFont(ofSize: preferences.fontSize, weight: .regular),
            .foregroundColor: preferences.theme.textColor,
        ]
        let attributed = NSAttributedString(string: value, attributes: attributes)
        setEditorAttributedText(attributed, markDirty: markDirty)
    }

    private func setEditorAttributedText(_ value: NSAttributedString, markDirty: Bool = true) {
        let selectedPrimary = primaryTextView.selectedRange()
        let selectedSecondary = secondaryTextView.selectedRange()

        isProgrammaticUpdate = true
        primaryTextView.textStorage?.setAttributedString(value)
        secondaryTextView.textStorage?.setAttributedString(value)

        let maxPrimary = primaryTextView.string.utf16.count
        let maxSecondary = secondaryTextView.string.utf16.count
        primaryTextView.setSelectedRange(NSRange(location: min(selectedPrimary.location, maxPrimary), length: 0))
        secondaryTextView.setSelectedRange(NSRange(location: min(selectedSecondary.location, maxSecondary), length: 0))
        isProgrammaticUpdate = false

        document.updateAttributedText(value, markDirty: markDirty)
        delegate?.editorTabNeedsTitleUpdate(self)

        if renderMode == .splitPreview {
            schedulePreviewRefresh()
        }
        updateStatus()
    }

    private func schedulePreviewRefresh() {
        previewRefreshWorkItem?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.refreshPreview()
        }
        previewRefreshWorkItem = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: task)
    }

    private func refreshPreview() {
        guard renderMode == .splitPreview else {
            return
        }

        let html = Self.renderedHTML(for: document.text, theme: preferences.theme)
        let baseURL = document.fileURL?.deletingLastPathComponent()
        previewWebView.loadHTMLString(html, baseURL: baseURL)
    }

    private static func renderedHTML(for markdown: String, theme: EditorTheme) -> String {
        let source = jsonString(markdown)
        let textHex = theme.textColor.hexString()
        let backgroundHex = theme.backgroundColor.hexString()

        return """
        <!doctype html>
        <html>
        <head>
            <meta charset=\"utf-8\">
            <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
            <style>
                body {
                    margin: 0;
                    padding: 24px;
                    font-family: "Iowan Old Style", "Georgia", serif;
                    background: \(backgroundHex);
                    color: \(textHex);
                    line-height: 1.55;
                }
                pre {
                    background: rgba(0, 0, 0, 0.08);
                    padding: 12px;
                    border-radius: 10px;
                    overflow-x: auto;
                }
                code {
                    font-family: Menlo, monospace;
                }
                blockquote {
                    border-left: 4px solid rgba(120, 120, 120, 0.35);
                    margin: 0;
                    padding-left: 14px;
                    color: rgba(120, 120, 120, 0.95);
                }
                table {
                    border-collapse: collapse;
                }
                th, td {
                    border: 1px solid rgba(120,120,120,0.35);
                    padding: 6px 10px;
                }
            </style>
            <script src=\"https://cdn.jsdelivr.net/npm/marked/marked.min.js\"></script>
        </head>
        <body>
            <div id=\"output\"></div>
            <script type=\"module\">
                import mermaid from 'https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs';

                const source = \(source);
                const output = document.getElementById('output');

                if (window.marked) {
                    output.innerHTML = marked.parse(source, { gfm: true, breaks: true });
                } else {
                    output.textContent = source;
                }

                output.querySelectorAll('pre > code.language-mermaid').forEach(code => {
                    const pre = code.closest('pre');
                    const block = document.createElement('div');
                    block.className = 'mermaid';
                    block.textContent = code.textContent;
                    if (pre) {
                        pre.replaceWith(block);
                    }
                });

                mermaid.initialize({ startOnLoad: false, securityLevel: 'loose' });
                await mermaid.run({ querySelector: '.mermaid' });
            </script>
        </body>
        </html>
        """
    }

    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let encoded = String(data: data, encoding: .utf8)
        else {
            return "\"\""
        }
        return encoded
    }

    private func activeTextView() -> NSTextView? {
        if let responder = view.window?.firstResponder as? NSTextView {
            if responder == primaryTextView || responder == secondaryTextView {
                return responder
            }
        }
        return primaryTextView
    }

    private func swapLines(in textView: NSTextView, first: NSRange, second: NSRange) {
        let nsText = textView.string as NSString
        let firstText = nsText.substring(with: first)
        let secondText = nsText.substring(with: second)

        let mergedRange = NSRange(location: first.location, length: first.length + second.length)
        textView.textStorage?.replaceCharacters(in: mergedRange, with: secondText + firstText)

        let newSelectionLocation = second.location
        textView.setSelectedRange(NSRange(location: newSelectionLocation, length: second.length))
        syncModelFromEditor(textView)
    }

    private func updateStatus() {
        guard let textView = activeTextView() else {
            return
        }

        let selected = textView.selectedRange()
        let full = textView.string as NSString
        let safeLocation = min(selected.location, full.length)
        let prefix = full.substring(to: safeLocation)

        let lines = prefix.components(separatedBy: "\n")
        let line = lines.count
        let column = (lines.last?.count ?? 0) + 1

        statusLabel.stringValue = "Ln \(line), Col \(column) • \(full.length) chars"
    }

    private func currentSearchOptions() -> SearchOptions {
        SearchOptions(regex: regexButton.state == .on, caseSensitive: caseButton.state == .on)
    }

    @objc private func toggleFindBar() {
        findBar.isHidden.toggle()
        if !findBar.isHidden {
            findField.becomeFirstResponder()
        }
    }

    @objc private func closeFindBar() {
        hideFindBar()
    }

    @objc private func changeRenderMode() {
        setRenderMode(modeControl.selectedSegment == 0 ? .text : .splitPreview)
    }

    @objc private func findNext() {
        guard let textView = activeTextView() else {
            return
        }

        let query = findField.stringValue
        let matches = SearchEngine.ranges(in: textView.string, query: query, options: currentSearchOptions())
        guard !matches.isEmpty else {
            NSSound.beep()
            return
        }

        let current = textView.selectedRange()
        let next = matches.first(where: { $0.location > current.location }) ?? matches.first!
        textView.setSelectedRange(next)
        textView.scrollRangeToVisible(next)
        updateStatus()
    }

    @objc private func replaceOne() {
        guard let textView = activeTextView() else {
            return
        }

        findNext()
        let selected = textView.selectedRange()
        guard selected.length > 0 else {
            return
        }

        textView.textStorage?.replaceCharacters(in: selected, with: replaceField.stringValue)
        let newLength = (replaceField.stringValue as NSString).length
        textView.setSelectedRange(NSRange(location: selected.location, length: newLength))
        syncModelFromEditor(textView)
    }

    @objc private func replaceAll() {
        guard let textView = activeTextView() else {
            return
        }

        let source = textView.string
        let query = findField.stringValue
        let replacement = replaceField.stringValue
        let options = currentSearchOptions()

        guard !query.isEmpty else {
            return
        }

        if options.regex {
            let regexFlags: NSRegularExpression.Options = options.caseSensitive ? [] : [.caseInsensitive]
            guard let regex = try? NSRegularExpression(pattern: query, options: regexFlags) else {
                NSSound.beep()
                return
            }
            let ns = source as NSString
            let range = NSRange(location: 0, length: ns.length)
            let output = regex.stringByReplacingMatches(in: source, options: [], range: range, withTemplate: replacement)
            setEditorText(output)
            return
        }

        var output = source
        if options.caseSensitive {
            output = source.replacingOccurrences(of: query, with: replacement)
        } else {
            let regex = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: query), options: [.caseInsensitive])
            if let regex {
                let ns = source as NSString
                output = regex.stringByReplacingMatches(in: source, options: [], range: NSRange(location: 0, length: ns.length), withTemplate: replacement)
            }
        }

        setEditorText(output)
    }

    private func insertImage(_ image: NSImage, into textView: NSTextView?) {
        guard let textView = textView ?? activeTextView() else {
            return
        }

        let fitted = fitImageIfNeeded(
            image,
            maxWidth: maxAllowedImageWidth(for: textView),
            maxHeight: maxInlineImageHeight
        )
        let insertion = attachmentString(for: fitted)
        let range = textView.selectedRange()

        textView.textStorage?.replaceCharacters(in: range, with: insertion)
        textView.setSelectedRange(NSRange(location: range.location + insertion.length, length: 0))
        syncModelFromEditor(textView)
    }

    private func maxAllowedImageWidth(for textView: NSTextView) -> CGFloat {
        let visibleWidth = max(textView.bounds.width - 32, 220)
        return min(maxInlineImageWidth, visibleWidth)
    }

    private func attachmentString(for image: NSImage) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.attachmentCell = NSTextAttachmentCell(imageCell: image)

        let mutable = NSMutableAttributedString(attachment: attachment)
        if let pngData = image.pngRepresentation() {
            mutable.addAttribute(.easyTXTPNGData, value: pngData, range: NSRange(location: 0, length: 1))
        }
        mutable.append(NSAttributedString(string: "\n"))
        return mutable
    }

    private func fitImageIfNeeded(_ image: NSImage, maxWidth: CGFloat, maxHeight: CGFloat) -> NSImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else {
            return image
        }
        let ratio = min(maxWidth / size.width, maxHeight / size.height, 1)
        if ratio >= 0.999 {
            return image
        }
        let targetSize = NSSize(width: size.width * ratio, height: size.height * ratio)
        return resizedImage(image, to: targetSize)
    }

    private func resizedImage(_ image: NSImage, to targetSize: NSSize) -> NSImage {
        let output = NSImage(size: targetSize)
        output.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: targetSize), from: NSRect(origin: .zero, size: image.size), operation: .copy, fraction: 1)
        output.unlockFocus()
        return output
    }

    private func selectedAttachment(in textView: NSTextView) -> (NSTextAttachment, NSRange)? {
        guard let storage = textView.textStorage, storage.length > 0 else {
            return nil
        }

        let selection = textView.selectedRange()
        let start = max(0, min(selection.location, storage.length - 1))
        var candidates = [start]
        if start > 0 {
            candidates.append(start - 1)
        }

        for index in candidates {
            var effective = NSRange(location: 0, length: 0)
            if let attachment = storage.attribute(.attachment, at: index, effectiveRange: &effective) as? NSTextAttachment {
                return (attachment, effective)
            }
        }

        if selection.length > 0 {
            let selectionEnd = min(storage.length, selection.location + selection.length)
            if selection.location < selectionEnd {
                var found: (NSTextAttachment, NSRange)?
                storage.enumerateAttribute(.attachment, in: NSRange(location: selection.location, length: selectionEnd - selection.location), options: []) { value, range, stop in
                    if let attachment = value as? NSTextAttachment {
                        found = (attachment, range)
                        stop.pointee = true
                    }
                }
                return found
            }
        }

        return nil
    }

    private func imageFromAttachment(_ attachment: NSTextAttachment) -> NSImage? {
        if let imageCell = attachment.attachmentCell as? NSTextAttachmentCell {
            return imageCell.image
        }
        if let data = attachment.fileWrapper?.regularFileContents {
            return NSImage(data: data)
        }
        if let wrappers = attachment.fileWrapper?.fileWrappers {
            for wrapper in wrappers.values {
                if let data = wrapper.regularFileContents, let image = NSImage(data: data) {
                    return image
                }
            }
        }
        return nil
    }

    private func displayedSize(for attachment: NSTextAttachment, fallbackImage: NSImage) -> NSSize {
        if let imageCell = attachment.attachmentCell as? NSTextAttachmentCell {
            return imageCell.cellSize()
        }
        return fallbackImage.size
    }

    private func applyAIOutput(_ output: String, targetRange: NSRange?) {
        guard let textView = activeTextView() else {
            return
        }

        if let targetRange {
            textView.textStorage?.replaceCharacters(in: targetRange, with: output)
            textView.setSelectedRange(NSRange(location: targetRange.location, length: (output as NSString).length))
        } else {
            setEditorText(output)
        }

        syncModelFromEditor(textView)
    }

    private static func normalizedAIOutput(_ output: String) -> String {
        var value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return ""
        }

        let lines = value.components(separatedBy: "\n")
        if lines.count >= 2,
           lines.first?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true,
           lines.last?.trimmingCharacters(in: .whitespaces) == "```"
        {
            value = lines.dropFirst().dropLast().joined(separator: "\n")
        }

        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}

private extension NSColor {
    func hexString() -> String {
        guard let converted = usingColorSpace(.deviceRGB) else {
            return "#FFFFFF"
        }
        let red = Int(round(converted.redComponent * 255))
        let green = Int(round(converted.greenComponent * 255))
        let blue = Int(round(converted.blueComponent * 255))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}

private extension NSImage {
    func pngRepresentation() -> Data? {
        guard let tiff = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}
