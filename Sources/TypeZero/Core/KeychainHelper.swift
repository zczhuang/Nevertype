import Foundation
import Security

public enum KeychainHelper {
    private static let service = AppBrand.bundleID
    private static let legacyAccount = "llm_api_key"
    private static let volcSpeechAccount = "volc_speech_api_key"
    private static let openAIASRAccount = "openai_asr_api_key"

    public static func saveVolcSpeechAPIKey(_ key: String) {
        let cleaned = key.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        deleteSlot(volcSpeechAccount)
        guard !cleaned.isEmpty, let data = cleaned.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: volcSpeechAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    public static func loadVolcSpeechAPIKey() -> String {
        return readSlot(volcSpeechAccount) ?? ""
    }

    /// True when the user has saved their own Doubao speech API key.
    public static var hasAnyDoubaoCredential: Bool {
        !loadVolcSpeechAPIKey().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func saveOpenAIASRAPIKey(_ key: String) {
        saveAPIKeyInSlot(key, slot: openAIASRAccount)
    }

    /// Reads ONLY the dedicated override key saved specifically for OpenAI/Groq cloud ASR.
    public static func loadOpenAIASROverrideKey() -> String {
        return readSlot(openAIASRAccount) ?? ""
    }

    /// Effective API key for OpenAI / Groq cloud ASR:
    /// 1. Uses the dedicated `openai_asr_api_key` override slot if configured.
    /// 2. Otherwise automatically reuses the saved OpenAI LLM key (`openai_api_key`) unless the endpoint is Groq (which requires a Groq `gsk_...` key).
    public static func loadEffectiveOpenAIASRAPIKey(for baseURL: String = "https://api.openai.com/v1") -> String {
        let overrideKey = loadOpenAIASROverrideKey().trimmingCharacters(in: .whitespacesAndNewlines)
        if !overrideKey.isEmpty {
            return overrideKey
        }
        if baseURL.lowercased().contains("groq.com") {
            return ""
        }
        return loadAPIKey(for: .openai)
    }

    public static func isReusingOpenAILLMKeyForASR(baseURL: String) -> Bool {
        let overrideKey = loadOpenAIASROverrideKey().trimmingCharacters(in: .whitespacesAndNewlines)
        guard overrideKey.isEmpty, !baseURL.lowercased().contains("groq.com") else { return false }
        return !loadAPIKey(for: .openai).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func providerSlot(for provider: LLMProviderOption) -> String {
        switch provider {
        case .deepseek: return "deepseek_api_key"
        case .volcengine: return "ark_api_key"
        case .dashscope: return "dashscope_api_key"
        case .openai: return "openai_api_key"
        case .gemini: return "gemini_api_key"
        case .anthropic: return "anthropic_api_key"
        case .custom: return "custom_api_key"
        }
    }

    public static func providerSlot(for baseURL: String) -> String {
        return providerSlot(for: LLMProviderOption.infer(from: baseURL))
    }

    public static func hasSavedAPIKey(for provider: LLMProviderOption) -> Bool {
        return !loadAPIKey(for: provider).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func saveAPIKey(_ key: String, for provider: LLMProviderOption) {
        saveAPIKeyInSlot(key, slot: providerSlot(for: provider))
    }

    public static func loadAPIKey(for provider: LLMProviderOption) -> String {
        if let envKey = ProcessInfo.processInfo.environment["NEVERTYPE_API_KEY"], !envKey.isEmpty {
            return envKey
        }
        let slot = providerSlot(for: provider)
        if let val = readSlot(slot), !val.isEmpty {
            return val
        }
        if slot == "deepseek_api_key", let legacy = readSlot(legacyAccount), !legacy.isEmpty {
            saveAPIKeyInSlot(legacy, slot: slot)
            return legacy
        }
        return ""
    }

    public static func saveAPIKey(_ key: String, for baseURL: String = "https://api.deepseek.com/v1") {
        saveAPIKeyInSlot(key, slot: providerSlot(for: baseURL))
    }

    private static func saveAPIKeyInSlot(_ key: String, slot: String) {
        var cleaned = key.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if cleaned.lowercased().hasPrefix("bearer ") {
            cleaned = String(cleaned.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        deleteSlot(slot)
        guard !cleaned.isEmpty, let data = cleaned.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: slot,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    public static func loadAPIKey(for baseURL: String = "https://api.deepseek.com/v1") -> String {
        return loadAPIKey(for: LLMProviderOption.infer(from: baseURL))
    }

    private static func readSlot(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    private static func deleteSlot(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
