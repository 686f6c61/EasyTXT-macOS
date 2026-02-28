import AppKit
import Foundation

@MainActor
protocol ProjectSearchViewControllerDelegate: AnyObject {
    func projectSearch(_ controller: ProjectSearchViewController, didSelect result: ProjectSearchMatch)
}

@MainActor
final class ProjectSearchViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    weak var delegate: ProjectSearchViewControllerDelegate?

    private let folderField = NSTextField(string: "")
    private let queryField = NSSearchField(string: "")
    private let regexButton = NSButton(checkboxWithTitle: "Regex", target: nil, action: nil)
    private let caseButton = NSButton(checkboxWithTitle: "Aa", target: nil, action: nil)
    private let runButton = NSButton(title: "Search", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()

    private var matches: [ProjectSearchMatch] = []

    override func loadView() {
        view = NSView()
        buildUI()
    }

    func setFolder(_ url: URL?) {
        folderField.stringValue = url?.path ?? ""
    }

    func selectedFolderURL() -> URL? {
        let path = folderField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    private func buildUI() {
        folderField.placeholderString = "Project folder"
        queryField.placeholderString = "Search in project"
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)

        let browseButton = NSButton(title: "Folder", target: self, action: #selector(selectFolder))
        runButton.target = self
        runButton.action = #selector(runSearch)

        let topRow = NSStackView(views: [folderField, browseButton])
        topRow.orientation = .horizontal
        topRow.spacing = 8
        topRow.distribution = .fillProportionally

        let options = NSStackView(views: [regexButton, caseButton, runButton])
        options.orientation = .horizontal
        options.spacing = 8

        let lineColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("line"))
        lineColumn.title = "Ln"
        lineColumn.width = 40

        let fileColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        fileColumn.title = "File"
        fileColumn.width = 150

        let previewColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("preview"))
        previewColumn.title = "Preview"
        previewColumn.width = 300

        tableView.addTableColumn(lineColumn)
        tableView.addTableColumn(fileColumn)
        tableView.addTableColumn(previewColumn)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true

        let stack = NSStackView(views: [topRow, queryField, options, statusLabel, scroll])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])
    }

    @objc private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"

        if panel.runModal() == .OK {
            folderField.stringValue = panel.url?.path ?? ""
        }
    }

    @objc private func runSearch() {
        guard let folder = selectedFolderURL() else {
            statusLabel.stringValue = "Selecciona una carpeta primero."
            return
        }

        let query = queryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            statusLabel.stringValue = "Escribe un término de búsqueda."
            return
        }

        let options = SearchOptions(regex: regexButton.state == .on, caseSensitive: caseButton.state == .on)
        runButton.isEnabled = false
        statusLabel.stringValue = "Buscando..."

        DispatchQueue.global(qos: .userInitiated).async {
            let results = SearchEngine.projectSearch(root: folder, query: query, options: options)
            DispatchQueue.main.async {
                self.matches = results
                self.tableView.reloadData()
                self.runButton.isEnabled = true
                self.statusLabel.stringValue = "\(results.count) resultados"
            }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        matches.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < matches.count else {
            return nil
        }

        let id = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
            let view = NSTableCellView()
            view.identifier = id
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
            view.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ])
            return view
        }()

        let result = matches[row]
        switch id.rawValue {
        case "line":
            cell.textField?.stringValue = "\(result.line)"
        case "file":
            cell.textField?.stringValue = result.fileURL.lastPathComponent
        default:
            cell.textField?.stringValue = result.preview
        }

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < matches.count else {
            return
        }
        delegate?.projectSearch(self, didSelect: matches[row])
    }
}
