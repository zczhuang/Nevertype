import Foundation

public enum SidebarTab: String, CaseIterable, Identifiable, Sendable {
    // Not persisted or decoded anywhere: the raw value doubles as the sidebar label, so it is plain English.
    case home = "Overview"
    case history = "History"
    case dictionary = "Dictionary"
    case settings = "Engine & shortcuts"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .home: return "sparkles.rectangle.stack"
        case .history: return "clock.arrow.circlepath"
        case .dictionary: return "character.book.closed"
        case .settings: return "slider.horizontal.3"
        }
    }
}

public enum DictationMode: String, Codable {
    // The raw values are persisted inside history.json (`DictationRecord.mode`) - never rename them.
    // Show `displayName` in the UI instead of `rawValue`.
    case dictate = "口述成稿"
    case rewriteSelection = "选中改写"

    public var displayName: String {
        switch self {
        case .dictate: return "Dictation"
        case .rewriteSelection: return "Rewrite selection"
        }
    }
}

public enum PipelinePhase: Equatable {
    case idle
    case listening(livePreview: String, mode: DictationMode)
    case polishing(rawText: String)
    case completed(finalText: String, latencyMs: Int)
    /// The cleaned text had nowhere to go (no text field has focus). The pill shows a one-line preview and a Copy button; the full
    /// text waits here, and nothing is written to the clipboard until the button is clicked.
    case readyToCopy(text: String)
    /// The Copy button was clicked: the pill says "Copied" for a moment, then hides.
    case copied
    case error(message: String)
}

/// The Copy pill (see `PipelinePhase.readyToCopy`): what it previews and how long it stays up.
public enum CopyPill {
    /// Longest preview, in characters. The pill cuts what does not fit its width on top of this (and a very long dictation never
    /// reaches the layout engine in full).
    public static let previewCharacterLimit = 80

    /// One line for the pill: every run of whitespace, line breaks included, becomes a single space; longer than
    /// `previewCharacterLimit` is cut and ended with an ellipsis.
    public static func preview(of text: String, limit: Int = previewCharacterLimit) -> String {
        let oneLine = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard oneLine.count > limit else { return oneLine }
        return String(oneLine.prefix(max(1, limit - 1))).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// How long the Copy pill waits for a click: 8 s, paused while the pointer is over it. The caller supplies the clock, so the timing can
/// be tested without waiting.
public struct CopyPillCountdown: Equatable {
    /// Seconds the pill stays up when nobody clicks.
    public static let visibleSeconds: Double = 8
    /// Seconds the "Copied" confirmation stays up.
    public static let copiedSeconds: Double = 1

    /// Seconds left as of the last `start` / `pause`.
    public private(set) var remaining: Double = CopyPillCountdown.visibleSeconds
    private var runningSince: Date?

    public init() {}

    public var isRunning: Bool { runningSince != nil }

    /// Begins a fresh countdown of `visibleSeconds`.
    public mutating func start(now: Date) {
        remaining = Self.visibleSeconds
        runningSince = now
    }

    /// Stops the clock (the pointer is over the pill), keeping what was left.
    public mutating func pause(now: Date) {
        guard let since = runningSince else { return }
        remaining = max(0, remaining - now.timeIntervalSince(since))
        runningSince = nil
    }

    /// Continues from what `pause` kept.
    public mutating func resume(now: Date) {
        guard runningSince == nil else { return }
        runningSince = now
    }
}

/// Why a dictation could not start or had to stop, worded for two places.
///
/// `pillText` goes into the floating pill, which has room for two short lines (about 60 characters).
/// `detail` is the complete explanation, shown by the main window as a warning banner.
public struct DictationFailure: Equatable, Sendable {
    /// Longest `pillText`, in characters.
    public static let pillCharacterLimit = 60
    /// How long the error pill stays on screen, in seconds: long enough to read two lines.
    public static let displaySeconds: Double = 5.0

    /// Pill text when the transcript held only filler sounds (see `PolishEngine.isFillerOnlyTranscript`). Nothing is wrong, so
    /// there is no banner and the pill goes away sooner (`noSpeechDisplaySeconds`).
    public static let noSpeechPillText = "No speech detected"
    public static let noSpeechDisplaySeconds: Double = 2.0

    public let pillText: String
    public let detail: String

    /// Main-window banner text. The leading emoji picks the banner style (see `TZStatusMessage`).
    public var bannerText: String { "⚠️ " + detail }

    public static let accessibilityOff = DictationFailure(
        pillText: "Turn on Accessibility for \(AppBrand.name) in System Settings",
        detail: "\(AppBrand.name) needs Accessibility access to type into other apps. Turn it on in System Settings → Privacy & Security → Accessibility, then try again."
    )
    public static let microphoneOff = DictationFailure(
        pillText: "Allow microphone access in System Settings",
        detail: "\(AppBrand.name) can't hear you because microphone access is off. Allow it in System Settings → Privacy & Security → Microphone, then try again."
    )
    public static let speechRecognitionOff = DictationFailure(
        pillText: "Allow Speech Recognition in System Settings",
        detail: "\(AppBrand.name) needs Speech Recognition access to transcribe your voice. Allow it in System Settings → Privacy & Security → Speech Recognition, then try again."
    )
    /// The fixed permission failures, for the self-tests.
    public static let permissionFailures = [accessibilityOff, microphoneOff, speechRecognitionOff]

    /// No speech model is installed and macOS cannot recognize speech on this Mac either. Dictation never falls back to
    /// server recognition, so it stops here.
    public static let onDeviceSpeechUnavailable = DictationFailure(
        pillText: "Download a speech model in Settings",
        detail: "\(AppBrand.name) needs a speech model. None is installed, and macOS on-device speech recognition isn't available for your language on this Mac. Download a speech model in Settings → Speech recognition. \(AppBrand.name) never sends your audio to Apple's servers."
    )

    /// Wraps an error reported by the speech engine. `detail` keeps its full wording on one line; `pillText` is a
    /// copy cut down to `pillCharacterLimit` characters.
    public static func engineError(_ message: String) -> DictationFailure {
        let detail = message.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if detail == onDeviceSpeechUnavailable.detail { return onDeviceSpeechUnavailable }
        guard !detail.isEmpty else {
            return DictationFailure(
                pillText: "Dictation failed. Please try again.",
                detail: "Dictation failed for an unknown reason. Please try again."
            )
        }
        // The cloud failure prefix would otherwise use up half the pill before the actual reason starts.
        let brief = detail.replacingOccurrences(of: "Cloud speech recognition failed:", with: "Cloud speech failed:")
        return DictationFailure(pillText: shortened(brief, limit: pillCharacterLimit), detail: detail)
    }

    /// `text` unchanged when it has at most `limit` characters; otherwise cut at a word boundary (when that keeps at
    /// least half of the allowed length) and ended with an ellipsis, so the result never exceeds `limit`.
    static func shortened(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        var head = String(text.prefix(limit - 1))
        if let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) >= limit / 2 {
            head = String(head[..<space])
        }
        let edgeCharacters = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        return head.trimmingCharacters(in: edgeCharacters) + "…"
    }
}

public enum TriggerKeyOption: String, CaseIterable, Codable, Identifiable, Sendable {
    case fnKey = "fn"
    case leftOption = "leftOption"
    case rightOption = "rightOption"
    case leftCommand = "leftCommand"
    case rightCommand = "rightCommand"
    case leftControl = "leftControl"
    case rightControl = "rightControl"
    case leftShift = "leftShift"
    case rightShift = "rightShift"
    case optionSpace = "optionSpace"
    case custom = "custom"

    public var id: String { rawValue }

    /// Ordered 2×5 symmetric preset matrix (Row 1: Fn + Left/Right Option + Left/Right Command; Row 2: ⌥Space + Left/Right Control + Left/Right Shift).
    public static let presetMatrixOrder: [TriggerKeyOption] = [
        .fnKey, .leftOption, .rightOption, .leftCommand, .rightCommand,
        .optionSpace, .leftControl, .rightControl, .leftShift, .rightShift
    ]

    public var displayName: String {
        switch self {
        case .fnKey: return "Fn (Globe)"
        case .leftOption: return "Left Option (⌥)"
        case .rightOption: return "Right Option (⌥)"
        case .leftCommand: return "Left Command (⌘)"
        case .rightCommand: return "Right Command (⌘)"
        case .leftControl: return "Left Control (⌃)"
        case .rightControl: return "Right Control (⌃)"
        case .leftShift: return "Left Shift (⇧)"
        case .rightShift: return "Right Shift (⇧)"
        case .optionSpace: return "Option + Space (⌥Space)"
        case .custom: return "Custom shortcut"
        }
    }

    public var shortLabel: String {
        switch self {
        case .fnKey: return "Fn (Globe)"
        case .leftOption: return "Left Option ⌥"
        case .rightOption: return "Right Option ⌥"
        case .leftCommand: return "Left Command ⌘"
        case .rightCommand: return "Right Command ⌘"
        case .leftControl: return "Left Control ⌃"
        case .rightControl: return "Right Control ⌃"
        case .leftShift: return "Left Shift ⇧"
        case .rightShift: return "Right Shift ⇧"
        case .optionSpace: return "⌥ + Space"
        case .custom: return "Custom"
        }
    }

    public var compactSidebarLabel: String {
        switch self {
        case .fnKey: return "Fn (Globe)"
        case .leftOption: return "Left Option"
        case .rightOption: return "Right Option"
        case .leftCommand: return "Left Command"
        case .rightCommand: return "Right Command"
        case .leftControl: return "Left Control"
        case .rightControl: return "Right Control"
        case .leftShift: return "Left Shift"
        case .rightShift: return "Right Shift"
        case .optionSpace: return "⌥ + Space"
        case .custom: return "Custom"
        }
    }

    /// Left-side typing modifiers frequently used in `⌘+C` / `⇧+A` / `⌃+C` combos — protected by hold-to-talk combo debounce.
    public var isComboProneLeftModifier: Bool {
        switch self {
        case .leftOption, .leftCommand, .leftControl, .leftShift:
            return true
        default:
            return false
        }
    }

    public var isSingleModifierKey: Bool {
        switch self {
        case .optionSpace, .custom:
            return false
        default:
            return true
        }
    }
}

public struct CustomHotkeySpec: Codable, Equatable, Sendable {
    public var keyCode: UInt16
    public var carbonModifiers: UInt32
    public var label: String

    /// Default custom shortcut: `⌃ + Space` (`kVK_Space = 49`, `controlKey = 4096`)
    public static let `default` = CustomHotkeySpec(keyCode: 49, carbonModifiers: 4096, label: "⌃ + Space")

    public init(keyCode: UInt16, carbonModifiers: UInt32, label: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.label = label
    }
}

public enum ASRProviderOption: String, CaseIterable, Codable, Identifiable, Sendable {
    case volcSeedASR = "volcSeedASR"
    case openAIWhisper = "openAIWhisper"
    /// Raw value is persisted. Despite the legacy name this is the generic "local offline engine" slot:
    /// the model behind it (Parakeet TDT v2 or SenseVoice) is `LLMConfig.localASRModel`.
    case localSenseVoice = "localSenseVoice"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .volcSeedASR: return "Doubao streaming speech model 2.0"
        case .openAIWhisper: return "OpenAI / Groq cloud speech models"
        case .localSenseVoice: return "Local offline engine (Parakeet / SenseVoice)"
        }
    }

    public var shortName: String {
        switch self {
        case .volcSeedASR: return "Doubao Seed-ASR"
        case .openAIWhisper: return "OpenAI / Groq"
        case .localSenseVoice: return "Local offline"
        }
    }
}

public enum LLMProviderOption: String, CaseIterable, Codable, Identifiable, Sendable {
    case deepseek = "deepseek"
    case volcengine = "volcengine"
    case dashscope = "dashscope"
    case openai = "openai"
    case gemini = "gemini"
    case anthropic = "anthropic"
    case custom = "custom"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .deepseek: return "DeepSeek 4 Flash"
        case .volcengine: return "Volcengine Ark Doubao-Seed"
        case .dashscope: return "Alibaba DashScope Qwen-Flash"
        case .openai: return "OpenAI GPT"
        case .gemini: return "Google Gemini"
        case .anthropic: return "Anthropic Claude"
        case .custom: return "Custom OpenAI-compatible endpoint"
        }
    }

    public var shortName: String {
        switch self {
        case .deepseek: return "DeepSeek"
        case .volcengine: return "Volcengine Ark"
        case .dashscope: return "DashScope"
        case .openai: return "OpenAI"
        case .gemini: return "Gemini"
        case .anthropic: return "Claude"
        case .custom: return "Custom endpoint"
        }
    }

    public var subtitle: String {
        switch self {
        case .deepseek: return "DeepSeek's OpenAI-compatible chat API"
        case .volcengine: return "ByteDance Doubao models · supports Seed-2.1-lite or ep- endpoints"
        case .dashscope: return "Alibaba Cloud OpenAI-compatible mode · Qwen models"
        case .openai: return "Direct OpenAI API · works with gpt-4.1-mini / gpt-5-mini / gpt-4o-mini"
        case .gemini: return "Google AI Studio OpenAI-compatible endpoint · supports gemini-3.8-flash / 2.5-flash"
        case .anthropic: return "Anthropic native Messages streaming API · supports claude-haiku-5-5 / 4-5"
        case .custom: return "Local Ollama · also works with SiliconFlow / OpenRouter / MiniMax"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .deepseek: return "https://api.deepseek.com/v1"
        case .volcengine: return "https://ark.cn-beijing.volces.com/api/v3"
        case .dashscope: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .openai: return "https://api.openai.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .custom: return "http://127.0.0.1:11434/v1"
        }
    }

    public var defaultModelName: String {
        switch self {
        case .deepseek: return "deepseek-flash"
        case .volcengine: return "doubao-seed-2-1-lite-260915"
        case .dashscope: return "qwen-flash"
        case .openai: return "gpt-4.1-mini"
        case .gemini: return "gemini-3.8-flash"
        case .anthropic: return "claude-haiku-5-5"
        case .custom: return "gemma4:12b-mlx"
        }
    }

    public static func infer(from baseURL: String) -> LLMProviderOption {
        let u = baseURL.lowercased()
        if u.contains("deepseek.com") { return .deepseek }
        if u.contains("volces.com") || u.contains("volcengine") { return .volcengine }
        if u.contains("aliyuncs.com") { return .dashscope }
        if u.contains("openai.com") { return .openai }
        if u.contains("generativelanguage.googleapis.com") { return .gemini }
        if u.contains("anthropic.com") { return .anthropic }
        return .custom
    }
}

public enum TriggerBehavior: String, CaseIterable, Codable, Identifiable {
    case tapToggle = "tapToggle"
    case holdToTalk = "holdToTalk"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .tapToggle: return "Tap to start · tap again to stop (hands-free)"
        case .holdToTalk: return "Hold to talk · release to stop"
        }
    }
}

public enum FormattingStyle: String, CaseIterable, Codable, Identifiable {
    case structured = "structured"
    case lightPolish = "lightPolish"
    case verbatimLocal = "verbatimLocal"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .structured: return "Structured cleanup (removes fillers, fixes slips · auto paragraphs and numbered lists)"
        case .lightPolish: return "Light cleanup (removes fillers only · keeps your wording)"
        case .verbatimLocal: return "Verbatim (no LLM call · raw transcript, instantly)"
        }
    }
}

public enum LexiconCategory: String, CaseIterable, Codable, Identifiable, Sendable {
    // The raw values are persisted inside the personal lexicon JSON - never rename them.
    // Show `displayName` in the UI instead of `rawValue`.
    case person = "人名/称呼"
    case project = "项目/技术"
    case finance = "标的/商业"
    case memo = "纪要/备忘"
    case browser = "浏览高频"
    case autoLearned = "纠错自学习"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .person: return "People"
        case .project: return "Projects & tech"
        case .finance: return "Tickers & business"
        case .memo: return "Notes & memos"
        case .browser: return "Frequent sites"
        case .autoLearned: return "Auto-learned"
        }
    }
}

public struct LexiconEntry: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var term: String
    public var aliases: [String]
    public var phoneticKey: String
    public var category: LexiconCategory
    public var weight: Int
    public var hitCount: Int
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        term: String,
        aliases: [String] = [],
        phoneticKey: String = "",
        category: LexiconCategory = .project,
        weight: Int = 1,
        hitCount: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        self.aliases = aliases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        self.phoneticKey = phoneticKey.isEmpty ? PhoneticIndexer.normalize(term) : phoneticKey
        self.category = category
        self.weight = weight
        self.hitCount = hitCount
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        self.term = (try? c.decode(String.self, forKey: .term)) ?? ""
        self.aliases = (try? c.decode([String].self, forKey: .aliases)) ?? []
        let decodedPhonetic = (try? c.decode(String.self, forKey: .phoneticKey)) ?? ""
        self.phoneticKey = decodedPhonetic.isEmpty ? PhoneticIndexer.normalize(self.term) : decodedPhonetic
        self.category = (try? c.decode(LexiconCategory.self, forKey: .category)) ?? .project
        self.weight = (try? c.decode(Int.self, forKey: .weight)) ?? 5
        self.hitCount = (try? c.decode(Int.self, forKey: .hitCount)) ?? 0
        self.createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
    }
}

public struct DictationRecord: Identifiable, Codable {
    public var id: UUID
    public var timestamp: Date
    public var rawTranscript: String
    public var polishedText: String
    public var durationSeconds: Double
    public var polishLatencyMs: Int
    public var targetAppName: String
    public var mode: DictationMode
    public var matchedTerms: [String]

    public var characterCount: Int {
        polishedText.count
    }

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        rawTranscript: String,
        polishedText: String,
        durationSeconds: Double,
        polishLatencyMs: Int,
        targetAppName: String,
        mode: DictationMode = .dictate,
        matchedTerms: [String] = []
    ) {
        self.id = id
        self.timestamp = timestamp
        self.rawTranscript = rawTranscript
        self.polishedText = polishedText
        self.durationSeconds = max(0.2, durationSeconds)
        self.polishLatencyMs = polishLatencyMs
        self.targetAppName = targetAppName
        self.mode = mode
        self.matchedTerms = matchedTerms
    }
}

public struct LLMConfig: Codable, Equatable {
    public var selectedProvider: LLMProviderOption
    public var baseURL: String
    public var modelName: String
    public var customBaseURL: String
    public var providerModels: [String: String]
    public var formattingStyle: FormattingStyle
    public var asrProvider: ASRProviderOption
    /// Which on-device model backs the local engine (`asrProvider == .localSenseVoice`, also the cloud hot-standby).
    public var localASRModel: LocalASRModel
    public var openAIASRBaseURL: String
    public var openAIASRModel: String
    public var enableVolcSeedASR: Bool
    public var enableLiveInlineTyping: Bool
    public var enableFastBypassForShortPhrases: Bool
    public var stripTrailingPeriodInChatApps: Bool
    public var enablePanguSpacing: Bool
    public var enableWhisperAGC: Bool
    public var enableAutoLearn: Bool
    public var enableAutoMuteDuringDictation: Bool
    /// Short start / stop sounds around each dictation (Settings -> Output). Configs saved before this existed decode as on.
    public var enableSoundEffects: Bool
    public var showInDock: Bool
    public var speechLocale: String
    public var speechLocaleExplicitlySet: Bool
    /// Opt-in: copy past dictations from the Typeless app into History (Settings -> Import, shown only when Typeless's
    /// database exists). Off by default, and for every config saved before this existed. While it is off, nothing reads
    /// the Typeless database (see `TypelessSyncCoordinator`).
    public var enableTypelessImport: Bool

    public static let `default` = LLMConfig()

    /// Maps `speechLocale` (`"auto"`, `"zh-CN"`, `"en-US"`, etc.) to sherpa-onnx SenseVoice language token.
    public static func senseVoiceLanguageCode(for speechLocale: String) -> String {
        let trimmed = speechLocale.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty || trimmed == "auto" {
            return "auto"
        }
        if trimmed == "yue" || trimmed == "zh-hk" || trimmed == "zh_hk" {
            return "yue"
        }
        let head = trimmed.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? trimmed
        switch head {
        case "zh", "en", "ja", "ko", "yue":
            return head
        default:
            return "auto"
        }
    }

    public init(
        selectedProvider: LLMProviderOption? = nil,
        // Fork defaults: cleanup runs on a local Ollama model through the "Custom" OpenAI-compatible provider.
        baseURL: String = "http://127.0.0.1:11434/v1",
        modelName: String = "gemma4:12b-mlx",
        customBaseURL: String = "http://127.0.0.1:11434/v1",
        providerModels: [String: String] = [:],
        formattingStyle: FormattingStyle = .structured,
        // Fork default: speech-to-text runs on the local engine (Parakeet TDT v2) instead of a cloud provider.
        asrProvider: ASRProviderOption? = .localSenseVoice,
        localASRModel: LocalASRModel = .default,
        openAIASRBaseURL: String = "https://api.openai.com/v1",
        openAIASRModel: String = "gpt-4o-mini-transcribe",
        enableVolcSeedASR: Bool = true,
        enableLiveInlineTyping: Bool = true,
        enableFastBypassForShortPhrases: Bool = true,
        stripTrailingPeriodInChatApps: Bool = true,
        enablePanguSpacing: Bool = true,
        enableWhisperAGC: Bool = true,
        enableAutoLearn: Bool = true,
        enableAutoMuteDuringDictation: Bool = true,
        enableSoundEffects: Bool = true,
        showInDock: Bool = false,
        speechLocale: String = "auto",
        speechLocaleExplicitlySet: Bool = false,
        enableTypelessImport: Bool = false
    ) {
        let resolvedProvider = selectedProvider ?? LLMProviderOption.infer(from: baseURL)
        self.selectedProvider = resolvedProvider
        self.baseURL = baseURL
        self.modelName = modelName
        self.customBaseURL = (resolvedProvider == .custom && !baseURL.isEmpty) ? baseURL : customBaseURL
        var mergedModels = providerModels
        mergedModels[resolvedProvider.rawValue] = modelName
        self.providerModels = mergedModels
        self.formattingStyle = formattingStyle
        let resolvedASR = asrProvider ?? (enableVolcSeedASR ? .volcSeedASR : .localSenseVoice)
        self.asrProvider = resolvedASR
        self.localASRModel = localASRModel
        self.openAIASRBaseURL = openAIASRBaseURL
        self.openAIASRModel = openAIASRModel
        self.enableVolcSeedASR = (resolvedASR == .volcSeedASR)
        self.enableLiveInlineTyping = enableLiveInlineTyping
        self.enableFastBypassForShortPhrases = enableFastBypassForShortPhrases
        self.stripTrailingPeriodInChatApps = stripTrailingPeriodInChatApps
        self.enablePanguSpacing = enablePanguSpacing
        self.enableWhisperAGC = enableWhisperAGC
        self.enableAutoLearn = enableAutoLearn
        self.enableAutoMuteDuringDictation = enableAutoMuteDuringDictation
        self.enableSoundEffects = enableSoundEffects
        self.showInDock = showInDock
        self.speechLocale = speechLocale
        self.speechLocaleExplicitlySet = speechLocaleExplicitlySet
        self.enableTypelessImport = enableTypelessImport
    }

    public mutating func selectASRProvider(_ provider: ASRProviderOption) {
        asrProvider = provider
        enableVolcSeedASR = (provider == .volcSeedASR)
    }

    public mutating func selectProvider(_ provider: LLMProviderOption) {
        // Persist current provider's edits before switching
        providerModels[selectedProvider.rawValue] = modelName
        if selectedProvider == .custom && !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            customBaseURL = baseURL
        }
        selectedProvider = provider
        baseURL = (provider == .custom) ? customBaseURL : provider.defaultBaseURL
        let savedModel = providerModels[provider.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        modelName = savedModel.isEmpty ? provider.defaultModelName : savedModel
    }

    public mutating func syncActiveEndpointEdits() {
        providerModels[selectedProvider.rawValue] = modelName
        if selectedProvider == .custom && !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            customBaseURL = baseURL
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedURL = (try? c.decode(String.self, forKey: .baseURL)) ?? "https://api.deepseek.com/v1"
        let decodedModel = (try? c.decode(String.self, forKey: .modelName)) ?? "deepseek-flash"
        let upgradedModel = (decodedModel == "deepseek-chat" || decodedModel.isEmpty) ? "deepseek-flash" : decodedModel
        let inferredProvider = LLMProviderOption.infer(from: decodedURL)
        let resolvedProvider = (try? c.decode(LLMProviderOption.self, forKey: .selectedProvider)) ?? inferredProvider

        self.selectedProvider = resolvedProvider
        self.baseURL = decodedURL
        self.modelName = upgradedModel
        let decodedCustomURL = (try? c.decode(String.self, forKey: .customBaseURL)) ?? ""
        if !decodedCustomURL.isEmpty {
            self.customBaseURL = decodedCustomURL
        } else {
            self.customBaseURL = (resolvedProvider == .custom) ? decodedURL : LLMProviderOption.custom.defaultBaseURL
        }
        var modelsMap = (try? c.decode([String: String].self, forKey: .providerModels)) ?? [:]
        if let savedEp = UserDefaults.standard.string(forKey: "tz_ark_ep_id"),
           !savedEp.isEmpty,
           modelsMap[LLMProviderOption.volcengine.rawValue] == nil {
            modelsMap[LLMProviderOption.volcengine.rawValue] = savedEp
        }
        modelsMap[resolvedProvider.rawValue] = upgradedModel
        self.providerModels = modelsMap

        self.formattingStyle = (try? c.decode(FormattingStyle.self, forKey: .formattingStyle)) ?? .structured
        // A stored provider this build does not know (for example one that was removed) decodes to the default engine instead of
        // failing; only configs that predate `asrProvider` entirely fall back on the old `enableVolcSeedASR` flag.
        let resolvedASR: ASRProviderOption
        if c.contains(.asrProvider) {
            resolvedASR = (try? c.decode(ASRProviderOption.self, forKey: .asrProvider)) ?? LLMConfig.default.asrProvider
        } else {
            let legacyVolcFlag = (try? c.decode(Bool.self, forKey: .enableVolcSeedASR)) ?? true
            resolvedASR = legacyVolcFlag ? .volcSeedASR : .localSenseVoice
        }
        self.asrProvider = resolvedASR
        // Configs saved before this setting existed fall back to the default model; if its files are missing the
        // engine automatically uses the other installed model, so legacy SenseVoice-only machines keep working.
        self.localASRModel = (try? c.decode(LocalASRModel.self, forKey: .localASRModel)) ?? .default
        let decodedOpenAIASRURL = (try? c.decode(String.self, forKey: .openAIASRBaseURL)) ?? "https://api.openai.com/v1"
        self.openAIASRBaseURL = decodedOpenAIASRURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "https://api.openai.com/v1" : decodedOpenAIASRURL
        let decodedOpenAIASRModel = (try? c.decode(String.self, forKey: .openAIASRModel)) ?? "gpt-4o-mini-transcribe"
        self.openAIASRModel = decodedOpenAIASRModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "gpt-4o-mini-transcribe" : decodedOpenAIASRModel
        self.enableVolcSeedASR = (resolvedASR == .volcSeedASR)
        self.enableLiveInlineTyping = (try? c.decode(Bool.self, forKey: .enableLiveInlineTyping)) ?? true
        self.enableFastBypassForShortPhrases = (try? c.decode(Bool.self, forKey: .enableFastBypassForShortPhrases)) ?? true
        self.stripTrailingPeriodInChatApps = (try? c.decode(Bool.self, forKey: .stripTrailingPeriodInChatApps)) ?? true
        self.enablePanguSpacing = (try? c.decode(Bool.self, forKey: .enablePanguSpacing)) ?? true
        self.enableWhisperAGC = (try? c.decode(Bool.self, forKey: .enableWhisperAGC)) ?? true
        self.enableAutoLearn = (try? c.decode(Bool.self, forKey: .enableAutoLearn)) ?? true
        self.enableAutoMuteDuringDictation = (try? c.decode(Bool.self, forKey: .enableAutoMuteDuringDictation)) ?? true
        self.enableSoundEffects = (try? c.decode(Bool.self, forKey: .enableSoundEffects)) ?? true
        self.showInDock = (try? c.decode(Bool.self, forKey: .showInDock)) ?? false
        let explicitlySetLocale = (try? c.decode(Bool.self, forKey: .speechLocaleExplicitlySet)) ?? false
        let decodedLocale = ((try? c.decode(String.self, forKey: .speechLocale)) ?? "auto")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.speechLocaleExplicitlySet = explicitlySetLocale
        // Auto-migrate legacy v0.5.4 configs where `speechLocale` was hardcoded to `"zh-CN"` without UI control
        // so English/bilingual users no longer trigger forced `language=zh` translation in ASR models.
        if !explicitlySetLocale && (decodedLocale.isEmpty || decodedLocale == "zh-CN") {
            self.speechLocale = "auto"
        } else {
            self.speechLocale = decodedLocale.isEmpty ? "auto" : decodedLocale
        }
        self.enableTypelessImport = (try? c.decode(Bool.self, forKey: .enableTypelessImport)) ?? false
    }
}
