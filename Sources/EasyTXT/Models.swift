import AppKit
import Foundation

enum LineEnding: String, CaseIterable, Codable {
    case lf = "LF"
    case crlf = "CRLF"

    var sequence: String {
        switch self {
        case .lf:
            return "\n"
        case .crlf:
            return "\r\n"
        }
    }
}

enum DocumentFormat: String, CaseIterable, Codable {
    case plainText
    case markdown
    case richText

    var displayName: String {
        switch self {
        case .plainText:
            return "TXT"
        case .markdown:
            return "Markdown"
        case .richText:
            return "RTF"
        }
    }

    var fileExtension: String {
        switch self {
        case .plainText:
            return "txt"
        case .markdown:
            return "md"
        case .richText:
            return "rtf"
        }
    }

    static func from(url: URL?) -> DocumentFormat {
        guard let ext = url?.pathExtension.lowercased() else {
            return .plainText
        }
        switch ext {
        case "md", "markdown":
            return .markdown
        case "rtf":
            return .richText
        default:
            return .plainText
        }
    }
}

enum EditorTheme: String, CaseIterable, Codable {
    case light
    case dark

    var displayName: String {
        switch self {
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }

    var backgroundColor: NSColor {
        switch self {
        case .light:
            return NSColor(calibratedRed: 0.98, green: 0.98, blue: 0.99, alpha: 1.0)
        case .dark:
            return NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.14, alpha: 1.0)
        }
    }

    var textColor: NSColor {
        switch self {
        case .light:
            return NSColor(calibratedWhite: 0.12, alpha: 1.0)
        case .dark:
            return NSColor(calibratedWhite: 0.92, alpha: 1.0)
        }
    }

    var secondaryTextColor: NSColor {
        switch self {
        case .light:
            return NSColor(calibratedWhite: 0.38, alpha: 1.0)
        case .dark:
            return NSColor(calibratedWhite: 0.70, alpha: 1.0)
        }
    }

    var selectionColor: NSColor {
        switch self {
        case .light:
            return NSColor(calibratedRed: 0.70, green: 0.80, blue: 0.95, alpha: 0.55)
        case .dark:
            return NSColor(calibratedRed: 0.28, green: 0.46, blue: 0.72, alpha: 0.65)
        }
    }
}

enum AIProvider: String, CaseIterable, Codable {
    case anthropic
    case openAI

    var displayName: String {
        switch self {
        case .anthropic:
            return "Claude (Anthropic)"
        case .openAI:
            return "OpenAI"
        }
    }

    var modelOptions: [AIModelOption] {
        switch self {
        case .anthropic:
            return [
                AIModelOption(
                    id: "claude-opus-4-6",
                    title: "Opus 4.6",
                    summary: "Máxima calidad (si está habilitado en tu cuenta)"
                ),
                AIModelOption(
                    id: "claude-sonnet-4-5",
                    title: "Sonnet",
                    summary: "Equilibrado para edición y notas",
                    recommended: true
                ),
                AIModelOption(
                    id: "claude-opus-4-5",
                    title: "Opus",
                    summary: "Máxima calidad para reescritura compleja"
                ),
                AIModelOption(
                    id: "claude-haiku-4-5",
                    title: "Haiku",
                    summary: "Más rápido y económico"
                ),
            ]
        case .openAI:
            return [
                AIModelOption(
                    id: "gpt-5",
                    title: "GPT-5",
                    summary: "Modelo principal para texto",
                    recommended: true
                ),
                AIModelOption(
                    id: "gpt-5-chat-latest",
                    title: "GPT-5 Chat",
                    summary: "Versión optimizada para chat"
                ),
                AIModelOption(
                    id: "gpt-5-mini",
                    title: "GPT-5 Mini",
                    summary: "Más rápido con buena calidad"
                ),
                AIModelOption(
                    id: "gpt-5-nano",
                    title: "GPT-5 Nano",
                    summary: "Ultraligero para tareas simples"
                ),
                AIModelOption(
                    id: "o3",
                    title: "o3",
                    summary: "Razonamiento fuerte para prompts complejos"
                ),
                AIModelOption(
                    id: "o4-mini",
                    title: "o4-mini",
                    summary: "Razonamiento rápido y eficiente"
                ),
            ]
        }
    }

    var supportedModels: [String] {
        modelOptions.map(\.id)
    }

    var defaultModel: String {
        modelOptions.first(where: \.recommended)?.id ?? supportedModels.first ?? ""
    }

    func option(for modelID: String) -> AIModelOption? {
        modelOptions.first(where: { $0.id == modelID })
    }
}

struct AIModelOption {
    let id: String
    let title: String
    let summary: String
    var recommended: Bool = false
}

struct SessionTabState: Codable {
    var filePath: String?
    var draftPath: String?
    var encodingRawValue: UInt
    var lineEnding: LineEnding
    var customTitle: String?
    var format: DocumentFormat

    init(
        filePath: String?,
        draftPath: String?,
        encodingRawValue: UInt,
        lineEnding: LineEnding,
        customTitle: String?,
        format: DocumentFormat = .plainText
    ) {
        self.filePath = filePath
        self.draftPath = draftPath
        self.encodingRawValue = encodingRawValue
        self.lineEnding = lineEnding
        self.customTitle = customTitle
        self.format = format
    }

    private enum CodingKeys: String, CodingKey {
        case filePath
        case draftPath
        case encodingRawValue
        case lineEnding
        case customTitle
        case format
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        filePath = try container.decodeIfPresent(String.self, forKey: .filePath)
        draftPath = try container.decodeIfPresent(String.self, forKey: .draftPath)
        encodingRawValue = try container.decode(UInt.self, forKey: .encodingRawValue)
        lineEnding = try container.decode(LineEnding.self, forKey: .lineEnding)
        customTitle = try container.decodeIfPresent(String.self, forKey: .customTitle)
        format = try container.decodeIfPresent(DocumentFormat.self, forKey: .format) ?? .plainText
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(filePath, forKey: .filePath)
        try container.encodeIfPresent(draftPath, forKey: .draftPath)
        try container.encode(encodingRawValue, forKey: .encodingRawValue)
        try container.encode(lineEnding, forKey: .lineEnding)
        try container.encodeIfPresent(customTitle, forKey: .customTitle)
        try container.encode(format, forKey: .format)
    }
}

struct SessionState: Codable {
    var tabs: [SessionTabState]
    var selectedIndex: Int
}

final class DocumentBuffer {
    let id = UUID()
    var fileURL: URL?
    var customTitle: String?
    var format: DocumentFormat
    var encoding: String.Encoding
    var lineEnding: LineEnding
    var draftURL: URL?
    private(set) var isDirty: Bool

    private var internalAttributedText: NSAttributedString
    var attributedText: NSAttributedString {
        internalAttributedText
    }

    var text: String {
        internalAttributedText.string
    }

    var displayName: String {
        if let fileURL {
            return fileURL.lastPathComponent
        }
        if let customTitle, !customTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return customTitle
        }
        return "Untitled"
    }

    init(
        fileURL: URL? = nil,
        customTitle: String? = nil,
        attributedText: NSAttributedString? = nil,
        text: String = "",
        format: DocumentFormat = .plainText,
        encoding: String.Encoding = .utf8,
        lineEnding: LineEnding = .lf,
        isDirty: Bool = false
    ) {
        self.fileURL = fileURL
        self.customTitle = customTitle
        self.internalAttributedText = attributedText ?? NSAttributedString(string: text)
        self.format = format
        self.encoding = encoding
        self.lineEnding = lineEnding
        self.isDirty = isDirty
    }

    func updateText(_ newText: String, markDirty: Bool = true) {
        if internalAttributedText.string == newText {
            return
        }
        internalAttributedText = NSAttributedString(string: newText)
        if markDirty {
            isDirty = true
        }
    }

    func updateAttributedText(_ newText: NSAttributedString, markDirty: Bool = true) {
        if internalAttributedText.isEqual(to: newText) {
            return
        }
        internalAttributedText = newText.copy() as? NSAttributedString ?? NSAttributedString(string: newText.string)
        if markDirty {
            isDirty = true
        }
    }

    func markClean() {
        isDirty = false
        draftURL = nil
    }

    func displayTitle() -> String {
        if isDirty {
            return displayName + " *"
        }
        return displayName
    }
}

struct ProjectSearchMatch {
    let fileURL: URL
    let line: Int
    let column: Int
    let preview: String
}

struct EditorPreferences {
    var theme: EditorTheme
    var fontName: String
    var fontSize: CGFloat
    var lineNumbersEnabled: Bool
}

struct Snippet {
    let title: String
    let body: String
}
