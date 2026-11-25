import SwiftUI
import AppKit

/// First-run setup sheet: permissions, engines, shortcut + on-device speech model.
struct OnboardingWizardSheet: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 26)
                .padding(.top, 22)
                .padding(.bottom, 14)

            steps

            footer
                .padding(.horizontal, 26)
                .padding(.top, 14)
                .padding(.bottom, 20)
        }
        .frame(width: 680)
        .background(Color.white)
        .preferredColorScheme(.light)
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            NevertypeMarkView(size: 26)
                .frame(width: 44, height: 44)
                .background(Circle().fill(TZTheme.panel))
            VStack(alignment: .leading, spacing: 2) {
                Text("Welcome to \(AppBrand.name)")
                    .font(.system(size: 24, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(TZTheme.ink)
                Text("Three steps to set up dictation.")
                    .font(.system(size: 14))
                    .foregroundStyle(TZTheme.inkSecondary)
            }
            Spacer()
            TZBadge(text: "v\(appState.currentAppVersion)", tone: .neutral)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("Click into any text field, press your shortcut, talk, then press it again to insert the text.")
                .font(.system(size: 13))
                .foregroundStyle(TZTheme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Done, start using \(AppBrand.name)") {
                if !appState.volcSpeechKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    appState.saveVolcSpeechAPIKey()
                }
                if !appState.apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    appState.saveAPIKey()
                }
                appState.completeOnboarding()
            }
            .buttonStyle(.tzPrimary)
        }
    }

    // MARK: Steps

    private var steps: some View {
        VStack(alignment: .leading, spacing: 10) {
            permissionsStep
            enginesStep
            shortcutStep
        }
        .padding(.horizontal, 26)
    }

    private func stepCard<Content: View>(_ number: Int, title: String, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("\(number)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(TZTheme.ink))
                Text(title)
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(TZTheme.ink)
                    .lineLimit(1)
                Spacer()
                if let trailing { trailing }
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tzPanel(radius: 14)
    }

    // 1. Permissions

    private var permissionsStep: some View {
        stepCard(
            1,
            title: "Grant permissions",
            trailing: AnyView(
                HStack(spacing: 6) {
                    permissionBadge("Microphone", ok: appState.micAuthorized)
                    permissionBadge("Accessibility", ok: appState.accessibilityGranted)
                }
            )
        ) {
            HStack(spacing: 12) {
                Button("Open permission prompts") { appState.requestAllPermissions() }
                    .buttonStyle(.tzPrimaryCompact)
                Text("Allow the microphone in the macOS prompt, then switch \(AppBrand.name) on in System Settings, Privacy & Security, Accessibility.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(TZTheme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func permissionBadge(_ title: String, ok: Bool) -> some View {
        TZBadge(text: title, tone: ok ? .green : .amber, icon: ok ? "checkmark" : "exclamationmark.triangle.fill")
    }

    // 2. Engines

    private var asrReady: Bool {
        (appState.llmConfig.asrProvider == .volcSeedASR && appState.hasOwnVolcSpeechKey)
            || (appState.llmConfig.asrProvider == .openAIWhisper && appState.hasEffectiveOpenAIASRKey)
            || (appState.llmConfig.asrProvider == .localSenseVoice && appState.senseVoiceLoaded)
    }

    private var enginesStep: some View {
        stepCard(2, title: "Choose your engines") {
            VStack(alignment: .leading, spacing: 10) {
                TZFormRow(label: "Speech", labelWidth: 64) {
                    TZMenuField(
                        options: [
                            (value: ASRProviderOption.localSenseVoice, title: "On-device"),
                            (value: ASRProviderOption.openAIWhisper, title: "OpenAI / Groq (cloud)"),
                            (value: ASRProviderOption.volcSeedASR, title: "Doubao Seed-ASR (cloud)")
                        ],
                        selection: Binding(
                            get: { appState.llmConfig.asrProvider },
                            set: { appState.selectASRProvider($0) }
                        )
                    )
                    .frame(width: 260)
                    speechDetail
                }

                TZFormRow(label: "Cleanup", labelWidth: 64) {
                    TZMenuField(
                        options: ([LLMProviderOption.custom] + LLMProviderOption.allCases.filter { $0 != .custom })
                            .map { (value: $0, title: $0 == .custom ? "Local Ollama / custom endpoint" : $0.shortName) },
                        selection: Binding(
                            get: { appState.llmConfig.selectedProvider },
                            set: { appState.selectLLMProvider($0) }
                        )
                    )
                    .frame(width: 260)
                    cleanupDetail
                }
            }
        }
    }

    @ViewBuilder
    private var speechDetail: some View {
        switch appState.llmConfig.asrProvider {
        case .volcSeedASR:
            TZSecretField(placeholder: "Doubao speech API key", text: $appState.volcSpeechKeyInput, onSubmit: { appState.saveVolcSpeechAPIKey() })
            Button("Save") { appState.saveVolcSpeechAPIKey() }
                .buttonStyle(.tzPrimaryCompact)
        case .openAIWhisper:
            TZSecretField(
                placeholder: appState.isOpenAIASRReusingLLMKey ? "Using your OpenAI cleanup key" : "OpenAI or Groq API key",
                text: $appState.openAIASRKeyInput,
                onSubmit: { appState.saveOpenAIASRConfig() }
            )
            Button("Save") { appState.saveOpenAIASRConfig() }
                .buttonStyle(.tzPrimaryCompact)
        case .localSenseVoice:
            HStack(spacing: 6) {
                TZStatusDot(tone: asrReady ? .green : .amber)
                Text(asrReady ? "Model ready" : "Download the model in step 3")
                    .font(.system(size: 13))
                    .foregroundStyle(TZTheme.inkSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var cleanupDetail: some View {
        if appState.llmConfig.selectedProvider == .custom {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    TZStatusDot(tone: .green)
                    Text(appState.llmConfig.modelName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(TZTheme.inkBody)
                        .lineLimit(1)
                }
                Text(hostLabel(appState.llmConfig.baseURL))
                    .font(.system(size: 12))
                    .foregroundStyle(TZTheme.inkMuted)
                    .lineLimit(1)
                    .padding(.leading, 13)
            }
            Spacer(minLength: 0)
        } else {
            TZSecretField(
                placeholder: "\(appState.llmConfig.selectedProvider.shortName) API key",
                text: $appState.apiKeyInput,
                onSubmit: { appState.saveAPIKey() }
            )
            Button("Save") { appState.saveAPIKey() }
                .buttonStyle(.tzPrimaryCompact)
        }
    }

    private func hostLabel(_ baseURL: String) -> String {
        guard let url = URL(string: baseURL), let host = url.host else { return baseURL }
        if let port = url.port { return "\(host):\(port)" }
        return host
    }

    // 3. Shortcut and local model

    private var shortcutStep: some View {
        stepCard(
            3,
            title: "Pick a shortcut and get the speech model",
            trailing: appState.activeLocalModel != nil
                ? AnyView(TZBadge(text: "Speech model ready", tone: .green, icon: "checkmark"))
                : nil
        ) {
            TZHotkeyPresetGrid(appState: appState)

            if appState.isDownloadingOfflineModel {
                HStack(spacing: 10) {
                    TZProgressBar(value: appState.offlineDownloadProgress)
                    Text(appState.offlineDownloadStatusText)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(TZTheme.blue)
                        .lineLimit(1)
                        .frame(maxWidth: 220, alignment: .leading)
                }
            } else if !appState.installedLocalModels.contains(appState.llmConfig.localASRModel) {
                let pending = appState.llmConfig.localASRModel
                HStack(spacing: 10) {
                    Button("Download \(pending.shortName) · \(pending.approxDownloadMB) MB") {
                        appState.startLocalModelDownload(pending)
                    }
                    .buttonStyle(.tzSecondaryCompact)
                    Text("Needed for offline dictation, and used as the fallback if a cloud engine drops.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(TZTheme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
