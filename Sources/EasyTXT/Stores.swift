import Foundation

enum AppPaths {
    static let appSupportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("EasyTXT", isDirectory: true)
    }()

    static let historyDirectory = appSupportDirectory.appendingPathComponent("History", isDirectory: true)
    static let recoveryDirectory = appSupportDirectory.appendingPathComponent("Recovery", isDirectory: true)
    static let sessionFile = appSupportDirectory.appendingPathComponent("session.json")

    static func ensureDirectories() {
        let fileManager = FileManager.default
        [appSupportDirectory, historyDirectory, recoveryDirectory].forEach {
            try? fileManager.createDirectory(at: $0, withIntermediateDirectories: true)
        }
    }
}

final class SettingsStore {
    private enum Keys {
        static let theme = "easytxt.theme"
        static let fontName = "easytxt.fontName"
        static let fontSize = "easytxt.fontSize"
        static let lineNumbersEnabled = "easytxt.lineNumbersEnabled"
        static let preferredSearchFolder = "easytxt.preferredSearchFolder"
        static let anthropicModel = "easytxt.anthropicModel"
        static let openAIModel = "easytxt.openaiModel"
        static let aiProvider = "easytxt.aiProvider"
    }

    private let defaults = UserDefaults.standard

    var preferences: EditorPreferences {
        get {
            let rawTheme = defaults.string(forKey: Keys.theme) ?? EditorTheme.light.rawValue
            let theme = EditorTheme(rawValue: rawTheme) ?? .light
            let fontName = defaults.string(forKey: Keys.fontName) ?? "Menlo"
            let fontSize = defaults.double(forKey: Keys.fontSize)
            let resolvedSize: CGFloat = fontSize > 0 ? fontSize : 14
            let lineNumbersEnabled: Bool
            if defaults.object(forKey: Keys.lineNumbersEnabled) == nil {
                lineNumbersEnabled = true
            } else {
                lineNumbersEnabled = defaults.bool(forKey: Keys.lineNumbersEnabled)
            }
            return EditorPreferences(
                theme: theme,
                fontName: fontName,
                fontSize: resolvedSize,
                lineNumbersEnabled: lineNumbersEnabled
            )
        }
        set {
            defaults.set(newValue.theme.rawValue, forKey: Keys.theme)
            defaults.set(newValue.fontName, forKey: Keys.fontName)
            defaults.set(Double(newValue.fontSize), forKey: Keys.fontSize)
            defaults.set(newValue.lineNumbersEnabled, forKey: Keys.lineNumbersEnabled)
        }
    }

    var preferredSearchFolder: URL? {
        get {
            guard let raw = defaults.string(forKey: Keys.preferredSearchFolder) else {
                return nil
            }
            return URL(fileURLWithPath: raw)
        }
        set {
            defaults.set(newValue?.path, forKey: Keys.preferredSearchFolder)
        }
    }

    var aiProvider: AIProvider {
        get {
            let raw = defaults.string(forKey: Keys.aiProvider) ?? AIProvider.anthropic.rawValue
            return AIProvider(rawValue: raw) ?? .anthropic
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.aiProvider)
        }
    }

    var anthropicModel: String {
        get {
            if let envModel = ProcessInfo.processInfo.environment["ANTHROPIC_MODEL"], !envModel.isEmpty {
                return envModel
            }
            return defaults.string(forKey: Keys.anthropicModel) ?? AIProvider.anthropic.defaultModel
        }
        set {
            defaults.set(newValue, forKey: Keys.anthropicModel)
        }
    }

    var openAIModel: String {
        get {
            if let envModel = ProcessInfo.processInfo.environment["OPENAI_MODEL"], !envModel.isEmpty {
                return envModel
            }
            return defaults.string(forKey: Keys.openAIModel) ?? AIProvider.openAI.defaultModel
        }
        set {
            defaults.set(newValue, forKey: Keys.openAIModel)
        }
    }

    func model(for provider: AIProvider) -> String {
        let value: String
        switch provider {
        case .anthropic:
            value = anthropicModel
        case .openAI:
            value = openAIModel
        }
        if provider.supportedModels.contains(value) {
            return value
        }
        return provider.defaultModel
    }

    func setModel(_ model: String, for provider: AIProvider) {
        switch provider {
        case .anthropic:
            anthropicModel = model
        case .openAI:
            openAIModel = model
        }
    }

    var snippets: [Snippet] {
        [
            Snippet(title: "TODO", body: "- [ ] TODO: "),
            Snippet(title: "Timestamp", body: ISO8601DateFormatter().string(from: Date())),
            Snippet(title: "Mermaid Flow", body: "```mermaid\ngraph TD\n  A[Idea] --> B[Action]\n```"),
            Snippet(title: "Markdown Note", body: "# Note\n\n## Context\n\n## Next Steps\n")
        ]
    }
}

final class SessionStore {
    func save(_ state: SessionState) {
        AppPaths.ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else {
            return
        }
        try? data.write(to: AppPaths.sessionFile, options: .atomic)
    }

    func load() -> SessionState? {
        guard let data = try? Data(contentsOf: AppPaths.sessionFile) else {
            return nil
        }
        return try? JSONDecoder().decode(SessionState.self, from: data)
    }
}

final class RecoveryStore {
    func saveDraft(for document: DocumentBuffer) -> URL? {
        AppPaths.ensureDirectories()
        let name = document.id.uuidString + ".draft.rtf"
        let fileURL = AppPaths.recoveryDirectory.appendingPathComponent(name)
        do {
            let data = try document.attributedText.data(
                from: NSRange(location: 0, length: document.attributedText.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            )
            try data.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            return nil
        }
    }

    func readDraft(at url: URL) -> NSAttributedString? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        )
    }

    func removeDraft(at url: URL?) {
        guard let url else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }
}

final class HistoryStore {
    private let maxSnapshotsPerFile = 25

    func snapshot(document: DocumentBuffer) {
        guard let fileURL = document.fileURL else {
            return
        }

        AppPaths.ensureDirectories()
        let folder = AppPaths.historyDirectory.appendingPathComponent(safeName(for: fileURL.path), isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let formatter = ISO8601DateFormatter()
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let snapshotURL = folder.appendingPathComponent(stamp + ".rtf")

        do {
            let data = try document.attributedText.data(
                from: NSRange(location: 0, length: document.attributedText.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            )
            try data.write(to: snapshotURL, options: .atomic)
            pruneSnapshots(in: folder)
        } catch {
            // Best-effort local history; ignore write errors.
        }
    }

    func latestSnapshot(for fileURL: URL) -> NSAttributedString? {
        let folder = AppPaths.historyDirectory.appendingPathComponent(safeName(for: fileURL.path), isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else {
            return nil
        }
        let latest = files.sorted { $0.lastPathComponent > $1.lastPathComponent }.first
        guard let latest else {
            return nil
        }
        guard let data = try? Data(contentsOf: latest) else {
            return nil
        }
        return try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        )
    }

    private func pruneSnapshots(in folder: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else {
            return
        }
        let sorted = files.sorted { $0.lastPathComponent > $1.lastPathComponent }
        if sorted.count <= maxSnapshotsPerFile {
            return
        }
        sorted.dropFirst(maxSnapshotsPerFile).forEach { try? FileManager.default.removeItem(at: $0) }
    }

    private func safeName(for value: String) -> String {
        let bytes = Array(value.utf8)
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "/", with: "_")
    }
}
