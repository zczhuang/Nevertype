import Foundation
import SwiftUI
import AppKit

@MainActor
public final class AppState: ObservableObject {
    @Published public var phase: PipelinePhase = .idle {
        didSet {
            pillController.setVisible(phase != .idle)
            // Only the Copy pill takes clicks; in every other state the pill lets them through to the app underneath.
            if case .readyToCopy = phase {
                pillController.setInteractive(true)
            } else {
                pillController.setInteractive(false)
            }
        }
    }
    @Published public var audioLevel: Float = 0.08
    @Published public var history: [DictationRecord] = []
    @Published public var llmConfig: LLMConfig = .default {
        didSet {
            syncASREngineConfig()
            if oldValue.asrProvider != llmConfig.asrProvider
                || oldValue.openAIASRBaseURL != llmConfig.openAIASRBaseURL {
                lastOpenAIASRProbeSummary = ""
                asrEngine.prewarmCloudSocketIfReady()
            }
            if oldValue.speechLocale != llmConfig.speechLocale || oldValue.localASRModel != llmConfig.localASRModel {
                asrEngine.reloadSenseVoiceModelAsync()
            }
            if oldValue.selectedProvider != llmConfig.selectedProvider {
                apiKeyInput = KeychainHelper.loadAPIKey(for: llmConfig.selectedProvider)
                lastBenchmarkSummary = ""
                polishEngine.prewarmConnection(baseURL: llmConfig.baseURL, apiKey: apiKeyInput, model: llmConfig.modelName)
            }
            if oldValue.showInDock != llmConfig.showInDock {
                applyDockVisibilityPolicy()
            }
            saveConfig()
        }
    }
    @Published public var selectedTab: SidebarTab = .home
    @Published public var triggerKey: TriggerKeyOption = .fnKey {
        didSet {
            hotkeyMonitor.triggerOption = triggerKey
            UserDefaults.standard.set(triggerKey.rawValue, forKey: "tz_trigger_key")
        }
    }
    @Published public var customHotkey: CustomHotkeySpec = .default {
        didSet {
            hotkeyMonitor.customSpec = customHotkey
            if let encoded = try? JSONEncoder().encode(customHotkey) {
                UserDefaults.standard.set(encoded, forKey: "tz_custom_hotkey_spec")
            }
        }
    }
    @Published public var isRecordingShortcut: Bool = false
    @Published public var triggerBehavior: TriggerBehavior = .tapToggle {
        didSet {
            hotkeyMonitor.behavior = triggerBehavior
            UserDefaults.standard.set(triggerBehavior.rawValue, forKey: "tz_trigger_behavior")
        }
    }
    @Published public var apiKeyInput: String = ""
    @Published public var volcSpeechKeyInput: String = ""
    @Published public var openAIASRKeyInput: String = ""
    @Published public var savedProviderKeyFlags: [LLMProviderOption: Bool] = [:]
    @Published public var micAuthorized: Bool = false
    @Published public var speechAuthorized: Bool = false
    @Published public var accessibilityGranted: Bool = false
    /// True when ANY local model (Parakeet or SenseVoice) is loaded — legacy name kept to avoid churn in the UI layer.
    @Published public var senseVoiceLoaded: Bool = false
    /// True only when the lossless SenseVoice FP32 weights are the loaded model.
    @Published public var senseVoiceFullFP32: Bool = false
    /// The local model currently loaded in the engine (can differ from `llmConfig.localASRModel` when the selected one is not installed).
    @Published public var activeLocalModel: LocalASRModel? = nil
    /// Local models whose files are fully present on disk.
    @Published public var installedLocalModels: Set<LocalASRModel> = []
    /// The model currently being downloaded, if any.
    @Published public var downloadingLocalModel: LocalASRModel? = nil
    @Published public var statusBanner: String = ""
    @Published public var sandboxText: String = ""
    @Published public var isBenchmarkingLLM: Bool = false
    @Published public var lastBenchmarkSummary: String = ""
    @Published public var isProbingSeedASR: Bool = false
    @Published public var lastSeedASRProbeSummary: String = ""
    @Published public var isProbingOpenAIASR: Bool = false
    @Published public var lastOpenAIASRProbeSummary: String = ""
    @Published public var activatingASRProvider: ASRProviderOption? = nil
    @Published public var asrActivationErrors: [ASRProviderOption: String] = [:]
    @Published public var activatingLLMProvider: LLMProviderOption? = nil
    @Published public var llmActivationErrors: [LLMProviderOption: String] = [:]
    @Published public var llmProviderBenchmarkSummaries: [LLMProviderOption: String] = [:]
    @Published public var showOnboardingSheet: Bool = false
    @Published public var isDownloadingOfflineModel: Bool = false
    @Published public var offlineDownloadProgress: Double = 0.0
    @Published public var offlineDownloadStatusText: String = ""

    private var idleResetTask: Task<Void, Never>? = nil
    /// Clock behind the Copy pill's 8 s (paused while the pointer is over the pill).
    private var copyCountdown = CopyPillCountdown()
    private var pendingAutoMuteTask: Task<Void, Never>? = nil

    /// True when the user has typed or saved their own Doubao speech API key.
    public var hasOwnVolcSpeechKey: Bool {
        !volcSpeechKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Updates are off (see `AppUpdater`); only the version is shown.
    public var currentAppVersion: String {
        AppUpdater.currentAppVersion
    }

    public let lexiconStore = PersonalLexiconStore()
    private let asrEngine = StreamingASREngine()
    private let polishEngine = PolishEngine()
    private let hotkeyMonitor = HotkeyMonitor()
    private let pillController = FloatingPillController()
    private let modelDownloader = OfflineModelDownloader()
    private let audioDucker = SystemAudioDucker()

    private var activeContext: ActiveScreenContext = .empty
    private var activeMode: DictationMode = .dictate
    private var isSessionActive: Bool = false
    private var isFinalizingSession: Bool = false
    private var userSubmittedViaEnter: Bool = false
    private var liveInputSession: LiveInputSession? = nil
    private var sandboxBaseBeforeSession: String = ""
    private var isTypingInsideOwnApp: Bool = false
    private var permissionPollTimer: Timer? = nil
    private var workspaceActivateObserver: NSObjectProtocol? = nil

    private let historyURL: URL
    private let configURL: URL

    public init() {
        let dir = AppBrand.applicationSupportDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.historyURL = dir.appendingPathComponent("history.json")
        self.configURL = dir.appendingPathComponent("config.json")

        loadConfig()
        loadHistory()
        self.apiKeyInput = KeychainHelper.loadAPIKey(for: llmConfig.selectedProvider)
        self.volcSpeechKeyInput = KeychainHelper.loadVolcSpeechAPIKey()
        self.openAIASRKeyInput = KeychainHelper.loadOpenAIASROverrideKey()
        refreshSavedKeyFlags()
        syncASREngineConfig()
        refreshPermissionStatus()

        if let savedSpecData = UserDefaults.standard.data(forKey: "tz_custom_hotkey_spec"),
           let spec = try? JSONDecoder().decode(CustomHotkeySpec.self, from: savedSpecData) {
            self.customHotkey = spec
        }
        if let savedTrigger = UserDefaults.standard.string(forKey: "tz_trigger_key"),
           let opt = TriggerKeyOption(rawValue: savedTrigger) {
            self.triggerKey = opt
        }
        if let savedBehavior = UserDefaults.standard.string(forKey: "tz_trigger_behavior"),
           let beh = TriggerBehavior(rawValue: savedBehavior) {
            self.triggerBehavior = beh
        }

        setupCallbacks()
        hotkeyMonitor.customSpec = customHotkey
        hotkeyMonitor.triggerOption = triggerKey
        hotkeyMonitor.behavior = triggerBehavior

        // Defer NSPanel / NSHostingView attachment & permission prompts to next main RunLoop tick
        // so SwiftUI's root AttributeGraph finishes initializing @StateObject without re-entrant layout crash!
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyDockVisibilityPolicy()
            self.pillController.attach(appState: self)
            Self.preloadCueSounds()
            self.asrEngine.warmUp(localeIdentifier: self.llmConfig.speechLocale)
            self.polishEngine.prewarmConnection(baseURL: self.llmConfig.baseURL, model: self.llmConfig.modelName)
            self.hotkeyMonitor.start()
            self.startPermissionWatcher()
            self.workspaceActivateObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.isSessionActive else { return }
                    self.asrEngine.prewarmCloudSocketIfReady()
                }
            }
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.audioDucker.restoreIfNeeded()
            }

            if !self.micAuthorized || !self.speechAuthorized {
                StreamingASREngine.requestPermissions { [weak self] mic, speech in
                    self?.micAuthorized = mic
                    self?.speechAuthorized = speech
                    if mic && speech {
                        self?.asrEngine.warmUp(localeIdentifier: self?.llmConfig.speechLocale ?? "auto")
                    }
                }
            }

            // First-run colleague onboarding check:
            // Auto-complete silently on already-configured machines; open 3-step setup guide on a brand-new colleague's Mac!
            if !UserDefaults.standard.bool(forKey: "tz_onboarding_done_v1") {
                let hasAnyASRReady = self.hasOwnVolcSpeechKey
                    || self.hasEffectiveOpenAIASRKey
                    || LocalASRModel.anyInstalled()
                if self.micAuthorized && self.accessibilityGranted && hasAnyASRReady {
                    UserDefaults.standard.set(true, forKey: "tz_onboarding_done_v1")
                } else {
                    self.showOnboardingSheet = true
                }
            }
        }
    }

    /// There is no updater: nothing is downloaded or installed and no request is made. A manual check only says where new
    /// versions are published (see `AppUpdater.manualCheckMessage`).
    public func checkForUpdates(manual: Bool) async {
        guard manual else { return }
        statusBanner = AppUpdater.manualCheckMessage
    }

    private func startPermissionWatcher() {
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 2.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isSessionActive else { return }
                if !self.micAuthorized || !self.speechAuthorized || !self.accessibilityGranted || !self.senseVoiceLoaded || self.showOnboardingSheet {
                    self.refreshPermissionStatus()
                }
            }
        }
    }

    private func setupCallbacks() {
        asrEngine.onModelReady = { [weak self] in
            self?.refreshPermissionStatus()
        }
        modelDownloader.onProgress = { [weak self] frac, status in
            guard let self else { return }
            self.offlineDownloadProgress = frac
            self.offlineDownloadStatusText = status
        }
        modelDownloader.onCompletion = { [weak self] success, msg in
            guard let self else { return }
            self.isDownloadingOfflineModel = false
            self.downloadingLocalModel = nil
            self.offlineDownloadStatusText = msg
            self.statusBanner = msg
            self.refreshInstalledLocalModels()
            if success {
                self.asrEngine.reloadSenseVoiceModelAsync()
            }
        }
        asrEngine.onCloudFailoverNotice = { [weak self] reason in
            guard let self else { return }
            self.statusBanner = "✈️ Using the on-device model instead: \(reason)"
        }
        asrEngine.onError = { [weak self] errMsg in
            guard let self else { return }
            self.isSessionActive = false
            self.restoreSystemAudio()
            self.hotkeyMonitor.syncRecordingState(false)
            self.showDictationFailure(.engineError(errMsg))
        }
        asrEngine.onPartialResult = { [weak self] partial, flushTail in
            guard let self, self.isSessionActive else { return }
            let instantFixed = PolishEngine.applyInstantLocalDictionary(
                partial,
                entries: self.lexiconStore.entries,
                context: self.activeContext,
                config: self.llmConfig,
                stripPeriod: false
            )

            // Drive the zero-state-diff micro-symbol rhythm ribbon above the capsule wave!
            let spokenCount = instantFixed.filter { !$0.isWhitespace }.count
            AudioLevelBus.shared.pushRecognizedCount(spokenCount)

            // NOTE: Intentionally do NOT mutate `self.phase` here — avoids triggering full-app SwiftUI view hierarchy diffs on every syllable!
            if self.llmConfig.enableLiveInlineTyping && self.activeMode == .dictate {
                if self.isTypingInsideOwnApp {
                    self.sandboxText = self.sandboxBaseBeforeSession + instantFixed
                } else {
                    _ = self.liveInputSession?.updateLiveText(
                        instantFixed,
                        flushTrailingChar: flushTail,
                        isCloudStream: self.asrEngine.activeSessionUsesCloudSeedASR
                    )
                }
            }
        }
        hotkeyMonitor.onPrewarmMic = { [weak self] in
            self?.asrEngine.prewarmHotMicAsync()
        }
        hotkeyMonitor.onTriggerStart = { [weak self] in
            self?.beginDictationSession()
        }
        hotkeyMonitor.onTriggerStop = { [weak self] in
            Task { @MainActor in
                await self?.finishDictationSession()
            }
        }
        hotkeyMonitor.onCancel = { [weak self] in
            self?.cancelDictationSession()
        }
        hotkeyMonitor.onUserSubmitKeyPressed = { [weak self] in
            self?.handleUserPressedSubmitEnter()
        }
    }

    /// Invoked when the user physically hits bare `Return` / `Enter` / `Cmd+Return` to send their message directly:
    /// - If live inline text is already in the box while still recording: cleanly stops dictation WITHOUT re-pasting!
    /// - If we're currently inside the 200-400ms DeepSeek polish window: immediately aborts post-polish pasting so no ghost text remains!
    private func handleUserPressedSubmitEnter() {
        guard !isTypingInsideOwnApp else { return }
        if isFinalizingSession {
            userSubmittedViaEnter = true
            liveInputSession?.abortBecauseUserSubmitted()
            return
        }
        guard isSessionActive,
              llmConfig.enableLiveInlineTyping,
              activeMode == .dictate,
              let emitted = liveInputSession?.currentText,
              !emitted.isEmpty else {
            return
        }
        userSubmittedViaEnter = true
        isSessionActive = false
        restoreSystemAudio()
        hotkeyMonitor.syncRecordingState(false)
        asrEngine.cancel()
        AudioLevelBus.shared.reset()
        liveInputSession?.abortBecauseUserSubmitted()
        liveInputSession = nil
        phase = .idle
        ContextInjector.appendInjectionTrace("submitEnter app=\(activeContext.bundleID) stoppedLiveSession emitted=\(emitted.count)")
    }

    // MARK: Sound cues

    private enum CueKind { case start, stop }

    /// Loads the built-in cue sounds once at launch so the first key press does not wait for them to be read from disk.
    private static func preloadCueSounds() {
        for cue in [SessionCues.start, SessionCues.stop] {
            _ = NSSound(named: NSSound.Name(cue.soundName))
        }
    }

    /// Plays the start (Tink) or stop (Pop) cue, unless "Sound effects" is off.
    private func playSessionCue(_ kind: CueKind) {
        let cue = (kind == .start) ? SessionCues.start : SessionCues.stop
        playSubtleCue(cue.soundName, volume: cue.volume)
    }

    /// A new cue first stops every cue that is still playing. This also restarts a sound whose previous play is still ringing
    /// out (the files carry a silent tail), which would otherwise make a quick second start or stop silent.
    private func stopAllCues() {
        for name in SessionCues.allSoundNames {
            if let sound = NSSound(named: NSSound.Name(name)), sound.isPlaying {
                sound.stop()
            }
        }
    }

    /// Plays a built-in sound unless "Sound effects" is off.
    private func playSubtleCue(_ soundName: String, volume: Float = 0.30) {
        guard llmConfig.enableSoundEffects,
              let sound = NSSound(named: NSSound.Name(soundName)) else { return }
        stopAllCues()
        sound.volume = volume
        sound.play()
    }

    /// How long auto-mute has to wait after the start cue begins (0 when there is no cue): muting the output device would
    /// silence the cue, so it waits for its audible part.
    private func startCueMuteDelay() -> TimeInterval {
        SessionCues.muteDelayAfterStartCue(soundEffectsEnabled: llmConfig.enableSoundEffects)
    }

    /// Mutes system output for the session `delay` seconds from now (at once when `delay` is 0). A mute that has not happened
    /// yet is dropped as soon as the session ends, so a quick start/stop can never leave the Mac muted.
    private func scheduleAutoMute(after delay: TimeInterval) {
        pendingAutoMuteTask?.cancel()
        pendingAutoMuteTask = nil
        guard delay > 0 else {
            audioDucker.muteIfNeeded()
            return
        }
        pendingAutoMuteTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.isSessionActive else { return }
            self.audioDucker.muteIfNeeded()
        }
    }

    /// Gives system output back (and cancels a mute that has not happened yet). Do this before playing a cue that must be heard.
    private func restoreSystemAudio() {
        pendingAutoMuteTask?.cancel()
        pendingAutoMuteTask = nil
        audioDucker.restoreIfNeeded()
    }

    public func cancelDictationSession() {
        guard isSessionActive else { return }
        isSessionActive = false
        restoreSystemAudio()
        hotkeyMonitor.syncRecordingState(false)
        asrEngine.cancel()
        AudioLevelBus.shared.reset()
        if isTypingInsideOwnApp {
            sandboxText = sandboxBaseBeforeSession
        } else if let emitted = liveInputSession?.currentText, !emitted.isEmpty {
            ContextInjector.sendCleanBackspaces(count: emitted.count)
        }
        liveInputSession = nil
        phase = .idle
        playSubtleCue(SessionCues.cancel.soundName, volume: SessionCues.cancel.volume)
    }

    public func requestAllPermissions() {
        StreamingASREngine.requestPermissions { [weak self] mic, speech in
            self?.micAuthorized = mic
            self?.speechAuthorized = speech
            if mic && speech {
                self?.asrEngine.warmUp(localeIdentifier: self?.llmConfig.speechLocale ?? "auto")
            }
        }
        self.accessibilityGranted = ContextInjector.isAccessibilityTrusted(promptIfNeeded: true)
    }

    public func refreshPermissionStatus() {
        self.micAuthorized = StreamingASREngine.isMicrophoneAuthorized
        self.speechAuthorized = StreamingASREngine.isSpeechAuthorized
        self.accessibilityGranted = ContextInjector.isAccessibilityTrusted(promptIfNeeded: false)
        self.senseVoiceLoaded = asrEngine.isUsingSenseVoice
        self.senseVoiceFullFP32 = asrEngine.isFullPrecisionFP32
        self.activeLocalModel = asrEngine.activeLocalModel
        refreshInstalledLocalModels()
        clearResolvedPermissionBanner()
    }

    /// A "turn on this permission" banner left behind by a failed dictation is stale once that permission is granted.
    private func clearResolvedPermissionBanner() {
        let resolved = (accessibilityGranted && statusBanner == DictationFailure.accessibilityOff.bannerText)
            || (micAuthorized && statusBanner == DictationFailure.microphoneOff.bannerText)
            || (speechAuthorized && statusBanner == DictationFailure.speechRecognitionOff.bannerText)
        if resolved { statusBanner = "" }
    }

    public func refreshInstalledLocalModels() {
        let installed = Set(LocalASRModel.allCases.filter { $0.isInstalled() })
        if installed != installedLocalModels {
            installedLocalModels = installed
        }
    }

    /// Switches the on-device speech model (Parakeet TDT v2 ⇄ SenseVoice). The engine hot-reloads it; if the chosen
    /// model's files are missing the other installed model keeps running until the download finishes.
    public func selectLocalASRModel(_ model: LocalASRModel) {
        guard llmConfig.localASRModel != model else { return }
        llmConfig.localASRModel = model
        refreshInstalledLocalModels()
        if model.isInstalled() {
            statusBanner = "Local speech model set to \(model.displayName)."
        } else {
            statusBanner = "\(model.displayName) is not installed yet — download it below. Until then the other installed model (if any) is used."
        }
    }

    public func resetStaleTCCAndOpenSettings() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "Accessibility", AppBrand.bundleID]
        try? task.run()
        task.waitUntilExit()
        self.accessibilityGranted = false
        _ = ContextInjector.isAccessibilityTrusted(promptIfNeeded: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    public var activeTriggerDisplayName: String {
        triggerKey == .custom ? "Custom shortcut (\(customHotkey.label))" : triggerKey.displayName
    }

    public var activeTriggerCompactLabel: String {
        triggerKey == .custom ? customHotkey.label : triggerKey.compactSidebarLabel
    }

    public func startShortcutCapture() {
        isRecordingShortcut = true
        hotkeyMonitor.beginInteractiveCapture { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isRecordingShortcut = false
                switch result {
                case .preset(let opt):
                    self.triggerKey = opt
                    self.statusBanner = "✅ Trigger key set to \(opt.displayName)"
                case .custom(let spec):
                    self.customHotkey = spec
                    self.triggerKey = .custom
                    self.statusBanner = "✅ Custom shortcut active: \(spec.label)"
                case .cancelled:
                    break
                }
            }
        }
    }

    public func cancelShortcutCapture() {
        hotkeyMonitor.cancelInteractiveCapture()
        isRecordingShortcut = false
    }

    public func refreshSavedKeyFlags() {
        var flags: [LLMProviderOption: Bool] = [:]
        for p in LLMProviderOption.allCases {
            flags[p] = KeychainHelper.hasSavedAPIKey(for: p)
        }
        savedProviderKeyFlags = flags
    }

    public func selectLLMProvider(_ provider: LLMProviderOption) {
        guard llmConfig.selectedProvider != provider else { return }
        llmConfig.selectProvider(provider)
        refreshSavedKeyFlags()
    }

    public var isGroqASRSelected: Bool {
        OpenAITranscriptionClient.isGroqEndpoint(llmConfig.openAIASRBaseURL)
    }

    public var isOpenAIASRReusingLLMKey: Bool {
        let overrideEmpty = openAIASRKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && KeychainHelper.loadOpenAIASROverrideKey().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard overrideEmpty, !isGroqASRSelected else { return false }
        return (savedProviderKeyFlags[.openai] ?? false)
            || (llmConfig.selectedProvider == .openai && !apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    public var effectiveOpenAIASRKey: String {
        let typedOverride = openAIASRKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typedOverride.isEmpty { return typedOverride }
        let saved = KeychainHelper.loadEffectiveOpenAIASRAPIKey(for: llmConfig.openAIASRBaseURL)
        if !saved.isEmpty { return saved }
        if !isGroqASRSelected && llmConfig.selectedProvider == .openai {
            return apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    public var hasEffectiveOpenAIASRKey: Bool {
        !effectiveOpenAIASRKey.isEmpty || PolishEngine.isKeylessLocalEndpoint(llmConfig.openAIASRBaseURL)
    }

    public func syncASREngineConfig() {
        asrEngine.enableWhisperAGC = llmConfig.enableWhisperAGC
        asrEngine.speechLocale = llmConfig.speechLocale
        asrEngine.asrProvider = llmConfig.asrProvider
        asrEngine.localASRModel = llmConfig.localASRModel
        asrEngine.volcSpeechAPIKey = KeychainHelper.loadVolcSpeechAPIKey()
        asrEngine.openAIASRBaseURL = llmConfig.openAIASRBaseURL
        asrEngine.openAIASRModel = llmConfig.openAIASRModel
        asrEngine.openAIASRAPIKey = effectiveOpenAIASRKey
    }

    public func setSpeechLocale(_ locale: String) {
        let normalized = locale.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = normalized.isEmpty ? "auto" : normalized
        var updated = llmConfig
        updated.speechLocale = target
        updated.speechLocaleExplicitlySet = true
        llmConfig = updated
    }

    public func selectASRProvider(_ provider: ASRProviderOption) {
        guard llmConfig.asrProvider != provider else { return }
        llmConfig.selectASRProvider(provider)
    }

    /// Strict activation flow for ASR engines: validates credentials / local model & live handshake FIRST.
    /// Only switches `llmConfig.asrProvider` (lighting up the single active badge) after verification succeeds.
    @discardableResult
    public func activateASRProvider(_ provider: ASRProviderOption) async -> Bool {
        guard activatingASRProvider == nil else { return false }
        activatingASRProvider = provider
        asrActivationErrors[provider] = nil
        defer { activatingASRProvider = nil }

        switch provider {
        case .volcSeedASR:
            let typedOwn = volcSpeechKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !typedOwn.isEmpty {
                KeychainHelper.saveVolcSpeechAPIKey(typedOwn)
                volcSpeechKeyInput = KeychainHelper.loadVolcSpeechAPIKey()
                syncASREngineConfig()
            }
            let key = KeychainHelper.loadVolcSpeechAPIKey()
            guard !key.isEmpty else {
                let err = "❌ Can't activate: enter your own Doubao speech API key first"
                asrActivationErrors[provider] = err
                statusBanner = err
                return false
            }
            do {
                let rttMs = try await VolcSeedASRClient.probeHandshakeLatency(apiKey: key)
                llmConfig.selectASRProvider(.volcSeedASR)
                syncASREngineConfig()
                speechAuthorized = StreamingASREngine.isSpeechAuthorized
                let hotCount = min(65, lexiconStore.entries.count)
                lastSeedASRProbeSummary = "⚡ Verified and active (volc.seedasr.sauc.duration): direct connection, first frame \(rttMs)ms · \(hotCount) hotwords loaded"
                statusBanner = "✅ Doubao streaming speech 2.0 verified and now the active engine"
                return true
            } catch {
                let err = "❌ Verification failed, not activated: \(error.localizedDescription)"
                asrActivationErrors[provider] = err
                statusBanner = err
                return false
            }

        case .openAIWhisper:
            llmConfig.openAIASRBaseURL = llmConfig.openAIASRBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if llmConfig.openAIASRBaseURL.isEmpty {
                llmConfig.openAIASRBaseURL = "https://api.openai.com/v1"
            }
            llmConfig.openAIASRModel = llmConfig.openAIASRModel.trimmingCharacters(in: .whitespacesAndNewlines)
            if llmConfig.openAIASRModel.isEmpty {
                llmConfig.openAIASRModel = isGroqASRSelected ? "whisper-large-v3-turbo" : "gpt-4o-mini-transcribe"
            }
            let typedOverride = openAIASRKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !typedOverride.isEmpty {
                KeychainHelper.saveOpenAIASRAPIKey(typedOverride)
                openAIASRKeyInput = KeychainHelper.loadOpenAIASROverrideKey()
            }
            syncASREngineConfig()
            let label = isGroqASRSelected ? "Groq Whisper" : "OpenAI speech model"
            guard hasEffectiveOpenAIASRKey else {
                let err = isGroqASRSelected
                    ? "❌ Can't activate: no Groq API key. Enter a valid key first (current settings are not active)."
                    : "❌ Can't activate: no OpenAI API key. Enter a valid key first (current settings are not active)."
                asrActivationErrors[provider] = err
                statusBanner = err
                return false
            }
            let effectiveKey = effectiveOpenAIASRKey
            do {
                let rttMs = try await OpenAITranscriptionClient.probeLatency(
                    baseURL: llmConfig.openAIASRBaseURL,
                    model: llmConfig.openAIASRModel,
                    apiKey: effectiveKey
                )
                llmConfig.selectASRProvider(.openAIWhisper)
                syncASREngineConfig()
                speechAuthorized = StreamingASREngine.isSpeechAuthorized
                let hotCount = min(40, lexiconStore.entries.count)
                let keyMode = isOpenAIASRReusingLLMKey ? "reusing your OpenAI key" : "separate key"
                lastOpenAIASRProbeSummary = "⚡ Verified and active (\(llmConfig.openAIASRModel)): audio upload + transcription \(rttMs)ms · \(keyMode) · top \(hotCount) dictionary terms sent as hints"
                statusBanner = "✅ \(label) verified and now the active engine"
                return true
            } catch {
                let err = "❌ Verification failed, not activated: \(error.localizedDescription)"
                asrActivationErrors[provider] = err
                statusBanner = err
                return false
            }

        case .localSenseVoice:
            if !LocalASRModel.anyInstalled() {
                let err = "❌ Cannot activate: no local speech model is installed yet. Download Parakeet or SenseVoice first."
                asrActivationErrors[provider] = err
                statusBanner = err
                return false
            }
            if !senseVoiceLoaded {
                asrEngine.reloadSenseVoiceModelAsync()
                refreshPermissionStatus()
            }
            llmConfig.selectASRProvider(.localSenseVoice)
            syncASREngineConfig()
            speechAuthorized = StreamingASREngine.isSpeechAuthorized
            statusBanner = "✅ Local offline engine (\(llmConfig.localASRModel.displayName)) is ready and now the active speech engine"
            return true
        }
    }

    public func saveLLMProviderDraft(provider: LLMProviderOption, baseURL: String, modelName: String, apiKey: String) {
        let cleanModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalModel = cleanModel.isEmpty ? provider.defaultModelName : cleanModel
        let cleanURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalURL = cleanURL.isEmpty ? provider.defaultBaseURL : cleanURL

        llmConfig.providerModels[provider.rawValue] = finalModel
        if provider == .custom {
            llmConfig.customBaseURL = finalURL
        }
        if provider == .volcengine && finalModel.hasPrefix("ep-") {
            UserDefaults.standard.set(finalModel, forKey: "tz_ark_ep_id")
        }
        if llmConfig.selectedProvider == provider {
            llmConfig.modelName = finalModel
            llmConfig.baseURL = finalURL
        }

        KeychainHelper.saveAPIKey(apiKey, for: provider)
        if llmConfig.selectedProvider == provider {
            apiKeyInput = KeychainHelper.loadAPIKey(for: provider)
            polishEngine.prewarmConnection(baseURL: llmConfig.baseURL, apiKey: apiKeyInput, model: llmConfig.modelName)
        }
        refreshSavedKeyFlags()
        syncASREngineConfig()
        speechAuthorized = StreamingASREngine.isSpeechAuthorized
        llmActivationErrors[provider] = nil
        llmProviderBenchmarkSummaries[provider] = nil
        if llmConfig.selectedProvider == provider {
            lastBenchmarkSummary = ""
        }
        let savedKey = KeychainHelper.loadAPIKey(for: provider)
        if savedKey.isEmpty && !PolishEngine.isKeylessLocalEndpoint(finalURL) {
            statusBanner = "Cleared the \(provider.shortName) API key"
        } else if llmConfig.selectedProvider == provider {
            statusBanner = "✅ \(provider.title): key and model saved"
        } else {
            statusBanner = "💾 \(provider.title): settings saved (not active yet, verify to switch)"
        }
    }

    /// Strict activation flow for LLM providers: verifies API key & live benchmark FIRST.
    /// Only switches `llmConfig.selectedProvider` after the check passes.
    @discardableResult
    public func activateLLMProvider(
        _ provider: LLMProviderOption,
        baseURL: String,
        modelName: String,
        apiKey: String
    ) async -> Bool {
        guard activatingLLMProvider == nil else { return false }
        activatingLLMProvider = provider
        llmActivationErrors[provider] = nil
        defer { activatingLLMProvider = nil }

        let cleanModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalModel = cleanModel.isEmpty ? provider.defaultModelName : cleanModel
        let cleanURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalURL = cleanURL.isEmpty ? provider.defaultBaseURL : cleanURL
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        let isKeylessLocal = PolishEngine.isKeylessLocalEndpoint(finalURL)
        if cleanKey.isEmpty && !isKeylessLocal {
            let err = "❌ Can't activate: enter your \(provider.shortName) API key first (current settings are not active)"
            llmActivationErrors[provider] = err
            statusBanner = err
            return false
        }

        // Persist key & model draft first so user doesn't lose edits, without switching active provider yet.
        KeychainHelper.saveAPIKey(cleanKey, for: provider)
        llmConfig.providerModels[provider.rawValue] = finalModel
        if provider == .custom {
            llmConfig.customBaseURL = finalURL
        }
        if provider == .volcengine && finalModel.hasPrefix("ep-") {
            UserDefaults.standard.set(finalModel, forKey: "tz_ark_ep_id")
        }
        refreshSavedKeyFlags()

        var probeConfig = llmConfig
        probeConfig.selectedProvider = provider
        probeConfig.baseURL = finalURL
        probeConfig.modelName = finalModel

        do {
            let res = try await polishEngine.benchmarkLatency(config: probeConfig, apiKey: cleanKey)
            llmConfig.selectProvider(provider)
            llmConfig.baseURL = finalURL
            llmConfig.modelName = finalModel
            llmConfig.syncActiveEndpointEdits()
            apiKeyInput = KeychainHelper.loadAPIKey(for: provider)
            refreshSavedKeyFlags()
            syncASREngineConfig()
            polishEngine.prewarmConnection(baseURL: llmConfig.baseURL, apiKey: apiKeyInput, model: llmConfig.modelName)

            let flatSample = res.sampleOutput.replacingOccurrences(of: "\n", with: " ↵ ")
            let summary = "⚡ Verified and active (\(finalModel)): first token \(res.ttftMs)ms · total \(res.totalMs)ms · sample: \"\(flatSample)\""
            llmProviderBenchmarkSummaries[provider] = summary
            lastBenchmarkSummary = summary
            statusBanner = "✅ \(provider.title) verified and now the active cleanup model"
            return true
        } catch {
            let err = "❌ Verification failed, not activated: \(error.localizedDescription)"
            llmActivationErrors[provider] = err
            statusBanner = err
            return false
        }
    }

    public func runLLMProviderBenchmark(
        provider: LLMProviderOption,
        baseURL: String,
        modelName: String,
        apiKey: String
    ) async {
        guard !isBenchmarkingLLM else { return }
        isBenchmarkingLLM = true
        llmActivationErrors[provider] = nil
        let cleanModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalModel = cleanModel.isEmpty ? provider.defaultModelName : cleanModel
        let cleanURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalURL = cleanURL.isEmpty ? provider.defaultBaseURL : cleanURL
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        llmProviderBenchmarkSummaries[provider] = "Warming up the connection and measuring \(finalModel) first-token latency…"
        if llmConfig.selectedProvider == provider {
            lastBenchmarkSummary = llmProviderBenchmarkSummaries[provider] ?? ""
        }
        defer { isBenchmarkingLLM = false }

        if !cleanKey.isEmpty {
            KeychainHelper.saveAPIKey(cleanKey, for: provider)
            refreshSavedKeyFlags()
        }

        var probeConfig = llmConfig
        probeConfig.selectedProvider = provider
        probeConfig.baseURL = finalURL
        probeConfig.modelName = finalModel

        do {
            let res = try await polishEngine.benchmarkLatency(config: probeConfig, apiKey: cleanKey)
            let flatSample = res.sampleOutput.replacingOccurrences(of: "\n", with: " ↵ ")
            let summary = "⚡ Test passed (\(finalModel)): first token \(res.ttftMs)ms · total \(res.totalMs)ms · sample: \"\(flatSample)\""
            llmProviderBenchmarkSummaries[provider] = summary
            if llmConfig.selectedProvider == provider {
                lastBenchmarkSummary = summary
            }
            statusBanner = "⚡ \(provider.shortName) test passed: first token \(res.ttftMs)ms"
        } catch {
            let summary = "❌ Latency test failed: \(error.localizedDescription)"
            llmProviderBenchmarkSummaries[provider] = summary
            if llmConfig.selectedProvider == provider {
                lastBenchmarkSummary = summary
            }
        }
    }

    public func applyOpenAIASRPreset(baseURL: String, model: String) {
        llmConfig.openAIASRBaseURL = baseURL
        llmConfig.openAIASRModel = model
        lastOpenAIASRProbeSummary = ""
        syncASREngineConfig()
    }

    public func saveAPIKey() {
        llmConfig.syncActiveEndpointEdits()
        if llmConfig.selectedProvider == .volcengine && llmConfig.modelName.hasPrefix("ep-") {
            UserDefaults.standard.set(llmConfig.modelName, forKey: "tz_ark_ep_id")
        }
        KeychainHelper.saveAPIKey(apiKeyInput, for: llmConfig.selectedProvider)
        apiKeyInput = KeychainHelper.loadAPIKey(for: llmConfig.selectedProvider)
        refreshSavedKeyFlags()
        syncASREngineConfig()
        speechAuthorized = StreamingASREngine.isSpeechAuthorized
        polishEngine.prewarmConnection(baseURL: llmConfig.baseURL, apiKey: apiKeyInput, model: llmConfig.modelName)
        lastBenchmarkSummary = ""
        statusBanner = apiKeyInput.isEmpty
            ? "Cleared the \(llmConfig.selectedProvider.shortName) API key"
            : "✅ \(llmConfig.selectedProvider.title): key and model saved and active"
    }

    public func saveVolcSpeechAPIKey() {
        let trimmed = volcSpeechKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        KeychainHelper.saveVolcSpeechAPIKey(trimmed)
        volcSpeechKeyInput = KeychainHelper.loadVolcSpeechAPIKey()
        syncASREngineConfig()
        speechAuthorized = StreamingASREngine.isSpeechAuthorized
        lastSeedASRProbeSummary = ""
        asrActivationErrors[.volcSeedASR] = nil
        if volcSpeechKeyInput.isEmpty {
            statusBanner = "Cleared the Doubao speech key"
        } else if llmConfig.asrProvider == .volcSeedASR {
            statusBanner = "✅ Your own Doubao Seed-ASR 2.0 key is saved and active"
        } else {
            statusBanner = "💾 Your Doubao key is saved (not active yet, verify to switch)"
        }
    }

    public func saveOpenAIASRConfig() {
        llmConfig.openAIASRBaseURL = llmConfig.openAIASRBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if llmConfig.openAIASRBaseURL.isEmpty {
            llmConfig.openAIASRBaseURL = "https://api.openai.com/v1"
        }
        llmConfig.openAIASRModel = llmConfig.openAIASRModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if llmConfig.openAIASRModel.isEmpty {
            llmConfig.openAIASRModel = isGroqASRSelected ? "whisper-large-v3-turbo" : "gpt-4o-mini-transcribe"
        }
        KeychainHelper.saveOpenAIASRAPIKey(openAIASRKeyInput)
        openAIASRKeyInput = KeychainHelper.loadOpenAIASROverrideKey()
        syncASREngineConfig()
        speechAuthorized = StreamingASREngine.isSpeechAuthorized
        lastOpenAIASRProbeSummary = ""
        asrActivationErrors[.openAIWhisper] = nil
        asrEngine.prewarmCloudSocketIfReady()
        let label = isGroqASRSelected ? "Groq Whisper" : "OpenAI speech model"
        if hasEffectiveOpenAIASRKey {
            let keyNote = isOpenAIASRReusingLLMKey ? " (reusing your OpenAI key)" : ""
            if llmConfig.asrProvider == .openAIWhisper {
                statusBanner = "✅ \(label) (\(llmConfig.openAIASRModel)) saved\(keyNote)"
            } else {
                statusBanner = "💾 \(label) (\(llmConfig.openAIASRModel)) saved\(keyNote). Verify to switch to it."
            }
        } else {
            statusBanner = "⚠️ \(label) endpoint settings saved, but there is no valid API key yet"
        }
    }

    public func runOpenAIASRProbe() async {
        guard !isProbingOpenAIASR else { return }
        isProbingOpenAIASR = true
        let label = isGroqASRSelected ? "Groq Whisper" : "OpenAI speech"
        lastOpenAIASRProbeSummary = "Sending 0.35s of audio to \(llmConfig.openAIASRModel) to measure end-to-end latency…"
        defer { isProbingOpenAIASR = false }

        KeychainHelper.saveOpenAIASRAPIKey(openAIASRKeyInput)
        openAIASRKeyInput = KeychainHelper.loadOpenAIASROverrideKey()
        syncASREngineConfig()
        let effectiveKey = effectiveOpenAIASRKey

        do {
            let rttMs = try await OpenAITranscriptionClient.probeLatency(
                baseURL: llmConfig.openAIASRBaseURL,
                model: llmConfig.openAIASRModel,
                apiKey: effectiveKey
            )
            let hotCount = min(40, lexiconStore.entries.count)
            let keyMode = isOpenAIASRReusingLLMKey ? "reusing your OpenAI key" : "separate key"
            lastOpenAIASRProbeSummary = "⚡ Test passed (\(llmConfig.openAIASRModel)): audio upload + transcription \(rttMs)ms · \(keyMode) · top \(hotCount) dictionary terms sent as hints"
            statusBanner = "⚡ \(label) connected: \(rttMs)ms round trip"
        } catch {
            lastOpenAIASRProbeSummary = "❌ \(label) connection failed: \(error.localizedDescription)"
        }
    }

    public func startLocalModelDownload(_ model: LocalASRModel) {
        guard !isDownloadingOfflineModel else { return }
        isDownloadingOfflineModel = true
        downloadingLocalModel = model
        offlineDownloadProgress = 0.01
        offlineDownloadStatusText = "Starting \(model.shortName) download (~\(model.approxDownloadMB) MB)…"
        modelDownloader.startDownload(model: model)
    }

    public func cancelOfflineModelDownload() {
        modelDownloader.cancelDownload()
        isDownloadingOfflineModel = false
        downloadingLocalModel = nil
    }

    public func applyDockVisibilityPolicy() {
        let desired: NSApplication.ActivationPolicy = llmConfig.showInDock ? .regular : .accessory
        if NSApp.activationPolicy() != desired {
            NSApp.setActivationPolicy(desired)
        }
    }

    public func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "tz_onboarding_done_v1")
        showOnboardingSheet = false
    }

    public func runSeedASRProbe() async {
        guard !isProbingSeedASR else { return }
        isProbingSeedASR = true
        let typedOwn = volcSpeechKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typedOwn.isEmpty {
            KeychainHelper.saveVolcSpeechAPIKey(typedOwn)
            volcSpeechKeyInput = KeychainHelper.loadVolcSpeechAPIKey()
        }
        let key = KeychainHelper.loadVolcSpeechAPIKey()
        asrEngine.volcSpeechAPIKey = key
        lastSeedASRProbeSummary = "Testing the Doubao Seed-ASR 2.0 bidirectional stream over the direct connection…"
        defer { isProbingSeedASR = false }

        do {
            let rttMs = try await VolcSeedASRClient.probeHandshakeLatency(apiKey: key)
            let hotCount = min(65, lexiconStore.entries.count)
            lastSeedASRProbeSummary = "⚡ Test passed (volc.seedasr.sauc.duration): direct connection, handshake + first frame \(rttMs)ms · \(hotCount) hotwords loaded"
            statusBanner = "⚡ Doubao Seed-ASR 2.0 connected: first frame \(rttMs)ms"
        } catch {
            lastSeedASRProbeSummary = "❌ Doubao speech connection failed: \(error.localizedDescription)"
        }
    }

    public func runLiveEngineBenchmark() async {
        guard !isBenchmarkingLLM else { return }
        isBenchmarkingLLM = true
        llmConfig.syncActiveEndpointEdits()
        lastBenchmarkSummary = "Warming up the connection and measuring \(llmConfig.modelName) first-token latency…"
        defer { isBenchmarkingLLM = false }

        // Auto-save if user typed into field without clicking save first
        if !apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            KeychainHelper.saveAPIKey(apiKeyInput, for: llmConfig.selectedProvider)
            apiKeyInput = KeychainHelper.loadAPIKey(for: llmConfig.selectedProvider)
            refreshSavedKeyFlags()
        }
        let key = KeychainHelper.loadAPIKey(for: llmConfig.selectedProvider)

        do {
            let res = try await polishEngine.benchmarkLatency(config: llmConfig, apiKey: key)
            let flatSample = res.sampleOutput.replacingOccurrences(of: "\n", with: " ↵ ")
            lastBenchmarkSummary = "⚡ Test passed (\(llmConfig.modelName)): first token \(res.ttftMs)ms · total \(res.totalMs)ms · sample: \"\(flatSample)\""
            statusBanner = "⚡ \(llmConfig.selectedProvider.shortName) test passed: first token \(res.ttftMs)ms"
        } catch {
            lastBenchmarkSummary = "❌ Latency test failed: \(error.localizedDescription)"
        }
    }

    public func beginDictationSession() {
        guard !isSessionActive, !isFinalizingSession else {
            hotkeyMonitor.syncRecordingState(isSessionActive)
            return
        }

        if !micAuthorized || !speechAuthorized || !accessibilityGranted {
            refreshPermissionStatus()
        }

        if !micAuthorized || !speechAuthorized {
            StreamingASREngine.requestPermissions { [weak self] mic, speech in
                guard let self else { return }
                self.micAuthorized = mic
                self.speechAuthorized = speech
                if !mic {
                    self.showDictationFailure(.microphoneOff)
                } else if !speech {
                    self.showDictationFailure(.speechRecognitionOff)
                }
            }
            return
        }

        let frontApp = NSWorkspace.shared.frontmostApplication
        let frontBundle = frontApp?.bundleIdentifier ?? ""
        let frontName = frontApp?.localizedName ?? ""
        isTypingInsideOwnApp = (frontBundle == AppBrand.bundleID)
        if !isTypingInsideOwnApp && !accessibilityGranted {
            hotkeyMonitor.syncRecordingState(false)
            showDictationFailure(.accessibilityOff)
            return
        }

        // 1. 0.0ms INSTANT visual + audio feedback & immediate mic stream launch (ZERO synchronous IPC or CoreAudio stall on MainActor!)
        userSubmittedViaEnter = false
        isSessionActive = true
        hotkeyMonitor.syncRecordingState(true)
        if isTypingInsideOwnApp {
            sandboxBaseBeforeSession = sandboxText
        }

        let fastInitialContext = ActiveScreenContext(
            appName: frontName,
            bundleID: frontBundle,
            windowTitle: "",
            selectedText: "",
            precedingText: ""
        )
        activeContext = fastInitialContext
        activeMode = .dictate
        AudioLevelBus.shared.reset()
        // The first guess has no focus check yet: the session types nothing until the capture below delivers it (`updateContext`).
        let session: LiveInputSession? = llmConfig.enableLiveInlineTyping ? LiveInputSession(context: fastInitialContext, awaitingFocusCheck: true) : nil
        liveInputSession = session
        phase = .listening(livePreview: "", mode: .dictate)
        // Start cue first, whatever the auto-mute setting; auto-mute then waits until the cue has played, because muting the
        // output device would silence the cue too (nothing to wait for when sound effects are off).
        playSessionCue(.start)
        if llmConfig.enableAutoMuteDuringDictation {
            scheduleAutoMute(after: startCueMuteDelay())
        }

        // 2. Zero-wait parallel mic start!
        // Launch ASR streaming immediately (~0.5ms using in-memory lexicon + history + clipboard)
        // so the very first syllable is NEVER clipped while AXUIElement inspects heavy Electron/browser trees.
        syncASREngineConfig()
        let localeID = llmConfig.speechLocale
        let entriesSnapshot = lexiconStore.entries
        let recentSnippets = Array(history.prefix(2).map(\.polishedText))
        let ownSandboxSnapshot = isTypingInsideOwnApp ? String(sandboxText.suffix(140)) : ""
        let rawClip = (NSPasteboard.general.string(forType: .string) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let shortClipboardHint = (rawClip.count >= 2 && rawClip.count <= 42 && !rawClip.contains("\n")) ? rawClip : ""

        let currentBaseURL = llmConfig.baseURL
        let currentKey = KeychainHelper.loadAPIKey(for: llmConfig.selectedProvider)
        // For a local Ollama endpoint this also loads the cleanup model (keep_alive -1: resident until Ollama quits) while the user is still speaking.
        polishEngine.prewarmConnection(baseURL: currentBaseURL, apiKey: currentKey, model: llmConfig.modelName)

        // Immediate hotword ranking + dialog_ctx from fast in-memory sources -> instant mic open!
        let immediateHint = ([frontName, shortClipboardHint, ownSandboxSnapshot] + recentSnippets).joined(separator: " ")
        var topTerms = PersonalLexiconStore.rankHotwords(from: entriesSnapshot, contextHint: immediateHint, limit: 64)
        if shortClipboardHint.count >= 2,
           shortClipboardHint.count <= 14,
           !shortClipboardHint.contains(" "),
           !topTerms.contains(where: { $0.caseInsensitiveCompare(shortClipboardHint) == .orderedSame }) {
            topTerms.insert(shortClipboardHint, at: 0)
        }
        var dialogCtxItems: [String] = []
        let cleanOwnPre = ownSandboxSnapshot.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanOwnPre.isEmpty {
            dialogCtxItems.append(String(cleanOwnPre.suffix(100)))
        }
        for snippet in recentSnippets.prefix(2) {
            let s = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty {
                dialogCtxItems.append(String(s.suffix(100)))
            }
        }
        asrEngine.startStreamingAsync(
            localeIdentifier: localeID,
            contextualStrings: topTerms,
            dialogContext: Array(dialogCtxItems.prefix(2))
        )

        // 3. In parallel, inspect active AX input-box context in background for Pass-2 LLM & rewrite-selection mode.
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let fullCtx = ContextInjector.captureCurrentContext()
            session?.updateContext(fullCtx)

            DispatchQueue.main.async {
                guard let self, self.isSessionActive else { return }
                self.activeContext = fullCtx
                if !fullCtx.selectedText.isEmpty {
                    self.activeMode = .rewriteSelection
                    self.phase = .listening(livePreview: "", mode: .rewriteSelection)
                }
            }
        }
    }

    public func finishDictationSession() async {
        guard isSessionActive, !isFinalizingSession else { return }
        isFinalizingSession = true
        defer {
            isFinalizingSession = false
            restoreSystemAudio()
        }
        hotkeyMonitor.syncRecordingState(false)

        // Tail-capture grace window: keep microphone & ASR stream open for 0.1s after stop trigger
        // so trailing syllables finish cleanly while keeping stop-to-paste feeling snappy.
        try? await Task.sleep(nanoseconds: 100_000_000)

        isSessionActive = false
        // Immediately restore system audio output as soon as mic tail capture finishes (before LLM polishing)!
        restoreSystemAudio()
        // Stop cue: right after the output is restored (a muted device would swallow it) and before any cleanup work.
        playSessionCue(.stop)
        let sessionUsedPunctuatedCloudASR = asrEngine.activeSessionUsesAnyCloudASR
        if asrEngine.activeSessionUsesOpenAIASR {
            phase = .polishing(rawText: "Transcribing in the cloud…")
        }
        let (rawText, duration) = await asrEngine.finishStreaming()
        guard !rawText.isEmpty else {
            if isTypingInsideOwnApp {
                sandboxText = sandboxBaseBeforeSession
            } else {
                _ = liveInputSession?.updateLiveText("")
            }
            liveInputSession = nil
            if case .error = phase {
                // Preserve error banner emitted by asrEngine.onError
            } else {
                phase = .idle
            }
            return
        }

        // Nothing but filler sounds ("uh", "um", "嗯") and punctuation: skip the model and the fast path, insert nothing (and take
        // back anything already typed live), keep no history entry, and say so briefly.
        if PolishEngine.isFillerOnlyTranscript(rawText) {
            if isTypingInsideOwnApp {
                sandboxText = sandboxBaseBeforeSession
            } else {
                _ = liveInputSession?.updateLiveText("")
            }
            liveInputSession = nil
            phase = .error(message: DictationFailure.noSpeechPillText)
            scheduleIdleReset(after: DictationFailure.noSpeechDisplaySeconds)
            return
        }

        let tailFixed = PolishEngine.applyInstantLocalDictionary(
            rawText,
            entries: lexiconStore.entries,
            context: activeContext,
            config: llmConfig,
            stripPeriod: true
        )
        if isTypingInsideOwnApp && llmConfig.enableLiveInlineTyping && activeMode == .dictate {
            sandboxText = sandboxBaseBeforeSession + tailFixed
        }

        let recalled = lexiconStore.recallRelevantTerms(
            for: rawText,
            activeWindowTitle: activeContext.windowTitle,
            limit: 26
        )
        let recentTexts = history.prefix(3).map(\.polishedText).reversed() as [String]
        let effectiveConfig = llmConfig
        var key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            key = KeychainHelper.loadAPIKey(for: effectiveConfig.selectedProvider)
        }
        if key.isEmpty
            && !PolishEngine.isKeylessLocalEndpoint(effectiveConfig.baseURL)
            && effectiveConfig.formattingStyle != .verbatimLocal {
            statusBanner = "⚠️ No API key for the active \(effectiveConfig.selectedProvider.shortName) provider; only your local dictionary was applied this time"
        }

        phase = .polishing(rawText: tailFixed)

        let canStreamSSELive = !isTypingInsideOwnApp
            && llmConfig.enableLiveInlineTyping
            && activeMode == .dictate
            && (liveInputSession?.prepareForSSEPolishStream() == true)
        var didStreamViaSSE = false

        let polishOutcome = await polishEngine.polishWithDiagnostics(
            rawTranscript: rawText,
            mode: activeMode,
            screenContext: activeContext,
            recalledTerms: recalled,
            recentOutputs: recentTexts,
            config: effectiveConfig,
            apiKey: key,
            // Parakeet TDT v2 and SenseVoice both count as high-accuracy local ASR.
            isHighAccuracyLocalASR: asrEngine.activeLocalModel != nil,
            isPunctuatedCloudASR: sessionUsedPunctuatedCloudASR,
            onStreamChunk: { [weak self] chunk, isFirst in
                guard let self else { return }
                if self.isTypingInsideOwnApp && self.llmConfig.enableLiveInlineTyping {
                    if isFirst {
                        self.sandboxText = self.sandboxBaseBeforeSession + chunk
                    } else {
                        self.sandboxText += chunk
                    }
                    didStreamViaSSE = true
                } else if canStreamSSELive {
                    self.liveInputSession?.consumeSSEChunk(chunk)
                    didStreamViaSSE = true
                }
            }
        )

        let finalText = polishOutcome.text
        let polishMs = polishOutcome.latencyMs
        if polishOutcome.route == .llmFailedFallback {
            // Make an unreachable / timed-out cleanup model visible instead of silently pasting the raw transcript.
            statusBanner = "⚠️ Cleanup model unavailable (\(polishOutcome.llmError ?? "unknown error")) — inserted the raw transcript instead."
        }

        guard !finalText.isEmpty else {
            liveInputSession = nil
            phase = .idle
            return
        }

        // Where can the text go? Asked again now instead of trusting the check from the start of the dictation: the user may have clicked
        // into (or out of) a text field while speaking. The read runs off the main thread (when the focus is not a text field it walks
        // up a web page's accessibility tree, which can take tens of milliseconds); `userSubmittedViaEnter` is looked at again below,
        // because Enter can arrive while it runs.
        var focusStatusAtDelivery: FocusedTextInputStatus? = nil
        if !isTypingInsideOwnApp && !userSubmittedViaEnter {
            focusStatusAtDelivery = await Task.detached(priority: .userInitiated) {
                ContextInjector.focusedTextInputStatus(tracePhase: "deliver")
            }.value
        }

        var landedInInput = true
        if userSubmittedViaEnter {
            // User already hit Enter and sent the message during polishing — do NOT re-paste a ghost copy!
            ContextInjector.appendInjectionTrace("finalize app=\(activeContext.bundleID) branch=abortedUserSubmitInAppState final=\(finalText.count)")
            landedInInput = true
        } else if isTypingInsideOwnApp {
            sandboxText = sandboxBaseBeforeSession + finalText
        } else {
            // Without a text input to take it, nothing is typed or pasted and the clipboard is left alone: the text is offered on
            // the Copy pill instead.
            let focusStatus = focusStatusAtDelivery ?? .unknown
            let plan = DictationDelivery.plan(
                status: focusStatus,
                accessibilityTrusted: ContextInjector.isAccessibilityTrusted(),
                targetAllowed: ContextInjector.isAllowedTarget(bundleID: activeContext.bundleID, appName: activeContext.appName)
            )
            if case .offerCopy(let reason) = plan {
                ContextInjector.appendInjectionTrace("finalize app=\(activeContext.bundleID) branch=\(reason.traceBranch) emitted=\(liveInputSession?.currentText.count ?? 0) final=\(finalText.count)")
                landedInInput = false
            } else if didStreamViaSSE {
                liveInputSession?.finishSSEPolishStream(with: finalText)
            } else if llmConfig.enableLiveInlineTyping && activeMode == .dictate {
                landedInInput = liveInputSession?.finalizeAfterKeyRelease(with: finalText, focusStatus: focusStatus) ?? false
            } else {
                ContextInjector.injectTextAtCursor(finalText, in: activeContext)
            }
        }

        let trulyUsedTerms = recalled.filter { finalText.localizedCaseInsensitiveContains($0.term) }
        if !trulyUsedTerms.isEmpty {
            lexiconStore.recordTermHits(trulyUsedTerms)
        }

        // Voice Teach-in Loop: when user selected wrong text and pressed Fn to fix it, permanently learn the correction!
        if activeMode == .rewriteSelection && llmConfig.enableAutoLearn {
            if let taught = lexiconStore.learnFromSelectionRewrite(selectedText: activeContext.selectedText, rewrittenText: finalText) {
                statusBanner = "✨ Voice correction saved to your dictionary: \"\(taught.wrong)\" ➔ \"\(taught.corrected)\""
            }
        }

        let record = DictationRecord(
            rawTranscript: rawText,
            polishedText: finalText,
            durationSeconds: duration,
            polishLatencyMs: polishMs,
            targetAppName: isTypingInsideOwnApp ? "\(AppBrand.name) Sandbox" : activeContext.appName,
            mode: activeMode,
            matchedTerms: recalled.prefix(5).map(\.term)
        )
        history.insert(record, at: 0)
        if history.count > 1000 {
            history = Array(history.prefix(1000))
        }
        saveHistory()

        liveInputSession = nil

        if !landedInInput {
            showCopyPill(for: finalText)
        } else {
            phase = .completed(finalText: finalText, latencyMs: polishMs)
            scheduleIdleReset(after: 0.35)
            // P6 Auto-Learn Watcher: observe manual word corrections (both single-line and multi-paragraph!) at 5.5s & 12.5s
            if llmConfig.enableAutoLearn {
                scheduleAutoLearnObservation(
                    injectedText: finalText,
                    expectedBundleID: activeContext.bundleID,
                    wasInsideSandbox: isTypingInsideOwnApp
                )
            }
        }
    }

    private func scheduleAutoLearnObservation(injectedText: String, expectedBundleID: String, wasInsideSandbox: Bool) {
        let generationCount = history.count
        Task { @MainActor [weak self] in
            for delaySec in [5.5, 6.8] {
                try? await Task.sleep(nanoseconds: UInt64(delaySec * 1_000_000_000))
                guard let self, !self.isSessionActive, self.history.count == generationCount else { return }

                let editedBox: String?
                if wasInsideSandbox {
                    editedBox = self.sandboxText
                } else {
                    let currentFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
                    guard currentFront == expectedBundleID else { continue }
                    editedBox = ContextInjector.readCurrentFocusedValue()
                }
                guard let boxVal = editedBox, !boxVal.isEmpty else { continue }

                if let learned = self.lexiconStore.learnFromManualEditIfApplicable(injectedText: injectedText, editedBoxValue: boxVal) {
                    self.statusBanner = "✨ Learned from your edit: \"\(learned.wrong)\" ➔ \"\(learned.corrected)\""
                    return
                }
            }
        }
    }

    /// Shows why dictation failed: the short reason in the floating pill for `DictationFailure.displaySeconds`, and the
    /// full explanation in the main window banner so it is still there when the window is opened afterwards.
    private func showDictationFailure(_ failure: DictationFailure) {
        phase = .error(message: failure.pillText)
        statusBanner = failure.bannerText
        scheduleIdleReset(after: DictationFailure.displaySeconds)
    }

    // MARK: Copy pill

    /// The cleaned text had nowhere to go (no text input in focus): offers it on the pill instead of typing it or touching the
    /// clipboard. The pill hides after `CopyPillCountdown.visibleSeconds` unless Copy is clicked; hovering it pauses that countdown.
    private func showCopyPill(for text: String) {
        copyCountdown.start(now: Date())
        phase = .readyToCopy(text: text)
        scheduleIdleReset(after: copyCountdown.remaining)
    }

    /// The pill's Copy button: the full text goes on the general pasteboard as plain text, the pill says "Copied" for a second, then hides.
    public func copyReadyText() {
        guard case .readyToCopy(let text) = phase else { return }
        ContextInjector.copyPlainText(text)
        phase = .copied
        scheduleIdleReset(after: CopyPillCountdown.copiedSeconds)
    }

    /// The pointer entered or left the Copy pill (reported by the pill window's tracking area).
    public func copyPillHoverChanged(_ isHovering: Bool) {
        guard case .readyToCopy = phase else { return }
        if isHovering, copyCountdown.isRunning {
            copyCountdown.pause(now: Date())
            idleResetTask?.cancel()
        } else if !isHovering, !copyCountdown.isRunning {
            copyCountdown.resume(now: Date())
            scheduleIdleReset(after: copyCountdown.remaining)
        }
    }

    /// Returns the pill to idle after `seconds`. Only the latest call counts: an earlier timer must not cut a newer
    /// error short (for example when the shortcut is pressed again while an error is still showing).
    private func scheduleIdleReset(after seconds: Double) {
        idleResetTask?.cancel()
        idleResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            if case .listening = self.phase { return }
            if case .polishing = self.phase { return }
            self.phase = .idle
        }
    }

    public func distillPastedCorpus(_ rawCorpus: String) async {
        let key = KeychainHelper.loadAPIKey(for: llmConfig.selectedProvider)
        do {
            let extracted = try await polishEngine.distillTermsFromRawCorpus(
                corpusText: rawCorpus,
                config: llmConfig,
                apiKey: key
            )
            let count = lexiconStore.bulkUpsert(extracted)
            statusBanner = "Extraction complete: \(count) new terms added (\(lexiconStore.entries.count) total)"
        } catch {
            statusBanner = "Extraction failed: \(error.localizedDescription)"
        }
    }

    public var totalCharactersDictated: Int {
        history.reduce(0) { $0 + $1.characterCount }
    }

    public var totalDictationMinutes: Double {
        history.reduce(0.0) { $0 + $1.durationSeconds } / 60.0
    }

    public var averageCharactersPerMinute: Int {
        let mins = totalDictationMinutes
        guard mins > 0.05 else { return 0 }
        return Int(Double(totalCharactersDictated) / mins)
    }

    public var timeSavedMinutes: Int {
        let manualMinutes = Double(totalCharactersDictated) / 45.0
        let saved = max(0, manualMinutes - totalDictationMinutes)
        return Int(saved.rounded())
    }

    public var averagePolishLatencyMs: Int {
        guard !history.isEmpty else { return 0 }
        return history.reduce(0) { $0 + $1.polishLatencyMs } / history.count
    }

    public var activeDaysCount: Int {
        let cal = Calendar.current
        let uniqueDays = Set(history.map { cal.startOfDay(for: $0.timestamp) })
        return uniqueDays.count
    }

    public func dailyCountMap() -> [Date: Int] {
        let cal = Calendar.current
        var map: [Date: Int] = [:]
        for rec in history {
            let day = cal.startOfDay(for: rec.timestamp)
            map[day, default: 0] += rec.characterCount
        }
        return map
    }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: historyURL),
              let decoded = try? JSONDecoder().decode([DictationRecord].self, from: data) else { return }
        self.history = decoded
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            try? data.write(to: historyURL, options: .atomic)
        }
    }

    private func loadConfig() {
        if let data = try? Data(contentsOf: configURL),
           var decoded = try? JSONDecoder().decode(LLMConfig.self, from: data) {
            if !UserDefaults.standard.bool(forKey: "tz_default_inline_on_v3") {
                decoded.enableLiveInlineTyping = true
                UserDefaults.standard.set(true, forKey: "tz_default_inline_on_v3")
                self.llmConfig = decoded
                saveConfig()
                return
            }
            self.llmConfig = decoded
        } else {
            UserDefaults.standard.set(true, forKey: "tz_default_inline_on_v3")
        }
    }

    private func saveConfig() {
        if let data = try? JSONEncoder().encode(llmConfig) {
            try? data.write(to: configURL, options: .atomic)
        }
    }
}
