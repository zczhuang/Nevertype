import SwiftUI
import AppKit

// MARK: - Shared form pieces

/// "Label  [control]" row used inside expanded engine cards.
struct TZFormRow<Content: View>: View {
    let label: String
    var labelWidth: CGFloat = 78
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(TZTheme.inkSecondary)
                .frame(width: labelWidth, alignment: .leading)
            content()
        }
    }
}

/// White, rounded card with a clickable header that expands to reveal its settings.
struct TZEngineCard<Header: View, Trailing: View, Details: View>: View {
    let isActive: Bool
    /// Overrides the status dot (default: green when active, grey otherwise).
    var dotTone: TZStatusDot.Tone? = nil
    let isExpanded: Bool
    let onToggle: () -> Void
    @ViewBuilder let header: () -> Header
    @ViewBuilder let trailing: () -> Trailing
    @ViewBuilder let details: () -> Details

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                TZStatusDot(tone: dotTone ?? (isActive ? .green : .gray), size: 8)
                header()
                Spacer(minLength: 8)
                trailing()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(TZTheme.inkMuted)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 14)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.16)) { onToggle() }
            }

            if isExpanded {
                Rectangle().fill(TZTheme.border).frame(height: 1).padding(.vertical, 12)
                VStack(alignment: .leading, spacing: 12) {
                    details()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isActive ? TZTheme.blue.opacity(0.55) : TZTheme.border, lineWidth: isActive ? 1.25 : 1)
        )
    }
}

struct TZEngineTitle: View {
    let title: String
    var badge: String? = nil
    var detail: String? = nil
    var isActive: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(TZTheme.ink)
                    .lineLimit(1)
                if let badge, !badge.isEmpty {
                    Text(badge)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(TZTheme.inkSecondary)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(TZTheme.segmentTrack))
                }
            }
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(TZTheme.inkSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct TZKeyBadge: View {
    let isConfigured: Bool
    var keylessLocal: Bool = false

    var body: some View {
        if keylessLocal {
            TZBadge(text: "No key needed", tone: .neutral)
        } else if isConfigured {
            TZBadge(text: "Key saved", tone: .green, icon: "key.fill")
        } else {
            TZBadge(text: "Key needed", tone: .amber, icon: "key")
        }
    }
}

struct TZActiveBadge: View {
    let isActive: Bool

    var body: some View {
        if isActive {
            TZBadge(text: "Active", tone: .green, icon: "checkmark")
        }
    }
}

/// Secure field for API keys.
struct TZSecretField: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}

    var body: some View {
        SecureField(placeholder, text: $text)
            .tzField(height: 32)
            .onSubmit(onSubmit)
    }
}

// MARK: - Preset pill

struct TZPresetPill: View {
    let title: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: isActive ? .semibold : .medium))
                .foregroundStyle(isActive ? TZTheme.blue : TZTheme.inkSecondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(TZCapsuleSurface(
                    fill: isActive ? TZTheme.blueTint : Color.white,
                    border: isActive ? TZTheme.blue.opacity(0.35) : TZTheme.keycapBorder
                ))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Hotkey presets

struct TZHotkeyPresetGrid: View {
    @ObservedObject var appState: AppState
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 5)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(TriggerKeyOption.presetMatrixOrder) { option in
                let selected = appState.triggerKey == option
                Button {
                    if appState.isRecordingShortcut { appState.cancelShortcutCapture() }
                    appState.triggerKey = option
                } label: {
                    Text(option.shortLabel)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? TZTheme.blue : TZTheme.inkNav)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? TZTheme.blueTint : Color.white))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(selected ? TZTheme.blue.opacity(0.55) : TZTheme.keycapBorder, lineWidth: selected ? 1.25 : 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - On-device speech engine

struct TZLocalASRCard: View {
    @ObservedObject var appState: AppState
    let isExpanded: Bool
    let onToggle: () -> Void

    private var isActive: Bool { appState.llmConfig.asrProvider == .localSenseVoice }
    private var isActivating: Bool { appState.activatingASRProvider == .localSenseVoice }

    private var modelBadge: String {
        guard let active = appState.activeLocalModel else { return "no model" }
        if active == .senseVoice {
            return appState.senseVoiceFullFP32 ? "SenseVoice FP32" : "SenseVoice INT8"
        }
        return active.shortName
    }

    private var readiness: (text: String, tone: TZBadge.Tone) {
        if appState.senseVoiceLoaded { return ("Model ready", .green) }
        if appState.installedLocalModels.isEmpty { return ("No model installed", .amber) }
        return ("Loading model…", .amber)
    }

    var body: some View {
        TZEngineCard(
            isActive: isActive,
            dotTone: (isActive && !appState.senseVoiceLoaded) ? .amber : nil,
            isExpanded: isExpanded,
            onToggle: onToggle,
            header: {
                TZEngineTitle(
                    title: "On-device",
                    badge: modelBadge,
                    detail: (isExpanded || isActive) ? "Audio never leaves this Mac. Works offline, and is the fallback if a cloud engine drops." : nil
                )
            },
            trailing: {
                HStack(spacing: 6) {
                    TZBadge(text: readiness.text, tone: readiness.tone)
                    TZActiveBadge(isActive: isActive)
                }
            },
            details: { details }
        )
    }

    @ViewBuilder
    private var details: some View {
        if appState.isDownloadingOfflineModel {
            VStack(alignment: .leading, spacing: 8) {
                TZProgressBar(value: appState.offlineDownloadProgress)
                HStack(spacing: 10) {
                    Text(appState.offlineDownloadStatusText)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(TZTheme.blue)
                        .lineLimit(1)
                    Spacer()
                    Button("Cancel") { appState.cancelOfflineModelDownload() }
                        .buttonStyle(.tzDestructiveCompact)
                }
            }
        } else {
            TZFormRow(label: "Model") {
                TZSegmentedControl(
                    items: LocalASRModel.allCases.map { model in
                        .init(value: model, title: model.shortName + (model == .parakeetTDTv2 ? " · English" : " · multilingual"))
                    },
                    selection: Binding(
                        get: { appState.llmConfig.localASRModel },
                        set: { appState.selectLocalASRModel($0) }
                    ),
                    fontSize: 13.5
                )
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(LocalASRModel.allCases) { model in
                    let installed = appState.installedLocalModels.contains(model)
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.displayName)
                                .font(.system(size: 13.5, weight: .medium))
                                .foregroundStyle(TZTheme.ink)
                            Text(model.detail)
                                .font(.system(size: 12.5))
                                .foregroundStyle(TZTheme.inkSecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if installed {
                            TZBadge(text: appState.activeLocalModel == model ? "Installed · in use" : "Installed", tone: .green, icon: "checkmark")
                        } else {
                            Button("Download · \(model.approxDownloadMB) MB") {
                                appState.startLocalModelDownload(model)
                            }
                            .buttonStyle(.tzSecondaryCompact)
                        }
                    }
                }
            }

            if appState.installedLocalModels.isEmpty {
                TZInlineMessage(
                    message: "No on-device speech model is installed yet. Download Parakeet (English) or SenseVoice (multilingual) above.",
                    forceTone: .warning
                )
            } else if let active = appState.activeLocalModel, active != appState.llmConfig.localASRModel {
                TZInlineMessage(
                    message: "\(appState.llmConfig.localASRModel.shortName) is not installed, so \(active.shortName) is in use for now. Download \(appState.llmConfig.localASRModel.shortName) to switch.",
                    forceTone: .warning
                )
            }

            Text("Parakeet only transcribes English and ignores the recognition language above. SenseVoice and the cloud engines follow it.")
                .font(.system(size: 12.5))
                .foregroundStyle(TZTheme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)

            if !isActive {
                HStack {
                    Spacer()
                    Button(isActivating ? "Verifying…" : "Verify & switch") {
                        Task { _ = await appState.activateASRProvider(.localSenseVoice) }
                    }
                    .buttonStyle(.tzPrimaryCompact)
                    .disabled(appState.activatingASRProvider != nil)
                }
            }

            if let err = appState.asrActivationErrors[.localSenseVoice], !err.isEmpty {
                TZInlineMessage(message: err)
            }
        }
    }
}

// MARK: - OpenAI / Groq speech engine

struct TZOpenAIASRCard: View {
    @ObservedObject var appState: AppState
    let isExpanded: Bool
    let onToggle: () -> Void

    private var isActive: Bool { appState.llmConfig.asrProvider == .openAIWhisper }
    private var isActivating: Bool { appState.activatingASRProvider == .openAIWhisper }
    private var keylessLocal: Bool { PolishEngine.isKeylessLocalEndpoint(appState.llmConfig.openAIASRBaseURL) }
    private var ready: Bool { appState.hasEffectiveOpenAIASRKey }

    var body: some View {
        TZEngineCard(
            isActive: isActive,
            isExpanded: isExpanded,
            onToggle: onToggle,
            header: {
                TZEngineTitle(
                    title: "OpenAI / Groq",
                    badge: appState.llmConfig.openAIASRModel,
                    detail: (isExpanded || isActive) ? "Cloud transcription with gpt-4o-mini-transcribe or Groq whisper-large-v3-turbo. Sends audio to the provider." : nil
                )
            },
            trailing: {
                HStack(spacing: 6) {
                    if appState.isOpenAIASRReusingLLMKey {
                        TZBadge(text: "Using your OpenAI key", tone: .neutral)
                    } else {
                        TZKeyBadge(isConfigured: ready, keylessLocal: keylessLocal)
                    }
                    TZActiveBadge(isActive: isActive)
                }
            },
            details: { details }
        )
    }

    @ViewBuilder
    private var details: some View {
        TZFormRow(label: "Presets") {
            HStack(spacing: 6) {
                TZPresetPill(title: "OpenAI Mini", isActive: !appState.isGroqASRSelected && appState.llmConfig.openAIASRModel == "gpt-4o-mini-transcribe") {
                    appState.applyOpenAIASRPreset(baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini-transcribe")
                }
                TZPresetPill(title: "OpenAI Full", isActive: !appState.isGroqASRSelected && appState.llmConfig.openAIASRModel == "gpt-4o-transcribe") {
                    appState.applyOpenAIASRPreset(baseURL: "https://api.openai.com/v1", model: "gpt-4o-transcribe")
                }
                TZPresetPill(title: "Groq Whisper Turbo", isActive: appState.isGroqASRSelected) {
                    appState.applyOpenAIASRPreset(baseURL: "https://api.groq.com/openai/v1", model: "whisper-large-v3-turbo")
                }
                Spacer()
            }
        }

        TZFormRow(label: "Base URL") {
            TextField("https://api.openai.com/v1 or https://api.groq.com/openai/v1", text: $appState.llmConfig.openAIASRBaseURL)
                .tzField(height: 32)
            Text("Model")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(TZTheme.inkSecondary)
            TextField("gpt-4o-mini-transcribe", text: $appState.llmConfig.openAIASRModel)
                .tzField(height: 32)
                .frame(width: 190)
        }

        TZFormRow(label: "API key") {
            TZSecretField(
                placeholder: appState.isGroqASRSelected
                    ? "Paste your Groq API key (gsk_...)"
                    : (appState.isOpenAIASRReusingLLMKey
                        ? "Using your OpenAI cleanup key (leave empty, or paste a separate key)"
                        : "Paste your OpenAI API key"),
                text: $appState.openAIASRKeyInput,
                onSubmit: { appState.saveOpenAIASRConfig() }
            )
            Button("Save") { appState.saveOpenAIASRConfig() }
                .buttonStyle(.tzSecondaryCompact)
            Button(appState.isProbingOpenAIASR ? "Testing…" : "Test connection") {
                Task { await appState.runOpenAIASRProbe() }
            }
            .buttonStyle(.tzSecondaryCompact)
            .disabled(appState.isProbingOpenAIASR || appState.activatingASRProvider != nil)
            if !isActive {
                Button(isActivating ? "Verifying…" : "Verify & switch") {
                    Task { _ = await appState.activateASRProvider(.openAIWhisper) }
                }
                .buttonStyle(.tzPrimaryCompact)
                .disabled(appState.activatingASRProvider != nil)
            }
        }

        if let err = appState.asrActivationErrors[.openAIWhisper], !err.isEmpty {
            TZInlineMessage(message: err)
        } else if !appState.lastOpenAIASRProbeSummary.isEmpty {
            TZInlineMessage(message: appState.lastOpenAIASRProbeSummary)
        } else if !ready {
            TZInlineMessage(
                message: appState.isGroqASRSelected
                    ? "No Groq API key yet. Add one, then choose Verify & switch to turn this engine on."
                    : "No OpenAI API key found. Add one, then choose Verify & switch (the engine stays off without a key).",
                forceTone: .warning
            )
        }
    }
}

// MARK: - Doubao speech engine

struct TZDoubaoASRCard: View {
    @ObservedObject var appState: AppState
    let isExpanded: Bool
    let onToggle: () -> Void

    private var isActive: Bool { appState.llmConfig.asrProvider == .volcSeedASR }
    private var isActivating: Bool { appState.activatingASRProvider == .volcSeedASR }
    private var hasKey: Bool { appState.hasOwnVolcSpeechKey }

    var body: some View {
        TZEngineCard(
            isActive: isActive,
            isExpanded: isExpanded,
            onToggle: onToggle,
            header: {
                TZEngineTitle(
                    title: "Doubao Seed-ASR 2.0",
                    badge: "cloud",
                    detail: (isExpanded || isActive) ? "ByteDance's streaming speech service (Volcengine). Uses your dictionary as hot words and falls back to the on-device model when offline." : nil
                )
            },
            trailing: {
                HStack(spacing: 6) {
                    TZKeyBadge(isConfigured: hasKey)
                    TZActiveBadge(isActive: isActive)
                }
            },
            details: { details }
        )
    }

    @ViewBuilder
    private var details: some View {
        TZFormRow(label: "API key") {
            TZSecretField(
                placeholder: "Paste your Volcengine Doubao speech API key",
                text: $appState.volcSpeechKeyInput,
                onSubmit: { appState.saveVolcSpeechAPIKey() }
            )
            Button("Save") { appState.saveVolcSpeechAPIKey() }
                .buttonStyle(.tzSecondaryCompact)
            Button(appState.isProbingSeedASR ? "Testing…" : "Test connection") {
                Task { await appState.runSeedASRProbe() }
            }
            .buttonStyle(.tzSecondaryCompact)
            .disabled(appState.isProbingSeedASR || appState.activatingASRProvider != nil)
            if !isActive {
                Button(isActivating ? "Verifying…" : "Verify & switch") {
                    Task { _ = await appState.activateASRProvider(.volcSeedASR) }
                }
                .buttonStyle(.tzPrimaryCompact)
                .disabled(appState.activatingASRProvider != nil)
            }
        }

        if let err = appState.asrActivationErrors[.volcSeedASR], !err.isEmpty {
            TZInlineMessage(message: err)
        } else if !appState.lastSeedASRProbeSummary.isEmpty {
            TZInlineMessage(message: appState.lastSeedASRProbeSummary)
        } else if !hasKey {
            TZInlineMessage(
                message: "No Doubao API key yet. Add one, then choose Verify & switch to turn this engine on.",
                forceTone: .warning
            )
        }
    }
}

// MARK: - Cleanup model provider card

/// `--render-ui` only: stand-in for the keychain so snapshots never read real API keys.
enum TZPreviewKeys {
    nonisolated(unsafe) static var override: [LLMProviderOption: String]? = nil

    static func storedKey(for provider: LLMProviderOption) -> String {
        if let override { return override[provider] ?? "" }
        return KeychainHelper.loadAPIKey(for: provider)
    }
}

struct LLMProviderUnifiedCard: View {
    @ObservedObject var appState: AppState
    let provider: LLMProviderOption
    let isExpanded: Bool
    let onToggleExpand: () -> Void

    @State private var draftAPIKey: String = ""
    @State private var draftModelName: String = ""
    @State private var draftBaseURL: String = ""
    @State private var didLoadDraft: Bool = false

    private func syncDraftFromStore() {
        draftAPIKey = TZPreviewKeys.storedKey(for: provider)
        if appState.llmConfig.selectedProvider == provider {
            draftModelName = appState.llmConfig.modelName
            draftBaseURL = appState.llmConfig.baseURL
        } else {
            draftModelName = appState.llmConfig.providerModels[provider.rawValue] ?? provider.defaultModelName
            draftBaseURL = (provider == .custom && !appState.llmConfig.customBaseURL.isEmpty)
                ? appState.llmConfig.customBaseURL
                : provider.defaultBaseURL
        }
        didLoadDraft = true
    }

    var body: some View {
        let isActive = appState.llmConfig.selectedProvider == provider
        let modelBadge = isActive
            ? appState.llmConfig.modelName
            : (appState.llmConfig.providerModels[provider.rawValue] ?? provider.defaultModelName)
        let effectiveURL = didLoadDraft
            ? draftBaseURL
            : (isActive
                ? appState.llmConfig.baseURL
                : ((provider == .custom && !appState.llmConfig.customBaseURL.isEmpty) ? appState.llmConfig.customBaseURL : provider.defaultBaseURL))
        let isLocalKeyless = PolishEngine.isKeylessLocalEndpoint(effectiveURL)
        let hasKey = didLoadDraft
            ? (!draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLocalKeyless)
            : ((appState.savedProviderKeyFlags[provider] ?? false) || isLocalKeyless)
        let isActivatingThis = appState.activatingLLMProvider == provider
        let activationError = appState.llmActivationErrors[provider]
        let benchmarkSummary = appState.llmProviderBenchmarkSummaries[provider]
            ?? (isActive ? appState.lastBenchmarkSummary : "")

        TZEngineCard(
            isActive: isActive,
            isExpanded: isExpanded,
            onToggle: {
                // Tapping the header only expands or collapses; it never switches the active model.
                if !didLoadDraft { syncDraftFromStore() }
                onToggleExpand()
            },
            header: {
                TZEngineTitle(
                    title: provider.title,
                    badge: modelBadge,
                    detail: (isExpanded || isActive) ? provider.subtitle : nil
                )
            },
            trailing: {
                HStack(spacing: 6) {
                    TZKeyBadge(isConfigured: hasKey && !isLocalKeyless, keylessLocal: isLocalKeyless)
                    TZActiveBadge(isActive: isActive)
                }
            },
            details: {
                if provider == .custom {
                    TZFormRow(label: "Base URL") {
                        TextField("https://api.siliconflow.cn/v1 or http://localhost:11434/v1", text: $draftBaseURL)
                            .tzField(height: 32)
                        Text("Model")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(TZTheme.inkSecondary)
                        TextField("Model name", text: $draftModelName)
                            .tzField(height: 32)
                            .frame(width: 190)
                    }
                }

                TZFormRow(label: "API key") {
                    TZSecretField(
                        placeholder: provider == .custom
                            ? "Paste an API key (leave empty for local Ollama or LM Studio)"
                            : "Paste your \(provider.shortName) API key",
                        text: $draftAPIKey,
                        onSubmit: { save() }
                    )
                    if provider != .custom {
                        TextField("Model ID", text: $draftModelName)
                            .tzField(height: 32)
                            .frame(width: 170)
                    }
                    Button("Save") { save() }
                        .buttonStyle(.tzSecondaryCompact)
                    Button(appState.isBenchmarkingLLM ? "Testing…" : "Test connection") {
                        Task {
                            await appState.runLLMProviderBenchmark(
                                provider: provider,
                                baseURL: draftBaseURL,
                                modelName: draftModelName,
                                apiKey: draftAPIKey
                            )
                        }
                    }
                    .buttonStyle(.tzSecondaryCompact)
                    .disabled(appState.isBenchmarkingLLM || appState.activatingLLMProvider != nil)
                    if !isActive {
                        Button(isActivatingThis ? "Verifying…" : "Verify & switch") {
                            Task {
                                _ = await appState.activateLLMProvider(
                                    provider,
                                    baseURL: draftBaseURL,
                                    modelName: draftModelName,
                                    apiKey: draftAPIKey
                                )
                            }
                        }
                        .buttonStyle(.tzPrimaryCompact)
                        .disabled(appState.activatingLLMProvider != nil)
                    }
                }

                if let err = activationError, !err.isEmpty {
                    TZInlineMessage(message: err)
                } else if !benchmarkSummary.isEmpty {
                    TZInlineMessage(message: benchmarkSummary)
                } else if !hasKey {
                    TZInlineMessage(
                        message: "No \(provider.shortName) API key yet. Add one, then choose Verify & switch to turn this model on.",
                        forceTone: .warning
                    )
                }
            }
        )
        .onAppear { syncDraftFromStore() }
        .onChange(of: isExpanded) { _, expanded in
            if expanded { syncDraftFromStore() }
        }
    }

    private func save() {
        appState.saveLLMProviderDraft(
            provider: provider,
            baseURL: draftBaseURL,
            modelName: draftModelName,
            apiKey: draftAPIKey
        )
    }
}
