import Combine
import Foundation
import Security

extension Notification.Name {
    static let yaprflowAIProviderSettingsChanged = Notification.Name("yaprflowAIProviderSettingsChanged")
}

@MainActor
final class AIProviderSettings: ObservableObject {
    static let shared = AIProviderSettings()

    private enum DefaultsKey {
        static let provider = "yaprflow.ai.provider"
        static let openAIModel = "yaprflow.ai.openai.model"
        static let openRouterModel = "yaprflow.ai.openrouter.model"
        static let ollamaModel = "yaprflow.ai.ollama.model"
        static let automaticDictationOutput = "yaprflow.ai.automaticDictationOutput"
    }

    @Published var provider: AIProviderKind {
        didSet {
            if oldValue != provider {
                automaticDictationOutput = provider == .appleIntelligence
                    && Self.supportsAutomaticAppleDictation
            }
            changed(DefaultsKey.provider, value: provider.rawValue)
        }
    }
    @Published var openAIModel: String {
        didSet {
            if oldValue != openAIModel && provider == .openAI { automaticDictationOutput = false }
            changed(DefaultsKey.openAIModel, value: openAIModel)
        }
    }
    @Published var openRouterModel: String {
        didSet {
            if oldValue != openRouterModel && provider == .openRouter { automaticDictationOutput = false }
            changed(DefaultsKey.openRouterModel, value: openRouterModel)
        }
    }
    @Published var ollamaModel: String {
        didSet {
            if oldValue != ollamaModel && provider == .ollama {
                automaticDictationOutput = false
            }
            changed(DefaultsKey.ollamaModel, value: ollamaModel)
        }
    }
    @Published var automaticDictationOutput: Bool {
        didSet { changed(DefaultsKey.automaticDictationOutput, value: automaticDictationOutput) }
    }
    @Published private(set) var hasOpenAIKey: Bool
    @Published private(set) var hasOpenRouterKey: Bool

    private init() {
        let defaults = UserDefaults.standard
        let selectedProvider = AIProviderKind(rawValue: defaults.string(forKey: DefaultsKey.provider) ?? "")
            ?? .appleIntelligence
        provider = selectedProvider
        openAIModel = defaults.string(forKey: DefaultsKey.openAIModel) ?? "gpt-4o-mini"
        openRouterModel = defaults.string(forKey: DefaultsKey.openRouterModel)
            ?? "openai/gpt-4o-mini"
        ollamaModel = defaults.string(forKey: DefaultsKey.ollamaModel) ?? ""
        automaticDictationOutput = defaults.object(forKey: DefaultsKey.automaticDictationOutput) as? Bool
            ?? (selectedProvider == .appleIntelligence && Self.supportsAutomaticAppleDictation)
        hasOpenAIKey = (try? AIKeychain.read(account: AIProviderKind.openAI.rawValue)) != nil
        hasOpenRouterKey = (try? AIKeychain.read(account: AIProviderKind.openRouter.rawValue)) != nil
    }

    var selectedModel: String {
        switch provider {
        case .appleIntelligence: ""
        case .openAI: openAIModel.trimmingCharacters(in: .whitespacesAndNewlines)
        case .openRouter: openRouterModel.trimmingCharacters(in: .whitespacesAndNewlines)
        case .ollama: ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static var supportsAutomaticAppleDictation: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    var isConfigured: Bool {
        switch provider {
        case .appleIntelligence: true
        case .openAI: hasOpenAIKey && !selectedModel.isEmpty
        case .openRouter: hasOpenRouterKey && !selectedModel.isEmpty
        case .ollama: !selectedModel.isEmpty
        }
    }

    func configuration() throws -> AIChatConfiguration {
        guard provider != .appleIntelligence else { throw AIProviderError.unsupportedProvider }
        guard !selectedModel.isEmpty else { throw AIProviderError.missingModel }
        let key: String?
        switch provider {
        case .openAI, .openRouter:
            key = try AIKeychain.read(account: provider.rawValue)
            guard let key, !key.isEmpty else { throw AIProviderError.missingAPIKey }
        case .ollama:
            key = nil
        case .appleIntelligence:
            throw AIProviderError.unsupportedProvider
        }
        return AIChatConfiguration(provider: provider, model: selectedModel, apiKey: key)
    }

    func hasKey(for provider: AIProviderKind) -> Bool {
        switch provider {
        case .openAI: hasOpenAIKey
        case .openRouter: hasOpenRouterKey
        case .appleIntelligence, .ollama: false
        }
    }

    func saveKey(_ key: String, for provider: AIProviderKind) throws {
        guard provider == .openAI || provider == .openRouter else {
            throw AIProviderError.unsupportedProvider
        }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIProviderError.missingAPIKey }
        try AIKeychain.save(trimmed, account: provider.rawValue)
        updateKeyPresence(for: provider, present: true)
    }

    func removeKey(for provider: AIProviderKind) throws {
        guard provider == .openAI || provider == .openRouter else { return }
        try AIKeychain.remove(account: provider.rawValue)
        updateKeyPresence(for: provider, present: false)
    }

    private func updateKeyPresence(for provider: AIProviderKind, present: Bool) {
        switch provider {
        case .openAI: hasOpenAIKey = present
        case .openRouter: hasOpenRouterKey = present
        case .appleIntelligence, .ollama: break
        }
        NotificationCenter.default.post(name: .yaprflowAIProviderSettingsChanged, object: nil)
    }

    private func changed(_ key: String, value: Any) {
        UserDefaults.standard.set(value, forKey: key)
        NotificationCenter.default.post(name: .yaprflowAIProviderSettingsChanged, object: nil)
    }
}

private enum AIKeychain {
    private static let service = (Bundle.main.bundleIdentifier ?? "com.tmoreton.yaprflow") + ".aiKeys"

    static func read(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw KeychainError(errSecDecode)
        }
        return key
    }

    static func save(_ key: String, account: String) throws {
        let data = Data(key.utf8)
        let query = baseQuery(account: account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status)
        }
    }

    static func remove(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status)
        }
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private struct KeychainError: LocalizedError {
        let status: OSStatus

        init(_ status: OSStatus) { self.status = status }

        var errorDescription: String? {
            "The Mac Keychain could not access this API key (error \(status))."
        }
    }
}
