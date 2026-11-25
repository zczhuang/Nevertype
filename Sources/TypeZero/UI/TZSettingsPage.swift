import SwiftUI
import AppKit

struct TZSettingsPage: View {
    @ObservedObject var appState: AppState
    let snapshot: TZSnapshotOptions?

    @State private var expandedASR: ASRProviderOption?
    @State private var expandedLLM: LLMProviderOption?

    init(appState: AppState, snapshot: TZSnapshotOptions?) {
        self.appState = appState
        self.snapshot = snapshot
        _expandedASR = State(initialValue: snapshot == nil ? .localSenseVoice : snapshot?.expandedASR)
        _expandedLLM = State(initialValue: snapshot?.expandedLLM)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TZPageTitle(text: "Settings")

            VStack(alignment: .leading, spacing: 34) {
                speechSection
                cleanupSection
                shortcutsSection
                outputSection
                typelessImportSection
                permissionsSection
                aboutSection
            }
            .padding(.top, 26)
        }
        .onDisappear {
            if appState.isRecordingShortcut { appState.cancelShortcutCapture() }
        }
    }

    // MARK: Layout helpers

    private func section<Content: View>(_ title: String, detail: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TZSectionHeader(title: title, detail: detail)
            content()
        }
    }

    private func toggleRow(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        TZSettingRow(title: title, detail: detail) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(TZSwitchStyle())
        }
    }

    private func toggleExpanded(_ provider: ASRProviderOption) {
        expandedASR = (expandedASR == provider) ? nil : provider
    }

    // MARK: Speech recognition

    private var speechSection: some View {
        section("Speech recognition", detail: "Turns your voice into text. One engine is active at a time.") {
            VStack(alignment: .leading, spacing: 0) {
                TZSettingRow(
                    title: "Recognition language",
                    detail: "Used by SenseVoice and the cloud engines. Parakeet is English only."
                ) {
                    TZSegmentedControl(
                        items: [
                            .init(value: "auto", title: "Auto-detect"),
                            .init(value: "zh-CN", title: "Chinese"),
                            .init(value: "en-US", title: "English")
                        ],
                        selection: Binding(
                            get: { appState.llmConfig.speechLocale },
                            set: { appState.setSpeechLocale($0) }
                        ),
                        fontSize: 13.5
                    )
                }

                TZRowDivider()

                VStack(spacing: 10) {
                    TZLocalASRCard(appState: appState, isExpanded: expandedASR == .localSenseVoice) {
                        toggleExpanded(.localSenseVoice)
                    }
                    TZOpenAIASRCard(appState: appState, isExpanded: expandedASR == .openAIWhisper) {
                        toggleExpanded(.openAIWhisper)
                    }
                    TZDoubaoASRCard(appState: appState, isExpanded: expandedASR == .volcSeedASR) {
                        toggleExpanded(.volcSeedASR)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tzPanel(radius: 14)
        }
    }

    // MARK: Cleanup model

    private var cleanupProviders: [LLMProviderOption] {
        // The local Ollama endpoint ("Custom") is the default, so it leads the list.
        [.custom] + LLMProviderOption.allCases.filter { $0 != .custom }
    }

    private var cleanupSection: some View {
        section("Cleanup model", detail: "The language model that tidies your transcript. One model is active at a time.") {
            VStack(alignment: .leading, spacing: 12) {
                if appState.llmConfig.formattingStyle == .verbatimLocal {
                    TZInlineMessage(
                        message: "Formatting style is set to Verbatim (see Output), so no cleanup model is called right now.",
                        forceTone: .info
                    )
                }
                VStack(spacing: 10) {
                    ForEach(cleanupProviders) { provider in
                        LLMProviderUnifiedCard(
                            appState: appState,
                            provider: provider,
                            isExpanded: expandedLLM == provider,
                            onToggleExpand: {
                                expandedLLM = (expandedLLM == provider) ? nil : provider
                            }
                        )
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tzPanel(radius: 14)
        }
    }

    // MARK: Shortcuts

    private var shortcutsSection: some View {
        section("Shortcuts", detail: "Pick the key that starts and stops dictation.") {
            VStack(alignment: .leading, spacing: 0) {
                TZSettingRow(title: "Dictation shortcut", detail: "Press it in any app to dictate. Press Esc while recording to cancel.") {
                    HStack(spacing: 10) {
                        TZFlowLayout(spacing: 6, lineSpacing: 6) {
                            ForEach(Array(appState.tzShortcutKeycaps.enumerated()), id: \.offset) { _, key in
                                TZKeycap(text: key)
                            }
                        }
                        .fixedSize()
                    }
                }

                TZRowDivider()

                TZHotkeyPresetGrid(appState: appState)

                HStack(spacing: 10) {
                    if appState.isRecordingShortcut {
                        TZBadge(text: "Press a modifier key or a key combination · Esc to cancel", tone: .blue, icon: "record.circle")
                        Button("Cancel") { appState.cancelShortcutCapture() }
                            .buttonStyle(.tzSecondaryCompact)
                    } else {
                        Button {
                            appState.startShortcutCapture()
                        } label: {
                            Label(
                                appState.triggerKey == .custom ? "Re-record custom shortcut (\(appState.customHotkey.label))" : "Record a custom shortcut…",
                                systemImage: "keyboard"
                            )
                        }
                        .buttonStyle(.tzSecondaryCompact)
                    }
                    Spacer()
                }
                .padding(.top, 12)

                TZRowDivider()

                TZSettingRow(title: "Trigger style", detail: appState.triggerBehavior.tzDetail) {
                    TZSegmentedControl(
                        items: [
                            .init(value: TriggerBehavior.tapToggle, title: "Tap"),
                            .init(value: TriggerBehavior.holdToTalk, title: "Hold to talk")
                        ],
                        selection: Binding(
                            get: { appState.triggerBehavior },
                            set: { appState.triggerBehavior = $0 }
                        ),
                        fontSize: 13.5
                    )
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tzPanel(radius: 14)
        }
    }

    // MARK: Output

    private var outputSection: some View {
        section("Output", detail: "How the result is cleaned up and delivered.") {
            VStack(alignment: .leading, spacing: 0) {
                TZSettingRow(title: "Formatting style", detail: appState.llmConfig.formattingStyle.tzDetail) {
                    TZSegmentedControl(
                        items: FormattingStyle.allCases.map { .init(value: $0, title: $0.tzLabel) },
                        selection: Binding(
                            get: { appState.llmConfig.formattingStyle },
                            set: { appState.llmConfig.formattingStyle = $0 }
                        ),
                        fontSize: 13.5
                    )
                }

                TZRowDivider()

                TZSettingRow(
                    title: "Typing mode",
                    detail: appState.llmConfig.enableLiveInlineTyping
                        ? "Words appear in the text field as you speak."
                        : "The result is pasted in one go when you finish."
                ) {
                    TZSegmentedControl(
                        items: [
                            .init(value: true, title: "Live typing"),
                            .init(value: false, title: "Paste on finish")
                        ],
                        selection: Binding(
                            get: { appState.llmConfig.enableLiveInlineTyping },
                            set: { appState.llmConfig.enableLiveInlineTyping = $0 }
                        ),
                        fontSize: 13.5
                    )
                }

                TZRowDivider()
                toggleRow(
                    "Mute speakers while dictating",
                    detail: "System audio is muted while you speak and restored when you finish.",
                    isOn: $appState.llmConfig.enableAutoMuteDuringDictation
                )
                TZRowDivider()
                toggleRow(
                    "Sound effects",
                    detail: "A soft sound when recording starts and when it stops, even while speakers are muted.",
                    isOn: $appState.llmConfig.enableSoundEffects
                )
                TZRowDivider()
                toggleRow(
                    "Skip cleanup for short, clean phrases",
                    detail: "Phrases under about 28 characters that already read well are inserted instantly.",
                    isOn: $appState.llmConfig.enableFastBypassForShortPhrases
                )
                TZRowDivider()
                toggleRow(
                    "Boost whispered speech",
                    detail: "Applies up to 25 dB of automatic gain to very quiet speech.",
                    isOn: $appState.llmConfig.enableWhisperAGC
                )
                TZRowDivider()
                toggleRow(
                    "Space between Chinese and English",
                    detail: "Adds a space between Chinese characters and Latin words or numbers. No effect on English-only text.",
                    isOn: $appState.llmConfig.enablePanguSpacing
                )
                TZRowDivider()
                toggleRow(
                    "Learn from my corrections",
                    detail: "When you fix a word by hand right after dictating, \(AppBrand.name) adds it to your dictionary.",
                    isOn: $appState.llmConfig.enableAutoLearn
                )
                TZRowDivider()
                toggleRow(
                    "Drop the final period in chat and terminal apps",
                    detail: "Short messages read more naturally without a trailing full stop.",
                    isOn: $appState.llmConfig.stripTrailingPeriodInChatApps
                )
                TZRowDivider()
                toggleRow(
                    "Show icon in the Dock",
                    detail: "When off, \(AppBrand.name) lives only in the menu bar.",
                    isOn: $appState.llmConfig.showInDock
                )
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tzPanel(radius: 14)
        }
    }

    // MARK: Import

    /// Only offered when Typeless's database exists on this Mac (a file-system check; the file is not opened). The switch is
    /// off until the user turns it on, and turning it on imports once right away. See `TypelessSyncCoordinator`.
    @ViewBuilder
    private var typelessImportSection: some View {
        if TypelessPaths.databaseExists {
            section("Import", detail: "Bring dictations from another app into History.") {
                VStack(alignment: .leading, spacing: 0) {
                    toggleRow(
                        "Import history from Typeless",
                        detail: appState.llmConfig.enableTypelessImport
                            ? "Copies your past Typeless dictations into History, once each, when \(AppBrand.name) starts and when you open History. Typeless's data is only read, never changed. Use “Sync from Typeless” in the History menu to sync by hand."
                            : "Off. \(AppBrand.name) does not open Typeless's data until you turn this on. Turning it on imports your past dictations right away.",
                        isOn: Binding(
                            get: { appState.llmConfig.enableTypelessImport },
                            set: { enabled in
                                TypelessSyncCoordinator.shared.setImportEnabled(enabled, on: appState)
                            }
                        )
                    )
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .tzPanel(radius: 14)
            }
        }
    }

    // MARK: Permissions

    private func permissionBadge(_ ok: Bool) -> some View {
        TZBadge(
            text: ok ? "Granted" : "Not granted",
            tone: ok ? .green : .amber,
            icon: ok ? "checkmark" : "exclamationmark.triangle.fill"
        )
    }

    private var permissionsSection: some View {
        section("Permissions", detail: "macOS asks for these so \(AppBrand.name) can hear you and type for you.") {
            VStack(alignment: .leading, spacing: 0) {
                TZSettingRow(title: "Microphone", detail: "Needed to hear you.") {
                    permissionBadge(appState.micAuthorized)
                }
                TZRowDivider()
                TZSettingRow(
                    title: "Accessibility",
                    detail: appState.accessibilityGranted
                        ? "Lets \(AppBrand.name) type into other apps."
                        : "Required to type into other apps. Turn \(AppBrand.name) on in System Settings, Privacy & Security, Accessibility."
                ) {
                    permissionBadge(appState.accessibilityGranted)
                }
                TZRowDivider()
                HStack(spacing: 8) {
                    Button("Request permissions") { appState.requestAllPermissions() }
                        .buttonStyle(.tzSecondaryCompact)
                    Button("Reset Accessibility cache") { appState.resetStaleTCCAndOpenSettings() }
                        .buttonStyle(.tzSecondaryCompact)
                    Spacer()
                    Button("Show setup guide") { appState.showOnboardingSheet = true }
                        .buttonStyle(.tzSecondaryCompact)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tzPanel(radius: 14)
        }
    }

    // MARK: About

    private var aboutSection: some View {
        section("About") {
            VStack(alignment: .leading, spacing: 0) {
                TZSettingRow(title: AppBrand.name, detail: "Version \(appState.currentAppVersion)") {
                    TZBadge(text: "Local-first", tone: .blue)
                }
                TZRowDivider()
                TZSettingRow(
                    title: "Updates",
                    detail: "Automatic updates are off. New versions are published on the project's GitHub page."
                ) {
                    Button("Open releases") { NSWorkspace.shared.open(AppBrand.releasesURL) }
                        .buttonStyle(.tzSecondaryCompact)
                }
                TZRowDivider()
                TZSettingRow(title: "Source code", detail: AppBrand.repositoryDisplayString) {
                    Button("Open on GitHub") { NSWorkspace.shared.open(AppBrand.repositoryURL) }
                        .buttonStyle(.tzSecondaryCompact)
                }
                TZRowDivider()
                TZSettingRow(
                    title: AppBrand.upstreamAttribution,
                    detail: "\(AppBrand.name) is built on the open-source \(AppBrand.upstreamName) project (MIT License)."
                ) {
                    Button("Open \(AppBrand.upstreamName) on GitHub") { NSWorkspace.shared.open(AppBrand.upstreamRepositoryURL) }
                        .buttonStyle(.tzSecondaryCompact)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tzPanel(radius: 14)
        }
    }
}
