import Foundation
import Security

enum TranslationLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case simplifiedChinese
    case traditionalChinese
    case english
    case japanese
    case korean

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .simplifiedChinese: return L("translation.language.simplifiedChinese")
        case .traditionalChinese: return L("translation.language.traditionalChinese")
        case .english: return L("translation.language.english")
        case .japanese: return L("translation.language.japanese")
        case .korean: return L("translation.language.korean")
        }
    }

    fileprivate var promptName: String {
        switch self {
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁体中文"
        case .english: return "英语"
        case .japanese: return "日语"
        case .korean: return "韩语"
        }
    }
}

enum TranslationError: LocalizedError, Equatable {
    case emptyInput
    case missingAPIKey
    case invalidEndpoint
    case missingModel
    case emptyResponse
    case invalidResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyInput: return L("translation.error.emptyInput")
        case .missingAPIKey: return L("translation.error.missingAPIKey")
        case .invalidEndpoint: return L("translation.error.invalidEndpoint")
        case .missingModel: return L("translation.error.missingModel")
        case .emptyResponse: return L("translation.error.emptyResponse")
        case .invalidResponse: return L("translation.error.invalidResponse")
        case let .requestFailed(message): return message
        }
    }
}

struct TranslationRequest: Equatable, Sendable {
    let text: String
    let targetLanguage: TranslationLanguage

    init(text: String, targetLanguage: TranslationLanguage) throws {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else { throw TranslationError.emptyInput }
        self.text = normalizedText
        self.targetLanguage = targetLanguage
    }
}

struct OpenAICompatibleTranslationPayload: Encodable, Equatable, Sendable {
    struct Message: Encodable, Equatable, Sendable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let temperature: Double

    init(request: TranslationRequest, model: String) {
        self.model = model
        messages = [
            Message(
                role: "system",
                content: "你是专业翻译引擎。仅输出译文，不要解释、不要加引号。将用户文本翻译为\(request.targetLanguage.promptName)，保留原有段落、换行、Markdown 和代码格式。"
            ),
            Message(role: "user", content: request.text)
        ]
        temperature = 0.2
    }
}

enum OpenAICompatibleTranslationResponse {
    private struct Response: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }

            let message: Message
        }

        let choices: [Choice]
    }

    static func translation(from data: Data) throws -> String {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw TranslationError.invalidResponse
        }
        let text = response.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw TranslationError.emptyResponse }
        return text
    }
}

enum TranslationEndpoint {
    static func chatCompletionsURL(from rawValue: String) throws -> URL {
        let normalizedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: normalizedValue),
              components.scheme == "https",
              components.host != nil else {
            throw TranslationError.invalidEndpoint
        }

        let normalizedPath = components.path.hasSuffix("/")
            ? String(components.path.dropLast())
            : components.path
        if normalizedPath.hasSuffix("/chat/completions") {
            components.path = normalizedPath
            guard let endpoint = components.url else { throw TranslationError.invalidEndpoint }
            return endpoint
        }

        if components.host == "openrouter.ai", normalizedPath == "/api" {
            components.path = "/api/v1/chat/completions"
        } else if normalizedPath.hasSuffix("/v1") {
            components.path = "\(normalizedPath)/chat/completions"
        } else {
            components.path = "\(normalizedPath)/v1/chat/completions"
        }
        guard let endpoint = components.url else { throw TranslationError.invalidEndpoint }
        return endpoint
    }
}

enum TranslationModel {
    static func canonicalName(_ rawValue: String, endpoint: URL) -> String {
        let normalizedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard endpoint.host == "openrouter.ai" else { return normalizedValue }

        switch normalizedValue {
        case "anthropic/claude-4.6-opus":
            return "anthropic/claude-opus-4.6"
        default:
            return normalizedValue
        }
    }
}

struct TranslationAIConfiguration: Sendable {
    let endpoint: URL
    let model: String
    let apiKey: String

    init(endpoint: String, model: String, apiKey: String?) throws {
        let resolvedEndpoint = try TranslationEndpoint.chatCompletionsURL(from: endpoint)
        let normalizedModel = TranslationModel.canonicalName(model, endpoint: resolvedEndpoint)
        guard !normalizedModel.isEmpty else { throw TranslationError.missingModel }
        let normalizedAPIKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalizedAPIKey.isEmpty else { throw TranslationError.missingAPIKey }

        self.endpoint = resolvedEndpoint
        self.model = normalizedModel
        self.apiKey = normalizedAPIKey
    }
}

struct OpenAICompatibleTranslationClient: Sendable {
    func translate(_ request: TranslationRequest, configuration: TranslationAIConfiguration) async throws -> String {
        let payload = OpenAICompatibleTranslationPayload(request: request, model: configuration.model)
        var urlRequest = URLRequest(url: configuration.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let response = response as? HTTPURLResponse else {
            throw TranslationError.invalidResponse
        }
        guard (200...299).contains(response.statusCode) else {
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw TranslationError.requestFailed(message?.isEmpty == false ? message! : "HTTP \(response.statusCode)")
        }
        return try OpenAICompatibleTranslationResponse.translation(from: data)
    }
}

enum TranslationSettingsKey {
    static let endpoint = "translation.endpoint"
    static let model = "translation.model"
    static let targetLanguage = "translation.targetLanguage"
    static let apiKeyAccount = "translation.apiKey"

    static let defaultEndpoint = "https://api.openai.com/v1/chat/completions"
    static let defaultModel = "gpt-4.1-mini"
}

enum TranslationSettingsValue {
    static func resolved(_ value: String?, fallback: String) -> String {
        let normalizedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalizedValue.isEmpty ? fallback : normalizedValue
    }

    static func placeholderValue(_ value: String, placeholder: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines) == placeholder ? "" : value
    }
}

struct TranslationAPIKeyCache {
    private enum State {
        case unresolved
        case resolved(String?)
    }

    private var state = State.unresolved

    mutating func load(using loader: () -> String?) -> String? {
        if case let .resolved(value) = state {
            return value
        }

        let loadedValue = loader()
        state = .resolved(loadedValue)
        return loadedValue
    }

    mutating func store(_ apiKey: String) {
        state = .resolved(apiKey)
    }

    mutating func clear() {
        state = .resolved(nil)
    }
}

@MainActor
enum TranslationAPIKeyStore {
    private static let service = Bundle.main.bundleIdentifier ?? "com.qoder.menutools"
    private static var cache = TranslationAPIKeyCache()

    static func load() -> String? {
        cache.load {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: TranslationSettingsKey.apiKeyAccount,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        }
    }

    static func save(_ apiKey: String) -> Bool {
        guard !apiKey.isEmpty else { return delete() }
        let data = Data(apiKey.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: TranslationSettingsKey.apiKeyAccount
        ]
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            cache.store(apiKey)
            return true
        }
        guard updateStatus == errSecItemNotFound else { return false }
        cache.clear()

        var addQuery = query
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { return false }
        cache.store(apiKey)
        return true
    }

    static func delete() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: TranslationSettingsKey.apiKeyAccount
        ]
        let deleteStatus = SecItemDelete(query as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            return false
        }
        cache.clear()
        return true
    }
}
