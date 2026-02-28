import AppKit
import Foundation

#if canImport(Darwin)
import Darwin
#endif

private extension NSAttributedString.Key {
    static let easyTXTPNGData = NSAttributedString.Key("easytxt.pngData")
}

struct LoadedDocument {
    let attributedText: NSAttributedString
    let format: DocumentFormat
    let encoding: String.Encoding
    let lineEnding: LineEnding
    let isLargeFile: Bool
    let fileSize: Int64

    var text: String {
        attributedText.string
    }
}

enum FileServiceError: LocalizedError {
    case unsupportedEncoding
    case saveFailure
    case attachmentsNotSupportedForPlainText
    case markdownImageExportFailure

    var errorDescription: String? {
        switch self {
        case .unsupportedEncoding:
            return "No se pudo detectar una codificación compatible para este archivo."
        case .saveFailure:
            return "No se pudo guardar el archivo con la codificación seleccionada."
        case .attachmentsNotSupportedForPlainText:
            return "TXT no soporta imágenes. Guarda como Markdown o RTF."
        case .markdownImageExportFailure:
            return "No se pudo exportar una imagen al guardar Markdown."
        }
    }
}

final class FileService {
    private let readQueue = DispatchQueue(label: "easytxt.file.read", qos: .userInitiated)
    private let largeFileThreshold: Int64 = 8 * 1024 * 1024

    func loadDocument(
        from url: URL,
        preferredEncoding: String.Encoding? = nil,
        completion: @escaping (Result<LoadedDocument, Error>) -> Void
    ) {
        readQueue.async {
            do {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                let format = DocumentFormat.from(url: url)
                let loaded: LoadedDocument

                switch format {
                case .richText:
                    let attributed = try NSAttributedString(
                        data: data,
                        options: [.documentType: NSAttributedString.DocumentType.rtf],
                        documentAttributes: nil
                    )
                    loaded = LoadedDocument(
                        attributedText: attributed,
                        format: .richText,
                        encoding: preferredEncoding ?? .utf8,
                        lineEnding: Self.detectLineEnding(in: attributed.string),
                        isLargeFile: size >= self.largeFileThreshold,
                        fileSize: size
                    )
                case .plainText, .markdown:
                    let decoded = try Self.decodeTextData(data, preferredEncoding: preferredEncoding)
                    loaded = LoadedDocument(
                        attributedText: NSAttributedString(string: decoded.text),
                        format: format,
                        encoding: decoded.encoding,
                        lineEnding: Self.detectLineEnding(in: decoded.text),
                        isLargeFile: size >= self.largeFileThreshold,
                        fileSize: size
                    )
                }

                DispatchQueue.main.async {
                    completion(.success(loaded))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    func saveDocument(_ document: DocumentBuffer, to destination: URL? = nil) throws {
        let targetURL = destination ?? document.fileURL
        guard let targetURL else {
            throw FileServiceError.saveFailure
        }

        let format = DocumentFormat.from(url: targetURL)
        switch format {
        case .plainText:
            if Self.containsAttachments(in: document.attributedText) {
                throw FileServiceError.attachmentsNotSupportedForPlainText
            }
            let normalized = Self.normalizeLineEndings(document.text, to: document.lineEnding)
            guard let data = normalized.data(using: document.encoding) else {
                throw FileServiceError.saveFailure
            }
            try data.write(to: targetURL, options: .atomic)
        case .richText:
            let range = NSRange(location: 0, length: document.attributedText.length)
            let data = try document.attributedText.data(
                from: range,
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            )
            try data.write(to: targetURL, options: .atomic)
        case .markdown:
            let markdown = try Self.markdownExport(from: document.attributedText, targetURL: targetURL)
            let normalized = Self.normalizeLineEndings(markdown, to: document.lineEnding)
            guard let data = normalized.data(using: document.encoding) else {
                throw FileServiceError.saveFailure
            }
            try data.write(to: targetURL, options: .atomic)
        }
    }

    static func detectLineEnding(in text: String) -> LineEnding {
        if text.contains("\r\n") {
            return .crlf
        }
        return .lf
    }

    static func normalizeLineEndings(_ text: String, to lineEnding: LineEnding) -> String {
        let canonical = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if lineEnding == .lf {
            return canonical
        }
        return canonical.replacingOccurrences(of: "\n", with: "\r\n")
    }

    private static func decodeTextData(
        _ data: Data,
        preferredEncoding: String.Encoding?
    ) throws -> (text: String, encoding: String.Encoding) {
        let tried: [String.Encoding]
        if let preferredEncoding {
            tried = [preferredEncoding, .utf8, .utf16, .windowsCP1252, .isoLatin1]
        } else {
            tried = [.utf8, .utf16, .windowsCP1252, .isoLatin1]
        }

        for encoding in tried {
            if let decoded = String(data: data, encoding: encoding) {
                return (decoded, encoding)
            }
        }
        throw FileServiceError.unsupportedEncoding
    }

    private static func containsAttachments(in text: NSAttributedString) -> Bool {
        let range = NSRange(location: 0, length: text.length)
        var hasAttachment = false
        text.enumerateAttribute(.attachment, in: range, options: []) { value, _, stop in
            if value is NSTextAttachment {
                hasAttachment = true
                stop.pointee = true
            }
        }
        return hasAttachment
    }

    private static func markdownExport(from text: NSAttributedString, targetURL: URL) throws -> String {
        if text.length == 0 {
            return ""
        }

        let assetDirectoryName = targetURL.deletingPathExtension().lastPathComponent + "_assets"
        let assetDirectoryURL = targetURL.deletingLastPathComponent().appendingPathComponent(assetDirectoryName, isDirectory: true)
        var didCreateAssetDirectory = false

        let source = text.string as NSString
        var output = ""
        var imageCounter = 1
        var location = 0

        while location < text.length {
            var range = NSRange(location: 0, length: 0)
            let attrs = text.attributes(at: location, effectiveRange: &range)

            if let attachment = attrs[.attachment] as? NSTextAttachment {
                if !didCreateAssetDirectory {
                    try FileManager.default.createDirectory(at: assetDirectoryURL, withIntermediateDirectories: true)
                    didCreateAssetDirectory = true
                }
                guard let pngData = pngData(fromAttachment: attachment, attributes: attrs) else {
                    throw FileServiceError.markdownImageExportFailure
                }

                let fileName = "image-\(imageCounter).png"
                imageCounter += 1
                let fileURL = assetDirectoryURL.appendingPathComponent(fileName)
                try pngData.write(to: fileURL, options: .atomic)

                output += "![\(fileName)](\(assetDirectoryName)/\(fileName))"
            } else {
                output += source.substring(with: range)
            }

            location = NSMaxRange(range)
        }

        return output
    }

    private static func pngData(
        fromAttachment attachment: NSTextAttachment,
        attributes: [NSAttributedString.Key: Any]
    ) -> Data? {
        if let stored = attributes[.easyTXTPNGData] as? Data {
            return stored
        }
        if let data = attachment.fileWrapper?.regularFileContents, let image = NSImage(data: data) {
            return pngData(from: image)
        }
        if let wrappers = attachment.fileWrapper?.fileWrappers {
            for wrapper in wrappers.values {
                if let data = wrapper.regularFileContents, let image = NSImage(data: data) {
                    return pngData(from: image)
                }
            }
        }
        return nil
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}

struct SearchOptions {
    var regex: Bool
    var caseSensitive: Bool
}

enum SearchEngine {
    static func ranges(in text: String, query: String, options: SearchOptions) -> [NSRange] {
        guard !query.isEmpty else {
            return []
        }

        let nsText = text as NSString
        var ranges: [NSRange] = []

        if options.regex {
            let flags: NSRegularExpression.Options = options.caseSensitive ? [] : [.caseInsensitive]
            guard let regex = try? NSRegularExpression(pattern: query, options: flags) else {
                return []
            }
            regex.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: nsText.length)) { match, _, _ in
                if let match {
                    ranges.append(match.range)
                }
            }
            return ranges
        }

        var searchRange = NSRange(location: 0, length: nsText.length)
        let compare: NSString.CompareOptions = options.caseSensitive ? [] : [.caseInsensitive]

        while true {
            let found = nsText.range(of: query, options: compare, range: searchRange)
            if found.location == NSNotFound {
                break
            }
            ranges.append(found)
            let nextLocation = found.location + max(found.length, 1)
            searchRange = NSRange(location: nextLocation, length: nsText.length - nextLocation)
            if searchRange.length <= 0 {
                break
            }
        }

        return ranges
    }

    static func projectSearch(
        root: URL,
        query: String,
        options: SearchOptions,
        maxResults: Int = 2500
    ) -> [ProjectSearchMatch] {
        guard !query.isEmpty else {
            return []
        }

        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var matches: [ProjectSearchMatch] = []

        for case let fileURL as URL in enumerator {
            if matches.count >= maxResults {
                break
            }

            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true else {
                continue
            }

            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
                continue
            }

            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let plainQuery = options.caseSensitive ? query : query.lowercased()

            for (index, lineSlice) in lines.enumerated() {
                if matches.count >= maxResults {
                    break
                }

                let line = String(lineSlice)

                if options.regex {
                    let flags: NSRegularExpression.Options = options.caseSensitive ? [] : [.caseInsensitive]
                    guard let regex = try? NSRegularExpression(pattern: query, options: flags) else {
                        break
                    }
                    let lineNS = line as NSString
                    let lineRange = NSRange(location: 0, length: lineNS.length)
                    regex.enumerateMatches(in: line, options: [], range: lineRange) { match, _, stop in
                        guard let match else {
                            return
                        }
                        let preview = String(line.prefix(220))
                        matches.append(ProjectSearchMatch(fileURL: fileURL, line: index + 1, column: match.range.location + 1, preview: preview))
                        if matches.count >= maxResults {
                            stop.pointee = true
                        }
                    }
                } else {
                    let source = options.caseSensitive ? line : line.lowercased()
                    if let range = source.range(of: plainQuery) {
                        let preview = String(line.prefix(220))
                        let column = source.distance(from: source.startIndex, to: range.lowerBound) + 1
                        matches.append(ProjectSearchMatch(fileURL: fileURL, line: index + 1, column: column, preview: preview))
                    }
                }
            }
        }

        return matches
    }
}

enum AITask: String {
    case correct
    case expand
    case ideate

    var title: String {
        switch self {
        case .correct:
            return "Corregir"
        case .expand:
            return "Expandir"
        case .ideate:
            return "Idea"
        }
    }

    func prompt(for input: String) -> String {
        switch self {
        case .correct:
            return "Corrige ortografía, puntuación y claridad del siguiente texto, manteniendo el tono y significado. Devuelve solo texto plano, sin markdown ni bloques de código:\n\n\(input)"
        case .expand:
            return "Expande el siguiente texto de forma útil y concreta, añadiendo detalle sin relleno. Devuelve solo texto plano, sin markdown ni bloques de código:\n\n\(input)"
        case .ideate:
            return "Toma el siguiente contexto y escribe ideas accionables en formato breve. Devuelve solo texto plano, sin markdown ni bloques de código:\n\n\(input)"
        }
    }
}

enum AnthropicServiceError: LocalizedError {
    case invalidResponse
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Respuesta inválida del servicio de IA."
        case .apiError(let message):
            return "Anthropic devolvió un error: \(message)"
        }
    }
}

@MainActor
final class AIClient {
    static let shared = AIClient()
    private let anthropic = AnthropicService()
    private let openAI = OpenAIService()

    func run(task: AITask, input: String, configuration: AIConfiguration, completion: @escaping (Result<String, Error>) -> Void) {
        switch configuration.provider {
        case .anthropic:
            anthropic.run(task: task, input: input, model: configuration.model, apiKey: configuration.apiKey, completion: completion)
        case .openAI:
            openAI.run(task: task, input: input, model: configuration.model, apiKey: configuration.apiKey, completion: completion)
        }
    }
}

struct AIConfiguration {
    let provider: AIProvider
    let model: String
    let apiKey: String
}

@MainActor
final class AnthropicService {
    private let session = URLSession(configuration: .ephemeral)

    func run(task: AITask, input: String, model: String, apiKey: String, completion: @escaping (Result<String, Error>) -> Void) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(.success(""))
            return
        }

        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            completion(.failure(AIClientError.missingAPIKey(provider: .anthropic)))
            return
        }

        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            completion(.failure(AnthropicServiceError.invalidResponse))
            return
        }

        let prompt = task.prompt(for: trimmed)
        let body = AnthropicRequest(
            model: model,
            max_tokens: 1600,
            temperature: 0.3,
            system: "You are a concise writing assistant. Return plain text only.",
            messages: [
                AnthropicRequest.Message(
                    role: "user",
                    content: [AnthropicRequest.Block(type: "text", text: prompt)]
                )
            ]
        )

        guard let payload = try? JSONEncoder().encode(body) else {
            completion(.failure(AnthropicServiceError.invalidResponse))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = payload

        session.dataTask(with: request) { data, _, error in
            if let error {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
                return
            }

            guard let data else {
                DispatchQueue.main.async {
                    completion(.failure(AnthropicServiceError.invalidResponse))
                }
                return
            }

            if let apiError = try? JSONDecoder().decode(AnthropicErrorEnvelope.self, from: data) {
                DispatchQueue.main.async {
                    completion(.failure(AnthropicServiceError.apiError(apiError.error.message)))
                }
                return
            }

            guard let response = try? JSONDecoder().decode(AnthropicResponse.self, from: data) else {
                DispatchQueue.main.async {
                    completion(.failure(AnthropicServiceError.invalidResponse))
                }
                return
            }

            let text = response.content
                .filter { $0.type == "text" }
                .compactMap { $0.text }
                .joined(separator: "\n")

            DispatchQueue.main.async {
                completion(.success(text))
            }
        }.resume()
    }
}

enum AIClientError: LocalizedError {
    case missingAPIKey(provider: AIProvider)
    case invalidResponse(provider: AIProvider)
    case providerError(provider: AIProvider, message: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "Falta API key para \(provider.displayName). Configúrala en Tools > AI Settings."
        case .invalidResponse(let provider):
            return "Respuesta inválida de \(provider.displayName)."
        case .providerError(let provider, let message):
            return "\(provider.displayName) devolvió un error: \(message)"
        }
    }
}

private struct AnthropicRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: [Block]
    }

    struct Block: Encodable {
        let type: String
        let text: String
    }

    let model: String
    let max_tokens: Int
    let temperature: Double
    let system: String
    let messages: [Message]
}

private struct AnthropicResponse: Decodable {
    struct Block: Decodable {
        let type: String
        let text: String?
    }

    let content: [Block]
}

private struct AnthropicErrorEnvelope: Decodable {
    struct ErrorBody: Decodable {
        let message: String
    }

    let error: ErrorBody
}

@MainActor
final class OpenAIService {
    private let session = URLSession(configuration: .ephemeral)

    func run(task: AITask, input: String, model: String, apiKey: String, completion: @escaping (Result<String, Error>) -> Void) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(.success(""))
            return
        }

        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            completion(.failure(AIClientError.missingAPIKey(provider: .openAI)))
            return
        }

        guard let url = URL(string: "https://api.openai.com/v1/responses") else {
            completion(.failure(AIClientError.invalidResponse(provider: .openAI)))
            return
        }

        let prompt = task.prompt(for: trimmed)
        let body = OpenAIRequest(
            model: model,
            input: [OpenAIRequest.InputMessage(role: "user", content: [OpenAIRequest.InputContent(type: "input_text", text: prompt)])],
            temperature: 0.3,
            max_output_tokens: 1600
        )

        guard let payload = try? JSONEncoder().encode(body) else {
            completion(.failure(AIClientError.invalidResponse(provider: .openAI)))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        request.httpBody = payload

        session.dataTask(with: request) { data, _, error in
            if let error {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
                return
            }

            guard let data else {
                DispatchQueue.main.async {
                    completion(.failure(AIClientError.invalidResponse(provider: .openAI)))
                }
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async {
                    completion(.failure(AIClientError.invalidResponse(provider: .openAI)))
                }
                return
            }

            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                DispatchQueue.main.async {
                    completion(.failure(AIClientError.providerError(provider: .openAI, message: message)))
                }
                return
            }

            if let outputText = json["output_text"] as? String, !outputText.isEmpty {
                DispatchQueue.main.async {
                    completion(.success(outputText))
                }
                return
            }

            if let extracted = Self.extractText(from: json), !extracted.isEmpty {
                DispatchQueue.main.async {
                    completion(.success(extracted))
                }
                return
            }

            DispatchQueue.main.async {
                completion(.failure(AIClientError.invalidResponse(provider: .openAI)))
            }
        }.resume()
    }

    nonisolated private static func extractText(from json: [String: Any]) -> String? {
        guard let output = json["output"] as? [[String: Any]] else {
            return nil
        }

        var chunks: [String] = []
        for item in output {
            guard let content = item["content"] as? [[String: Any]] else {
                continue
            }
            for block in content {
                if let text = block["text"] as? String {
                    chunks.append(text)
                }
            }
        }
        return chunks.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct OpenAIRequest: Encodable {
    struct InputMessage: Encodable {
        let role: String
        let content: [InputContent]
    }

    struct InputContent: Encodable {
        let type: String
        let text: String
    }

    let model: String
    let input: [InputMessage]
    let temperature: Double
    let max_output_tokens: Int
}

final class FileWatcher {
    private let descriptor: Int32
    private let source: DispatchSourceFileSystemObject

    init?(url: URL, onChange: @escaping () -> Void) {
        descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            return nil
        }

        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: DispatchQueue.global(qos: .utility)
        )

        source.setEventHandler(handler: onChange)
        source.setCancelHandler { [descriptor] in
            close(descriptor)
        }
        source.resume()
    }

    deinit {
        source.cancel()
    }
}
