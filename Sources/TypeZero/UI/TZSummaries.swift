import Foundation

// MARK: - Engine + privacy summaries
//
// Both are derived from the live configuration. The inputs are plain values so the logic can be unit-tested and the
// sidebar card can be previewed for cloud setups without touching the real configuration.

struct TZEngineInputs {
    var config: LLMConfig
    var isGroqASR: Bool = false
    var localLoaded: Bool = false
    var installedLocal: Set<LocalASRModel> = []
    var activeLocal: LocalASRModel? = nil
    var hasOpenAIASRKey: Bool = false
    var hasVolcCredential: Bool = false
    var hasCleanupKey: Bool = false

    @MainActor
    init(appState: AppState) {
        self.config = appState.llmConfig
        self.isGroqASR = appState.isGroqASRSelected
        self.localLoaded = appState.senseVoiceLoaded
        self.installedLocal = appState.installedLocalModels
        self.activeLocal = appState.activeLocalModel
        // Reads the keychain, so only ask when the OpenAI/Groq engine is the selected one (this runs on every render).
        self.hasOpenAIASRKey = appState.llmConfig.asrProvider == .openAIWhisper ? appState.hasEffectiveOpenAIASRKey : false
        self.hasVolcCredential = appState.hasOwnVolcSpeechKey
        self.hasCleanupKey = appState.savedProviderKeyFlags[appState.llmConfig.selectedProvider] ?? false
    }

    init(config: LLMConfig) {
        self.config = config
    }

    /// The cleanup endpoint lives on this Mac.
    var cleanupIsLocal: Bool {
        config.selectedProvider == .custom && PolishEngine.isKeylessLocalEndpoint(config.baseURL)
    }

    var cleanupIsOllama: Bool {
        let u = config.baseURL.lowercased()
        return u.contains(":11434") || u.contains("ollama")
    }

    var cleanupIsOff: Bool { config.formattingStyle == .verbatimLocal }

    /// Name of a custom (non-local) endpoint, e.g. "OpenRouter".
    var customEndpointName: String {
        let u = config.baseURL.lowercased()
        if u.contains("openrouter.ai") { return "OpenRouter" }
        if u.contains("siliconflow") { return "SiliconFlow" }
        if u.contains("minimax") { return "MiniMax" }
        if u.contains("groq.com") { return "Groq" }
        if u.contains("together") { return "Together AI" }
        if let host = URL(string: config.baseURL)?.host, !host.isEmpty { return host }
        return "a custom endpoint"
    }

    var asrCloudName: String {
        switch config.asrProvider {
        case .volcSeedASR: return "Volcengine (Doubao Seed-ASR)"
        case .openAIWhisper:
            if isGroqASR { return "Groq" }
            let u = config.openAIASRBaseURL.lowercased()
            if u.contains("openai.com") { return "OpenAI" }
            if let host = URL(string: config.openAIASRBaseURL)?.host, !host.isEmpty { return host }
            return "OpenAI"
        case .localSenseVoice: return "this Mac"
        }
    }

    var asrIsLocalServer: Bool {
        config.asrProvider == .openAIWhisper && PolishEngine.isKeylessLocalEndpoint(config.openAIASRBaseURL)
    }
}

struct TZEngineLine: Equatable {
    var title: String
    var detail: String
    var tone: TZStatusDot.Tone
}

struct TZEnginesSummary: Equatable {
    var speech: TZEngineLine
    var cleanup: TZEngineLine

    static func make(_ i: TZEngineInputs) -> TZEnginesSummary {
        TZEnginesSummary(speech: speechLine(i), cleanup: cleanupLine(i))
    }

    private static func speechLine(_ i: TZEngineInputs) -> TZEngineLine {
        switch i.config.asrProvider {
        case .localSenseVoice:
            let model = i.activeLocal ?? i.config.localASRModel
            if i.installedLocal.isEmpty && !i.localLoaded {
                return TZEngineLine(title: model.shortName, detail: "Not installed", tone: .amber)
            }
            if i.localLoaded {
                return TZEngineLine(title: model.shortName, detail: "On-device", tone: .green)
            }
            return TZEngineLine(title: model.shortName, detail: "On-device · loading", tone: .amber)
        case .openAIWhisper:
            let ready = i.hasOpenAIASRKey
            if i.asrIsLocalServer {
                return TZEngineLine(title: i.config.openAIASRModel, detail: "Local server", tone: .green)
            }
            let provider = i.isGroqASR ? "Groq Whisper" : "OpenAI"
            return TZEngineLine(
                title: provider,
                detail: ready ? "Cloud · \(i.config.openAIASRModel)" : "Cloud · API key needed",
                tone: ready ? .green : .amber
            )
        case .volcSeedASR:
            return TZEngineLine(
                title: "Doubao Seed-ASR",
                detail: i.hasVolcCredential ? "Cloud" : "Cloud · API key needed",
                tone: i.hasVolcCredential ? .green : .amber
            )
        }
    }

    private static func cleanupLine(_ i: TZEngineInputs) -> TZEngineLine {
        if i.cleanupIsOff {
            return TZEngineLine(title: "No cleanup", detail: "Verbatim mode", tone: .gray)
        }
        let provider = i.config.selectedProvider
        if provider == .custom {
            if i.cleanupIsLocal {
                let server = i.cleanupIsOllama ? "Ollama" : "Local server"
                return TZEngineLine(title: i.config.modelName, detail: "\(server) · local", tone: .green)
            }
            let ready = i.hasCleanupKey
            return TZEngineLine(title: i.customEndpointName, detail: i.config.modelName, tone: ready ? .green : .amber)
        }
        return TZEngineLine(
            title: provider.shortName,
            detail: i.hasCleanupKey ? i.config.modelName : "API key needed",
            tone: i.hasCleanupKey ? .green : .amber
        )
    }
}

struct TZPrivacySummary: Equatable {
    var isFullyLocal: Bool
    var text: String

    private enum Speech {
        case onDevice(String)
        case appleFallback
        case cloud(String)
    }

    private enum Cleanup {
        case off
        case local(String)
        case cloud(String)
    }

    static func make(_ i: TZEngineInputs) -> TZPrivacySummary {
        let speech: Speech
        switch i.config.asrProvider {
        case .localSenseVoice:
            if i.installedLocal.isEmpty && !i.localLoaded {
                speech = .appleFallback
            } else {
                speech = .onDevice((i.activeLocal ?? i.config.localASRModel).tzFamilyName)
            }
        case .openAIWhisper:
            speech = i.asrIsLocalServer ? .onDevice("your local speech server") : .cloud(i.asrCloudName)
        case .volcSeedASR:
            speech = .cloud(i.asrCloudName)
        }

        let cleanup: Cleanup
        if i.cleanupIsOff {
            cleanup = .off
        } else if i.cleanupIsLocal {
            cleanup = .local(i.cleanupIsOllama ? "Ollama" : "model server")
        } else if i.config.selectedProvider == .custom {
            cleanup = .cloud(i.customEndpointName)
        } else {
            cleanup = .cloud(i.config.selectedProvider.shortName)
        }

        switch (speech, cleanup) {
        case (.onDevice(let model), .local(let server)):
            let engine = model.hasPrefix("your ") ? model : "on-device with \(model)"
            return TZPrivacySummary(
                isFullyLocal: true,
                text: "Speech recognition runs \(engine), and cleanup runs on your local \(server) model. Nothing leaves this Mac."
            )
        case (.onDevice(let model), .off):
            let engine = model.hasPrefix("your ") ? model : "on-device with \(model)"
            return TZPrivacySummary(
                isFullyLocal: true,
                text: "Speech recognition runs \(engine) and cleanup is turned off. Nothing leaves this Mac."
            )
        case (.onDevice(let model), .cloud(let name)):
            let engine = model.hasPrefix("your ") ? model : "on-device with \(model)"
            return TZPrivacySummary(
                isFullyLocal: false,
                text: "Speech recognition runs \(engine), so audio stays on this Mac. Your transcribed text is sent to \(name) for cleanup."
            )
        case (.appleFallback, let cleanup):
            // Without a speech model, dictation uses macOS speech recognition restricted to on-device recognition: the audio
            // never leaves this Mac (when macOS cannot recognize on-device here, dictation stops instead).
            let lead = "No speech model is installed yet, so dictation uses macOS on-device speech recognition and your audio stays on this Mac."
            switch cleanup {
            case .off:
                return TZPrivacySummary(isFullyLocal: true, text: "\(lead) Cleanup is turned off. Nothing leaves this Mac.")
            case .local(let server):
                return TZPrivacySummary(isFullyLocal: true, text: "\(lead) Cleanup runs on your local \(server) model. Nothing leaves this Mac.")
            case .cloud(let name):
                return TZPrivacySummary(isFullyLocal: false, text: "\(lead) Your transcribed text is sent to \(name) for cleanup.")
            }
        case (.cloud(let name), .local(let server)):
            return TZPrivacySummary(
                isFullyLocal: false,
                text: "Your audio is sent to \(name) for transcription. Cleanup runs on your local \(server) model."
            )
        case (.cloud(let name), .off):
            return TZPrivacySummary(
                isFullyLocal: false,
                text: "Your audio is sent to \(name) for transcription. Cleanup is turned off."
            )
        case (.cloud(let name), .cloud(let cleanupName)):
            return TZPrivacySummary(
                isFullyLocal: false,
                text: "Your audio is sent to \(name) for transcription, and the transcribed text is sent to \(cleanupName) for cleanup."
            )
        }
    }
}
