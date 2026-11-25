import Foundation
import AVFoundation
import Speech
import CSherpaOnnx

/// Continuous, memory-bounded SenseVoice + VAD Sliding Segment Engine:
/// Uses real-time Voice Activity Detection (VAD) to detect natural breath pauses (~420ms silence),
/// commits completed clauses into `frozenTranscriptPrefix`, and IMMEDIATELY flushes `activeSegmentSamples`!
/// Guarantees constant ~25ms inference speed and flat memory even if you dictate non-stop for 30+ minutes.
///
/// NOTE: despite the legacy `senseVoice*` names, `senseVoiceHandle` / `isUsingSenseVoice` / `runSenseVoice` are generic over
/// whichever local sherpa-onnx recognizer is active (`activeLocalModel`: Parakeet TDT v2 or SenseVoice).
public final class StreamingASREngine: NSObject, @unchecked Sendable {
    private var audioEngine: AVAudioEngine?
    private var senseVoiceHandle: OpaquePointer?
    private let seedASRClient = VolcSeedASRClient()
    private let openAIASRClient = OpenAITranscriptionClient()
    private let decodeQueue = DispatchQueue(label: "io.github.typezero.sensevoice.decode", qos: .userInteractive)
    private let audioControlQueue = DispatchQueue(label: "io.github.typezero.audio.control", qos: .userInteractive)

    private let sampleLock = NSLock()
    /// Rolling buffer holding ONLY the current active clause (flushed on every breath pause in local mode)
    private var activeSegmentSamples: [Float] = []
    /// Full-utterance backup (capped at 90s) used for zero-word-loss local FP32 failover if Wi-Fi drops mid-speech
    private var cloudFailoverBackupSamples: [Float] = []
    /// Completed & locked earlier sentences (never re-decoded again -> zero drift, zero memory bloat!)
    private var frozenTranscriptPrefix: String = ""
    private var currentSampleRate: Int32 = 48_000
    private var lastDecodedSampleCount: Int = 0
    private var isDecodingChunk: Bool = false

    // Polyphase CoreAudio resampler for 16kHz Int16 Seed-ASR streaming
    private var pcm16Converter: AVAudioConverter?
    private var pcm16SourceFormat: AVAudioFormat?
    private let pcm16TargetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)

    // Lightweight inline VAD state
    private var hasDetectedSpeechInSegment: Bool = false
    private var hasDetectedSpeechOverall: Bool = false
    private var lastDecodedVoiceSampleMark: Int = 0
    private var totalVoiceSamplesInSegment: Int = 0
    private var consecutiveSilentSamples: Int = 0
    private var liveTimer: DispatchSourceTimer?
    private var cloudWatchdogTimer: DispatchSourceTimer?

    // Fallback Apple recognizer only if SenseVoice model files are absent
    private var fallbackRecognizer: SFSpeechRecognizer?
    private var fallbackRequest: SFSpeechAudioBufferRecognitionRequest?
    private var fallbackTask: SFSpeechRecognitionTask?

    private var latestTranscript: String = ""
    private var sessionStartTime: Date = Date()

    /// True whenever ANY local model (Parakeet or SenseVoice) is loaded.
    public private(set) var isUsingSenseVoice: Bool = false
    public private(set) var isFullPrecisionFP32: Bool = false
    /// The local model currently loaded in the handle slot (may differ from `localASRModel` when the selected one is not installed).
    public private(set) var activeLocalModel: LocalASRModel?
    /// User-selected local model (synced from `LLMConfig.localASRModel`).
    public var localASRModel: LocalASRModel = .default
    public private(set) var activeSessionUsesCloudSeedASR: Bool = false
    public private(set) var activeSessionUsesOpenAIASR: Bool = false
    public var activeSessionUsesAnyCloudASR: Bool {
        activeSessionUsesCloudSeedASR || activeSessionUsesOpenAIASR
    }
    public var asrProvider: ASRProviderOption = .volcSeedASR
    public var enableVolcSeedASR: Bool {
        get { asrProvider == .volcSeedASR }
        set { asrProvider = newValue ? .volcSeedASR : .localSenseVoice }
    }
    public var volcSpeechAPIKey: String = ""
    public var openAIASRBaseURL: String = "https://api.openai.com/v1"
    public var openAIASRModel: String = "gpt-4o-mini-transcribe"
    public var openAIASRAPIKey: String = ""
    public var enableWhisperAGC: Bool = true
    public var speechLocale: String = "auto"
    public var onPartialResult: ((_ text: String, _ flushTrailingChar: Bool) -> Void)?
    public var onModelReady: (() -> Void)?
    public var onCloudFailoverNotice: ((_ reason: String) -> Void)?
    public var onError: ((String) -> Void)?
    private var didFlushMicroPauseTail: Bool = false
    private var openAIActiveHotwords: [String] = []
    private var openAIActiveLocale: String = "auto"
    private var loadedSenseVoiceLanguage: String = ""
    private var loadedLocalModel: LocalASRModel?
    /// Rolling 220ms pre-roll ring buffer captured while mic is hot-standby (KeyDown / 15s keep-alive)
    /// so the very first syllable spoken right at keypress is NEVER clipped!
    private var preRollSamples: [Float] = []
    private var isCaptureActive: Bool = false
    private var isTapInstalled: Bool = false
    private var activeMaxBackupSamples: Int = 48_000 * 90
    private var idleHardwareShutdownWorkItem: DispatchWorkItem?
    private let hotMicKeepAliveSeconds: Double = 15.0
    private let modelInitLock = NSLock()

    public override init() {
        super.init()
        setupSeedASRCallbacks()
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.audioControlQueue.async {
                // If user plugged/unplugged AirPods or USB mic while not actively dictating,
                // tear down stale graph cleanly so next session binds the fresh hardware sample rate!
                self.sampleLock.lock()
                let capturing = self.isCaptureActive
                self.sampleLock.unlock()
                if !capturing {
                    self.shutdownAudioHardwareCompletely()
                }
            }
        }
    }

    private func setupSeedASRCallbacks() {
        seedASRClient.onStreamingTranscript = { [weak self] text, isDefinite in
            guard let self else { return }
            self.sampleLock.lock()
            let usingCloud = self.activeSessionUsesCloudSeedASR
            if usingCloud {
                self.didFlushMicroPauseTail = isDefinite
            }
            self.sampleLock.unlock()

            guard usingCloud, self.audioEngine?.isRunning == true, !text.isEmpty else { return }
            if text != self.latestTranscript || isDefinite {
                self.latestTranscript = text
                self.onPartialResult?(text, isDefinite)
            }
        }

        seedASRClient.onConnectionFallbackNeeded = { [weak self] reason in
            self?.switchActiveSessionFromCloudToLocalFP32(reason: reason)
        }
    }

    deinit {
        if let h = senseVoiceHandle {
            tz_sensevoice_destroy(h)
        }
    }

    // MARK: Apple Speech fallback (on-device only)

    /// Why the macOS speech fallback may not be used (nil when it may). It is allowed only when macOS can recognize speech on
    /// this Mac: a recognizer that needs Apple's servers (no on-device support for the language, or the on-device assets
    /// missing) is refused, and so is one that is not ready. Never fall back to server recognition.
    static func appleFallbackFailure(isAvailable: Bool, supportsOnDeviceRecognition: Bool) -> DictationFailure? {
        (isAvailable && supportsOnDeviceRecognition) ? nil : DictationFailure.onDeviceSpeechUnavailable
    }

    /// The only place a fallback recognition request is set up: it must never be sent to Apple's servers.
    static func configureAppleFallbackRequest(_ request: SFSpeechAudioBufferRecognitionRequest, contextualStrings: [String]) {
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.contextualStrings = contextualStrings
    }

    public static var isMicrophoneAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    public static var isSpeechAuthorized: Bool {
        if LocalASRModel.anyInstalled()
            || KeychainHelper.hasAnyDoubaoCredential
            || !KeychainHelper.loadEffectiveOpenAIASRAPIKey().isEmpty {
            return true
        }
        return SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    public static func senseVoiceModelPaths() -> (model: String, tokens: String, isFullFP32: Bool)? {
        guard let files = LocalASRModel.senseVoice.installedFiles() else { return nil }
        return (files.modelPath, files.tokensPath, files.isFullPrecision)
    }

    /// Creates a recognizer handle for resolved model files. This is the single construction path shared by the app engine
    /// and the headless `--dictate-file` CLI; the returned handle works with `tz_sensevoice_transcribe` for both models.
    public static func createLocalRecognizerHandle(files: LocalASRModelFiles, speechLocale: String) -> OpaquePointer? {
        switch files.model {
        case .parakeetTDTv2:
            guard let decoder = files.decoderPath, let joiner = files.joinerPath else { return nil }
            // English-only model: `speechLocale` is ignored. 4 threads decode as fast as 8 on Apple Silicon.
            return tz_parakeet_create(files.modelPath, decoder, joiner, files.tokensPath, 4)
        case .senseVoice:
            let maxThreads = files.isFullPrecision ? 8 : 6
            let threads = Int32(max(4, min(maxThreads, ProcessInfo.processInfo.activeProcessorCount - 2)))
            return tz_sensevoice_create(files.modelPath, files.tokensPath, threads, LLMConfig.senseVoiceLanguageCode(for: speechLocale))
        }
    }

    /// Loads the selected local model into the handle slot. If its files are missing the other installed model is used;
    /// if none is installed the current state is left untouched.
    public func loadSenseVoiceIfAvailable() {
        modelInitLock.lock()
        defer { modelInitLock.unlock() }

        let targetLang = LLMConfig.senseVoiceLanguageCode(for: speechLocale)
        let ordered = [localASRModel] + LocalASRModel.allCases.filter { $0 != localASRModel }
        for candidate in ordered {
            guard let files = candidate.installedFiles() else { continue }

            // Already loaded and still current (SenseVoice additionally depends on the language token).
            if senseVoiceHandle != nil,
               loadedLocalModel == candidate,
               (candidate != .senseVoice || loadedSenseVoiceLanguage == targetLang) {
                isUsingSenseVoice = true
                return
            }

            guard let handle = Self.createLocalRecognizerHandle(files: files, speechLocale: speechLocale) else { continue }
            let oldHandleBits = senseVoiceHandle.map { Int(bitPattern: $0) }
            self.senseVoiceHandle = handle
            self.loadedLocalModel = candidate
            self.activeLocalModel = candidate
            self.loadedSenseVoiceLanguage = (candidate == .senseVoice) ? targetLang : ""
            self.isUsingSenseVoice = true
            self.isFullPrecisionFP32 = files.isFullPrecision
            if let bits = oldHandleBits {
                decodeQueue.async {
                    if let oldPtr = OpaquePointer(bitPattern: bits) {
                        tz_sensevoice_destroy(oldPtr)
                    }
                }
            }
            DispatchQueue.main.async { [weak self] in
                self?.onModelReady?()
            }
            return
        }
        isUsingSenseVoice = (senseVoiceHandle != nil)
    }

    public func reloadSenseVoiceModelAsync() {
        audioControlQueue.async { [weak self] in
            self?.loadSenseVoiceIfAvailable()
        }
    }

    public static func requestPermissions(completion: @escaping (Bool, Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { micGranted in
            if LocalASRModel.anyInstalled()
                || KeychainHelper.hasAnyDoubaoCredential
                || !KeychainHelper.loadEffectiveOpenAIASRAPIKey().isEmpty {
                DispatchQueue.main.async {
                    completion(micGranted, true)
                }
                return
            }
            SFSpeechRecognizer.requestAuthorization { speechStatus in
                DispatchQueue.main.async {
                    completion(micGranted, speechStatus == .authorized)
                }
            }
        }
    }

    public func prewarmCloudSocketIfReady() {
        switch asrProvider {
        case .volcSeedASR:
            let key = volcSpeechAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            seedASRClient.prewarmStandbySocket(apiKey: key)
        case .openAIWhisper:
            let key = openAIASRAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty || PolishEngine.isKeylessLocalEndpoint(openAIASRBaseURL) else { return }
            openAIASRClient.prewarmConnection(baseURL: openAIASRBaseURL, apiKey: key)
        case .localSenseVoice:
            break
        }
    }

    public func warmUp(localeIdentifier: String = "auto") {
        speechLocale = localeIdentifier
        prewarmCloudSocketIfReady()
        audioControlQueue.async { [weak self] in
            guard let self else { return }
            if self.senseVoiceHandle == nil {
                self.loadSenseVoiceIfAvailable()
            }
            // Pre-initialize CoreAudio input graph once so first Fn press starts in ~12ms instead of ~320ms!
            if Self.isMicrophoneAuthorized && self.audioEngine == nil {
                let engine = AVAudioEngine()
                _ = engine.inputNode.outputFormat(forBus: 0)
                engine.prepare()
                self.audioEngine = engine
            }
        }
    }

    /// Non-blocking ultra-fast streaming start: launches CoreAudio tap on dedicated `.userInteractive` queue
    /// so `@MainActor` UI responds in 0.0ms without dropping the first spoken syllable!
    public func startStreamingAsync(
        localeIdentifier: String = "auto",
        contextualStrings: [String] = [],
        dialogContext: [String] = []
    ) {
        audioControlQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.startStreamingInternal(
                    localeIdentifier: localeIdentifier,
                    contextualStrings: contextualStrings,
                    dialogContext: dialogContext
                )
            } catch {
                DispatchQueue.main.async {
                    self.onError?(error.localizedDescription)
                }
            }
        }
    }

    /// Wakes hardware microphone immediately on KeyDown (before key release) and keeps a rolling
    /// ~220ms pre-roll buffer in memory so zero opening syllables are ever clipped.
    public func prewarmHotMicAsync() {
        guard Self.isMicrophoneAuthorized else { return }
        audioControlQueue.async { [weak self] in
            guard let self else { return }
            self.idleHardwareShutdownWorkItem?.cancel()
            self.idleHardwareShutdownWorkItem = nil
            do {
                _ = try self.ensureHotMicRunning()
                self.scheduleIdleHardwareShutdown()
            } catch {
                // Non-fatal during prewarm; startStreamingAsync will surface any real permission error.
            }
        }
    }

    private func ensureHotMicRunning() throws -> AVAudioFormat {
        let engine: AVAudioEngine
        if let existing = self.audioEngine {
            engine = existing
        } else {
            let fresh = AVAudioEngine()
            self.audioEngine = fresh
            engine = fresh
            self.isTapInstalled = false
        }

        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            throw NSError(domain: "TypeZero.ASR", code: -2, userInfo: [NSLocalizedDescriptionKey: "Microphone input is unavailable. Check microphone permissions."])
        }

        let hwRate = Int32(recordingFormat.sampleRate)
        sampleLock.lock()
        if currentSampleRate != hwRate {
            currentSampleRate = hwRate
            preRollSamples.removeAll(keepingCapacity: true)
        }
        sampleLock.unlock()

        if !isTapInstalled {
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 512, format: recordingFormat) { [weak self] buffer, _ in
                self?.handleIncomingAudioBuffer(buffer)
            }
            isTapInstalled = true
        }

        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        return recordingFormat
    }

    private func handleIncomingAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channel0 = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }

        sampleLock.lock()
        let capturing = self.isCaptureActive
        if !capturing {
            // Hot-standby mode: silently maintain a rolling ~220ms pre-roll ring buffer (zero network/CPU/UI work)
            let maxPreRoll = max(1600, Int(Double(self.currentSampleRate) * 0.22))
            self.preRollSamples.append(contentsOf: UnsafeBufferPointer(start: channel0, count: count))
            if self.preRollSamples.count > maxPreRoll {
                self.preRollSamples.removeFirst(self.preRollSamples.count - maxPreRoll)
            }
            sampleLock.unlock()
            return
        }
        let maxBackupSamples = self.activeMaxBackupSamples
        let currentlyVolcCloud = self.activeSessionUsesCloudSeedASR
        let currentlyOpenAICloud = self.activeSessionUsesOpenAIASR
        let currentlyAnyCloud = currentlyVolcCloud || currentlyOpenAICloud
        sampleLock.unlock()

        let (normLevel, rawRMS) = Self.calculateRMSMetrics(buffer: buffer)
        AudioLevelBus.shared.push(normLevel)

        let voiceThreshold: Float = self.enableWhisperAGC ? 0.0024 : 0.0080
        let isVoiceFrame = rawRMS > voiceThreshold

        // Preserve full-spectrum hardware PCM (all high-frequency Mandarin sibilants 4kHz-10kHz intact!)
        self.sampleLock.lock()
        guard self.isCaptureActive else {
            self.sampleLock.unlock()
            return
        }
        if !currentlyOpenAICloud {
            self.activeSegmentSamples.append(contentsOf: UnsafeBufferPointer(start: channel0, count: count))
        }
        if currentlyAnyCloud && self.cloudFailoverBackupSamples.count < maxBackupSamples {
            self.cloudFailoverBackupSamples.append(contentsOf: UnsafeBufferPointer(start: channel0, count: count))
        }
        var virtualOpenAICount: Int? = nil
        if isVoiceFrame {
            self.hasDetectedSpeechInSegment = true
            self.hasDetectedSpeechOverall = true
            self.didFlushMicroPauseTail = false
            self.totalVoiceSamplesInSegment += count
            self.consecutiveSilentSamples = 0
            if currentlyOpenAICloud {
                // Drive subtle rhythmic progress indicator in the floating capsule while recording for batch cloud ASR
                let stepSamples = max(1, Int(self.currentSampleRate) / 5) // ~200ms of speech per rhythm pulse
                virtualOpenAICount = max(1, self.totalVoiceSamplesInSegment / stepSamples)
            }
        } else {
            self.consecutiveSilentSamples += count
            let maxIdlePreRoll = Int(self.currentSampleRate) / 4
            if !currentlyOpenAICloud && !self.hasDetectedSpeechInSegment && self.activeSegmentSamples.count > maxIdlePreRoll {
                let excess = self.activeSegmentSamples.count - maxIdlePreRoll
                self.activeSegmentSamples.removeFirst(excess)
            }
            if currentlyAnyCloud && !self.hasDetectedSpeechOverall && self.cloudFailoverBackupSamples.count > maxIdlePreRoll {
                let excess = self.cloudFailoverBackupSamples.count - maxIdlePreRoll
                self.cloudFailoverBackupSamples.removeFirst(excess)
            }
        }
        self.sampleLock.unlock()

        if let pulse = virtualOpenAICount {
            AudioLevelBus.shared.pushRecognizedCount(pulse)
        }

        if currentlyVolcCloud {
            let pcm16 = self.convertMonoFloatTo16kHzPCM16(channel0: channel0, count: count, rawRMS: rawRMS, isVoice: isVoiceFrame)
            if !pcm16.isEmpty {
                self.seedASRClient.appendPCM16Samples(pcm16)
            }
        }
    }

    private func startStreamingInternal(
        localeIdentifier: String = "auto",
        contextualStrings: [String] = [],
        dialogContext: [String] = []
    ) throws {
        idleHardwareShutdownWorkItem?.cancel()
        idleHardwareShutdownWorkItem = nil
        liveTimer?.cancel()
        liveTimer = nil
        cloudWatchdogTimer?.cancel()
        cloudWatchdogTimer = nil
        fallbackRequest?.endAudio()
        fallbackTask?.cancel()
        fallbackRequest = nil
        fallbackTask = nil

        if senseVoiceHandle == nil {
            loadSenseVoiceIfAvailable()
        }

        latestTranscript = ""
        sessionStartTime = Date()

        let cleanSpeechKey = volcSpeechAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanOpenAIKey = openAIASRAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let wantCloudSeedASR = (asrProvider == .volcSeedASR) && !cleanSpeechKey.isEmpty
        let wantOpenAIASR = (asrProvider == .openAIWhisper) && (!cleanOpenAIKey.isEmpty || PolishEngine.isKeylessLocalEndpoint(openAIASRBaseURL))
        let hasLocalSenseVoice = isUsingSenseVoice && (senseVoiceHandle != nil)

        if wantCloudSeedASR || wantOpenAIASR || hasLocalSenseVoice {
            let recordingFormat = try ensureHotMicRunning()
            let hwRate = Int32(recordingFormat.sampleRate)

            if wantCloudSeedASR,
               let monoFloatFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: recordingFormat.sampleRate, channels: 1, interleaved: false),
               let targetFmt = pcm16TargetFormat {
                if pcm16SourceFormat?.sampleRate != monoFloatFmt.sampleRate || pcm16Converter == nil {
                    pcm16SourceFormat = monoFloatFmt
                    pcm16Converter = AVAudioConverter(from: monoFloatFmt, to: targetFmt)
                } else {
                    pcm16Converter?.reset()
                }
            }

            let maxBackupSamples = Int(hwRate) * (wantOpenAIASR ? 180 : 90)
            let isAnyCloudMode = wantCloudSeedASR || wantOpenAIASR

            if wantCloudSeedASR {
                seedASRClient.startSession(
                    apiKey: cleanSpeechKey,
                    hotwords: contextualStrings,
                    dialogContext: dialogContext
                )
            } else if wantOpenAIASR {
                openAIASRClient.prewarmConnection(baseURL: openAIASRBaseURL, apiKey: cleanOpenAIKey)
            }

            // Seamlessly prepend up to 180ms of hot-standby pre-roll audio so the opening syllable is 100% preserved!
            let maxInjectSamples = max(800, Int(Double(hwRate) * 0.18))
            sampleLock.lock()
            let preRollToInject: [Float] = preRollSamples.count > maxInjectSamples
                ? Array(preRollSamples.suffix(maxInjectSamples))
                : preRollSamples
            preRollSamples.removeAll(keepingCapacity: true)

            activeMaxBackupSamples = maxBackupSamples
            activeSessionUsesCloudSeedASR = wantCloudSeedASR
            activeSessionUsesOpenAIASR = wantOpenAIASR
            openAIActiveHotwords = wantOpenAIASR ? contextualStrings : []
            openAIActiveLocale = localeIdentifier
            activeSegmentSamples.removeAll(keepingCapacity: true)
            activeSegmentSamples.reserveCapacity(wantOpenAIASR ? 0 : Int(hwRate) * 14)
            cloudFailoverBackupSamples.removeAll(keepingCapacity: true)
            if isAnyCloudMode {
                cloudFailoverBackupSamples.reserveCapacity(Int(hwRate) * 20)
            }
            if !preRollToInject.isEmpty {
                if !wantOpenAIASR {
                    activeSegmentSamples.append(contentsOf: preRollToInject)
                }
                if isAnyCloudMode {
                    cloudFailoverBackupSamples.append(contentsOf: preRollToInject)
                }
            }
            frozenTranscriptPrefix = ""
            currentSampleRate = hwRate
            lastDecodedSampleCount = 0
            lastDecodedVoiceSampleMark = 0
            totalVoiceSamplesInSegment = 0
            isDecodingChunk = false
            hasDetectedSpeechInSegment = false
            hasDetectedSpeechOverall = false
            didFlushMicroPauseTail = false
            consecutiveSilentSamples = 0
            isCaptureActive = true
            sampleLock.unlock()

            if wantCloudSeedASR && !preRollToInject.isEmpty {
                let prePCM16 = Self.resampleFloatTo16kHzInt16(preRollToInject, sourceRate: Double(hwRate))
                if !prePCM16.isEmpty {
                    seedASRClient.appendPCM16Samples(prePCM16)
                }
            }

            if wantCloudSeedASR {
                startCloudWatchdogLoop()
            } else if !wantOpenAIASR {
                startContinuousVADStreamingLoop()
            }
            return
        }

        // Fallback: macOS speech recognition, on this Mac only. It is used when no speech model is installed, and it never goes
        // to Apple's servers: if macOS cannot recognize speech on-device here, dictation stops with a pointer to the speech
        // models in Settings. Checked before the microphone is touched.
        let trimmedLoc = localeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = (trimmedLoc.isEmpty || trimmedLoc.lowercased() == "auto")
            ? SFSpeechRecognizer()
            : (SFSpeechRecognizer(locale: Locale(identifier: trimmedLoc)) ?? SFSpeechRecognizer())
        let fallbackFailure = Self.appleFallbackFailure(
            isAvailable: candidate?.isAvailable ?? false,
            supportsOnDeviceRecognition: candidate?.supportsOnDeviceRecognition ?? false
        )
        guard fallbackFailure == nil, let recognizer = candidate else {
            let message = (fallbackFailure ?? DictationFailure.onDeviceSpeechUnavailable).detail
            throw NSError(domain: "TypeZero.ASR", code: -3, userInfo: [NSLocalizedDescriptionKey: message])
        }

        shutdownAudioHardwareCompletely()
        let engine = AVAudioEngine()
        self.audioEngine = engine
        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            throw NSError(domain: "TypeZero.ASR", code: -2, userInfo: [NSLocalizedDescriptionKey: "Microphone input is unavailable. Check microphone permissions."])
        }
        self.fallbackRecognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        Self.configureAppleFallbackRequest(request, contextualStrings: contextualStrings)
        self.fallbackRequest = request

        inputNode.installTap(onBus: 0, bufferSize: 512, format: recordingFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.fallbackRequest?.append(buffer)
            let (level, _) = Self.calculateRMSMetrics(buffer: buffer)
            AudioLevelBus.shared.push(level)
        }

        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }

        fallbackTask = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let self, let result else { return }
            let text = result.bestTranscription.formattedString
            if !text.isEmpty {
                DispatchQueue.main.async {
                    self.latestTranscript = text
                    self.onPartialResult?(text, false)
                }
            }
        }
    }

    private func startCloudWatchdogLoop() {
        cloudWatchdogTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        timer.schedule(deadline: .now() + .milliseconds(110), repeating: .milliseconds(110), leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            self?.processCloudWatchdogTick()
        }
        self.cloudWatchdogTimer = timer
        timer.resume()
    }

    private func processCloudWatchdogTick() {
        sampleLock.lock()
        guard activeSessionUsesCloudSeedASR else {
            sampleLock.unlock()
            return
        }
        let sr = max(1, Int(currentSampleRate))
        let silenceSeconds = Double(consecutiveSilentSamples) / Double(sr)
        let activeVoiceSeconds = Double(totalVoiceSamplesInSegment) / Double(sr)
        let shouldFlushTail = hasDetectedSpeechOverall && silenceSeconds >= 0.20 && !didFlushMicroPauseTail
        if shouldFlushTail {
            didFlushMicroPauseTail = true
        }
        sampleLock.unlock()

        // Dead-Wi-Fi / Captive Portal Blackhole Guard: if >= 1.5s of voice elapsed with zero server packets, fail over to local FP32!
        if activeVoiceSeconds >= 1.50 && !seedASRClient.hasReceivedAnyServerFrame && senseVoiceHandle != nil {
            switchActiveSessionFromCloudToLocalFP32(reason: "the network timed out (no audio lost)")
            return
        }

        if shouldFlushTail {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.audioEngine?.isRunning == true, !self.latestTranscript.isEmpty else { return }
                self.onPartialResult?(self.latestTranscript, true)
            }
        }
    }

    private func switchActiveSessionFromCloudToLocalFP32(reason: String) {
        sampleLock.lock()
        guard activeSessionUsesCloudSeedASR else {
            sampleLock.unlock()
            return
        }
        activeSessionUsesCloudSeedASR = false
        // Restore full utterance captured so far into activeSegmentSamples so local SenseVoice FP32 loses zero syllables!
        if !cloudFailoverBackupSamples.isEmpty {
            activeSegmentSamples = cloudFailoverBackupSamples
            cloudFailoverBackupSamples.removeAll(keepingCapacity: false)
        }
        sampleLock.unlock()

        cloudWatchdogTimer?.cancel()
        cloudWatchdogTimer = nil
        seedASRClient.stopAndReset()

        if senseVoiceHandle != nil && audioEngine?.isRunning == true {
            startContinuousVADStreamingLoop()
        }
        DispatchQueue.main.async { [weak self] in
            self?.onCloudFailoverNotice?(reason)
        }
    }

    private func convertMonoFloatTo16kHzPCM16(
        channel0: UnsafePointer<Float>,
        count: Int,
        rawRMS: Float,
        isVoice: Bool
    ) -> [Int16] {
        guard let converter = pcm16Converter,
              let srcFmt = pcm16SourceFormat,
              let dstFmt = pcm16TargetFormat,
              let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: AVAudioFrameCount(count)),
              let srcData = srcBuf.floatChannelData?[0] else {
            return []
        }
        srcBuf.frameLength = AVAudioFrameCount(count)
        if enableWhisperAGC && isVoice && rawRMS > 0.0018 && rawRMS < 0.045 {
            let gain = min(4.5, max(1.0, 0.065 / rawRMS))
            for i in 0..<count {
                let v = channel0[i] * gain
                srcData[i] = (v > 0.65 || v < -0.65) ? tanh(v) : v
            }
        } else {
            srcData.update(from: channel0, count: count)
        }

        let outCap = AVAudioFrameCount(ceil(Double(count) * 16_000.0 / srcFmt.sampleRate) + 16)
        guard let dstBuf = AVAudioPCMBuffer(pcmFormat: dstFmt, frameCapacity: outCap) else { return [] }

        var didSupply = false
        var convErr: NSError?
        converter.convert(to: dstBuf, error: &convErr) { _, outStatus in
            if !didSupply {
                didSupply = true
                outStatus.pointee = .haveData
                return srcBuf
            }
            outStatus.pointee = .noDataNow
            return nil
        }
        guard convErr == nil, dstBuf.frameLength > 0, let int16Ptr = dstBuf.int16ChannelData?[0] else {
            return []
        }
        return Array(UnsafeBufferPointer(start: int16Ptr, count: Int(dstBuf.frameLength)))
    }

    public static func resampleFloatTo16kHzInt16(_ samples: [Float], sourceRate: Double) -> [Int16] {
        guard !samples.isEmpty,
              let srcFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceRate, channels: 1, interleaved: false),
              let dstFmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: srcFmt, to: dstFmt),
              let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: AVAudioFrameCount(samples.count)),
              let srcData = srcBuf.floatChannelData?[0] else {
            return []
        }
        srcBuf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { ptr in
            if let base = ptr.baseAddress {
                srcData.update(from: base, count: samples.count)
            }
        }
        let outCap = AVAudioFrameCount(ceil(Double(samples.count) * 16_000.0 / sourceRate) + 32)
        guard let dstBuf = AVAudioPCMBuffer(pcmFormat: dstFmt, frameCapacity: outCap) else { return [] }
        var supplied = false
        var err: NSError?
        converter.convert(to: dstBuf, error: &err) { _, outStatus in
            if !supplied {
                supplied = true
                outStatus.pointee = .haveData
                return srcBuf
            }
            outStatus.pointee = .endOfStream
            return nil
        }
        guard err == nil, dstBuf.frameLength > 0, let int16Ptr = dstBuf.int16ChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: int16Ptr, count: Int(dstBuf.frameLength)))
    }

    private func startContinuousVADStreamingLoop() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        // 58ms ultra-responsive cadence (first tick at 46ms) on pre-decimated 16kHz buffer (~15ms inference)!
        timer.schedule(deadline: .now() + .milliseconds(46), repeating: .milliseconds(58), leeway: .milliseconds(3))
        timer.setEventHandler { [weak self] in
            self?.processActiveWindowAndVAD()
        }
        self.liveTimer = timer
        timer.resume()
    }

    /// Minimum amount of NEW audio (in samples at `sampleRate`) that must arrive before the live preview re-decodes the active segment.
    /// SenseVoice decodes in ~15 ms, so a ~55 ms step keeps its preview feeling instant. Parakeet needs 0.05-0.33 s per decode of the
    /// whole active segment: with a 55 ms step it would decode back-to-back for the entire utterance, and the final decode after key
    /// release would queue behind an in-flight preview decode on the single decode queue. ~0.35 s of new audio keeps that queue mostly idle.
    static func livePreviewMinStepSamples(sampleRate: Int, model: LocalASRModel?) -> Int {
        let sr = max(1, sampleRate)
        if model == .parakeetTDTv2 {
            return sr * 7 / 20   // 0.35 s, in integer math so 48 kHz gives exactly 16_800 samples
        }
        return sr / 18           // ~55 ms
    }

    /// Core VAD + Sliding Segment Engine:
    /// 1. Releases the withheld final character immediately on a >=180ms micro-pause so sentence endings never hang!
    /// 2. Seals & flushes `activeSegmentSamples` on >=420ms breath pause (or >=6.8s with >=150ms micro-pause) so active window stays <6.8s (~15ms constant inference!).
    private func processActiveWindowAndVAD() {
        guard let handle = senseVoiceHandle else { return }

        sampleLock.lock()
        if isDecodingChunk {
            sampleLock.unlock()
            return
        }

        let sr = Int(currentSampleRate)
        let totalSamples = activeSegmentSamples.count
        let segmentSeconds = Double(totalSamples) / Double(max(1, sr))
        let silenceSeconds = Double(consecutiveSilentSamples) / Double(max(1, sr))

        // Keep full 5s–9s clauses intact so SenseVoice's bidirectional attention resolves homophones using full-sentence context!
        // Only seal & flush when clause is >= 4.8s with a clear >= 0.72s sentence-end pause (or >= 9.5s with a >= 0.25s pause).
        let shouldCommitAndFlushSegment = hasDetectedSpeechInSegment && (
            (segmentSeconds >= 4.8 && silenceSeconds >= 0.72) ||
            (segmentSeconds >= 9.5 && silenceSeconds >= 0.25) ||
            (segmentSeconds >= 14.5)
        )

        if shouldCommitAndFlushSegment {
            isDecodingChunk = true
            let segmentToSeal = activeSegmentSamples
            let sampleRateC = currentSampleRate
            let wasLongPause = silenceSeconds >= 0.72

            let tailKeep = min(totalSamples, sr / 10)
            activeSegmentSamples = Array(activeSegmentSamples.suffix(tailKeep))
            lastDecodedSampleCount = 0
            lastDecodedVoiceSampleMark = 0
            totalVoiceSamplesInSegment = 0
            hasDetectedSpeechInSegment = false
            didFlushMicroPauseTail = false
            consecutiveSilentSamples = 0
            sampleLock.unlock()

            let agc = self.enableWhisperAGC
            decodeQueue.async { [weak self] in
                guard let self else { return }
                let segText = Self.runSenseVoice(handle: handle, samples: segmentToSeal, sampleRate: sampleRateC, applyWhisperAGC: agc)

                self.sampleLock.lock()
                if !segText.isEmpty {
                    self.frozenTranscriptPrefix = Self.joinTranscriptFragments(self.frozenTranscriptPrefix, segText)
                    // Preserve acoustic pause cue for downstream LLM paragraph/list structuring if the model didn't append punctuation
                    if wasLongPause, let last = segText.last, !"。！？；，,.;!?".contains(last) {
                        // Parakeet (English) gets an ASCII comma; SenseVoice keeps the original full-width one.
                        self.frozenTranscriptPrefix += (self.activeLocalModel == .parakeetTDTv2) ? "," : "，"
                    }
                }
                let fullCombined = self.frozenTranscriptPrefix
                self.isDecodingChunk = false
                self.sampleLock.unlock()

                if !fullCombined.isEmpty {
                    DispatchQueue.main.async {
                        guard self.audioEngine?.isRunning == true else { return }
                        self.latestTranscript = fullCombined
                        self.onPartialResult?(fullCombined, true)
                    }
                }
            }
            return
        }

        // Micro-pause tail flush (>=185ms silence): immediately push the withheld last character to the typewriter without waiting 420ms!
        if hasDetectedSpeechInSegment && silenceSeconds >= 0.185 && !didFlushMicroPauseTail && !latestTranscript.isEmpty {
            didFlushMicroPauseTail = true
            let cached = latestTranscript
            sampleLock.unlock()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.audioEngine?.isRunning == true else { return }
                self.onPartialResult?(cached, true)
            }
            return
        }

        // Ongoing active speech within current short segment: decode a live preview whenever enough NEW audio arrived
        // (~55ms for SenseVoice, ~0.35s for Parakeet; see `livePreviewMinStepSamples`).
        let minStep = Self.livePreviewMinStepSamples(sampleRate: sr, model: activeLocalModel)
        guard hasDetectedSpeechInSegment,
              totalSamples >= sr / 9,
              (totalSamples - lastDecodedSampleCount) >= minStep else {
            sampleLock.unlock()
            return
        }

        isDecodingChunk = true
        lastDecodedSampleCount = totalSamples
        let voiceMarkSnapshot = totalVoiceSamplesInSegment
        let snapshot = activeSegmentSamples
        let prefixCopy = frozenTranscriptPrefix
        let sampleRateC = currentSampleRate
        sampleLock.unlock()

        let agc = self.enableWhisperAGC
        decodeQueue.async { [weak self] in
            guard let self else { return }
            let activeText = Self.runSenseVoice(handle: handle, samples: snapshot, sampleRate: sampleRateC, applyWhisperAGC: agc)

            self.sampleLock.lock()
            let latestFrozen = self.frozenTranscriptPrefix
            if latestFrozen == prefixCopy {
                self.lastDecodedVoiceSampleMark = voiceMarkSnapshot
            }
            self.isDecodingChunk = false
            self.sampleLock.unlock()

            guard latestFrozen == prefixCopy, !activeText.isEmpty else { return }
            let combined = Self.joinTranscriptFragments(latestFrozen, activeText)

            DispatchQueue.main.async {
                guard self.audioEngine?.isRunning == true else { return }
                if combined != self.latestTranscript {
                    self.latestTranscript = combined
                    self.onPartialResult?(combined, false)
                }
            }
        }
    }

    private func takeCloudFinishSnapshot() -> (wasVolcCloud: Bool, wasOpenAICloud: Bool, hadSpeech: Bool, backup: [Float], sr: Int32, hotwords: [String], locale: String) {
        sampleLock.lock()
        defer { sampleLock.unlock() }
        let wasVolc = activeSessionUsesCloudSeedASR
        let wasOpenAI = activeSessionUsesOpenAIASR
        activeSessionUsesCloudSeedASR = false
        activeSessionUsesOpenAIASR = false
        let hadAnySpeech = hasDetectedSpeechOverall
        let backupSamples = cloudFailoverBackupSamples
        let backupSR = currentSampleRate
        let hw = openAIActiveHotwords
        let loc = openAIActiveLocale
        openAIActiveHotwords = []
        cloudFailoverBackupSamples.removeAll(keepingCapacity: false)
        return (wasVolc, wasOpenAI, hadAnySpeech, backupSamples, backupSR, hw, loc)
    }

    public func finishStreaming() async -> (transcript: String, duration: Double) {
        let elapsed = Date().timeIntervalSince(sessionStartTime)
        liveTimer?.cancel()
        liveTimer = nil
        cloudWatchdogTimer?.cancel()
        cloudWatchdogTimer = nil
        AudioLevelBus.shared.reset()

        let (wasUsingVolcCloud, wasUsingOpenAICloud, hadAnySpeech, backupSamples, backupSR, openAIHotwords, openAILocale) = takeCloudFinishSnapshot()

        audioControlQueue.async { [weak self] in
            self?.pauseActiveTapOnly()
        }

        if wasUsingOpenAICloud {
            guard hadAnySpeech, backupSamples.count > Int(backupSR) / 8 else {
                clearSessionBuffers()
                return ("", elapsed)
            }

            let baseURL = self.openAIASRBaseURL
            let model = self.openAIASRModel
            let apiKey = self.openAIASRAPIKey
            let agc = self.enableWhisperAGC

            let wavData: Data = await withCheckedContinuation { cont in
                decodeQueue.async {
                    let conditioned = agc ? Self.boostQuietSpeechAGC(backupSamples) : backupSamples
                    let pcm16 = Self.resampleFloatTo16kHzInt16(conditioned, sourceRate: Double(backupSR))
                    let wav = OpenAITranscriptionClient.encodePCM16ToWAV(pcm16, sampleRate: 16_000)
                    cont.resume(returning: wav)
                }
            }

            let dynamicTimeout = max(6.5, min(14.0, elapsed * 0.45 + 5.5))
            do {
                let (cloudText, _) = try await openAIASRClient.transcribe(
                    wavData: wavData,
                    baseURL: baseURL,
                    model: model,
                    apiKey: apiKey,
                    hotwords: openAIHotwords,
                    languageLocale: openAILocale,
                    timeoutSeconds: dynamicTimeout
                )
                let trimmed = cloudText.trimmingCharacters(in: .whitespacesAndNewlines)
                clearSessionBuffers()
                if !trimmed.isEmpty {
                    return (trimmed, elapsed)
                }
            } catch {
                // Seamless Zero-Word-Loss Failover to Local 886MB SenseVoice FP32 if offline / timeout / API error!
                if isUsingSenseVoice, let handle = senseVoiceHandle, backupSamples.count > Int(backupSR) / 10 {
                    let handleBits = Int(bitPattern: handle)
                    let localFallback: String = await withCheckedContinuation { cont in
                        decodeQueue.async {
                            guard let ptr = OpaquePointer(bitPattern: handleBits) else {
                                cont.resume(returning: "")
                                return
                            }
                            let txt = Self.runSenseVoice(handle: ptr, samples: backupSamples, sampleRate: backupSR, applyWhisperAGC: agc)
                            cont.resume(returning: txt)
                        }
                    }
                    clearSessionBuffers()
                    if !localFallback.isEmpty {
                        let shortErr = error.localizedDescription
                        DispatchQueue.main.async { [weak self] in
                            self?.onCloudFailoverNotice?("the cloud speech service returned an error (\(shortErr))")
                        }
                        return (localFallback, elapsed)
                    }
                }
                let errMsg = error.localizedDescription
                clearSessionBuffers()
                DispatchQueue.main.async { [weak self] in
                    self?.onError?("Cloud speech recognition failed: \(errMsg)")
                }
                return ("", elapsed)
            }

            clearSessionBuffers()
            return ("", elapsed)
        }

        if wasUsingVolcCloud {
            if !hadAnySpeech && latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                seedASRClient.stopAndReset()
                clearSessionBuffers()
                return ("", elapsed)
            }

            if let cloudFinal = await seedASRClient.finishAndAwaitFinalTranscript(timeoutMs: 1200),
               !cloudFinal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                clearSessionBuffers()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(120)) { [weak self] in
                    self?.prewarmCloudSocketIfReady()
                }
                return (cloudFinal.trimmingCharacters(in: .whitespacesAndNewlines), elapsed)
            }

            // Seamless Offline/Drop Failover: run local 886MB SenseVoice FP32 on full backup buffer so zero words are lost!
            if hadAnySpeech, isUsingSenseVoice, let handle = senseVoiceHandle, backupSamples.count > Int(backupSR) / 10 {
                let handleBits = Int(bitPattern: handle)
                let agc = self.enableWhisperAGC
                let localFallback: String = await withCheckedContinuation { cont in
                    decodeQueue.async {
                        guard let ptr = OpaquePointer(bitPattern: handleBits) else {
                            cont.resume(returning: "")
                            return
                        }
                        let txt = Self.runSenseVoice(handle: ptr, samples: backupSamples, sampleRate: backupSR, applyWhisperAGC: agc)
                        cont.resume(returning: txt)
                    }
                }
                clearSessionBuffers()
                if !localFallback.isEmpty {
                    DispatchQueue.main.async { [weak self] in
                        self?.onCloudFailoverNotice?("the cloud speech response timed out")
                    }
                    return (localFallback, elapsed)
                }
            }
            let partialCached = latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            clearSessionBuffers()
            return (partialCached, elapsed)
        }

        if isUsingSenseVoice, let handle = senseVoiceHandle {
            let (remainingSamples, needsTailDecode, cachedFull, sr) = takeFinalSnapshotAndCheckZeroWait()
            // Zero-Wait Instant Return: if no new speech frames arrived since the last 72ms live decode, return in 0ms!
            if !needsTailDecode && !cachedFull.isEmpty {
                clearSessionBuffers()
                return (cachedFull, elapsed)
            }

            let handleBits = Int(bitPattern: handle)
            let finalCombined: String = await withCheckedContinuation { continuation in
                decodeQueue.async { [weak self] in
                    guard let self, let ptr = OpaquePointer(bitPattern: handleBits) else {
                        continuation.resume(returning: cachedFull)
                        return
                    }
                    var tailText = ""
                    if needsTailDecode && remainingSamples.count > Int(sr) / 10 {
                        tailText = Self.runSenseVoice(handle: ptr, samples: remainingSamples, sampleRate: sr, applyWhisperAGC: self.enableWhisperAGC)
                    }
                    let prefix = self.readAndClearFrozenPrefix()
                    let merged = Self.joinTranscriptFragments(prefix, tailText).trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: merged.isEmpty ? cachedFull : merged)
                }
            }
            clearSessionBuffers()
            return (finalCombined, elapsed)
        }

        fallbackRequest?.endAudio()
        try? await Task.sleep(nanoseconds: 35_000_000)
        let finalString = latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        clearSessionBuffers()
        return (finalString, elapsed)
    }

    private func takeFinalSnapshotAndCheckZeroWait() -> ([Float], Bool, String, Int32) {
        sampleLock.lock()
        defer { sampleLock.unlock() }
        let samples = activeSegmentSamples
        let sr = currentSampleRate
        let undecodedVoiceSamples = totalVoiceSamplesInSegment - lastDecodedVoiceSampleMark
        // Only run final SenseVoice pass if >60ms of new voice arrived after the last streaming tick!
        let needsDecode = hasDetectedSpeechInSegment && (undecodedVoiceSamples > Int(sr) / 16 || latestTranscript.isEmpty)
        let cached = latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        activeSegmentSamples.removeAll(keepingCapacity: false)
        hasDetectedSpeechInSegment = false
        lastDecodedVoiceSampleMark = 0
        totalVoiceSamplesInSegment = 0
        return (samples, needsDecode, cached, sr)
    }

    private func readAndClearFrozenPrefix() -> String {
        sampleLock.lock()
        defer { sampleLock.unlock() }
        let p = frozenTranscriptPrefix
        frozenTranscriptPrefix = ""
        return p
    }

    /// Joins two consecutive ASR fragments. CJK text is concatenated directly (no inter-word spaces);
    /// Latin text (Parakeet / English) gets exactly one space so segment boundaries never glue sentences together ("done.Next").
    static func joinTranscriptFragments(_ prefix: String, _ next: String) -> String {
        guard let last = prefix.last, let first = next.first else { return prefix + next }
        if last.isWhitespace || first.isWhitespace { return prefix + next }
        if isCJKOrFullWidth(last) || isCJKOrFullWidth(first) { return prefix + next }
        // Closing punctuation hugs the previous word ("done" + "." -> "done.").
        if ",.;:!?)]}%".contains(first) { return prefix + next }
        return prefix + " " + next
    }

    static func isCJKOrFullWidth(_ ch: Character) -> Bool {
        guard let v = ch.unicodeScalars.first?.value else { return false }
        return (v >= 0x2E80 && v <= 0x9FFF)      // CJK radicals, punctuation, kana, ideographs
            || (v >= 0xAC00 && v <= 0xD7AF)      // Hangul syllables
            || (v >= 0xFF00 && v <= 0xFFEF)      // Full-width forms (，。！？)
    }

    /// Generic decode entry for whichever local model owns `handle` (Parakeet or SenseVoice).
    static func runSenseVoice(handle: OpaquePointer, samples: [Float], sampleRate: Int32, applyWhisperAGC: Bool = true) -> String {
        guard !samples.isEmpty else { return "" }
        let processed = applyWhisperAGC ? boostQuietSpeechAGC(samples) : samples
        return processed.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress,
                  let cStr = tz_sensevoice_transcribe(handle, base, Int32(ptr.count), sampleRate) else {
                return ""
            }
            defer { tz_sensevoice_free_string(cStr) }
            return String(cString: cStr).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// P5: Wispr-Flow-style Soft-Knee Automatic Gain Control (Whisper Mode).
    /// Linearly boosts low-volume 25dB whispers up to 7.5x with tanh soft-limiting so loud speech never clips!
    private static func boostQuietSpeechAGC(_ samples: [Float]) -> [Float] {
        var sumSq: Float = 0
        var activeCount: Int = 0
        let strideStep = max(1, samples.count / 2000)

        for i in stride(from: 0, to: samples.count, by: strideStep) {
            let v = abs(samples[i])
            if v > 0.0015 {
                sumSq += v * v
                activeCount += 1
            }
        }
        guard activeCount > 12 else { return samples }
        let activeRMS = sqrt(sumSq / Float(activeCount))

        // Normal speech RMS is ~0.07–0.18; if already strong (>= 0.065), zero overhead pass-through!
        guard activeRMS < 0.065 else { return samples }

        let targetRMS: Float = 0.085
        let gain = min(7.5, max(1.0, targetRMS / max(activeRMS, 0.0018)))
        guard gain > 1.15 else { return samples }

        var boosted = [Float](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            let amplified = samples[i] * gain
            // Fast rational soft-clipper approximating tanh(x) so plosives never harsh-clip above [-0.98, 0.98]
            if amplified > 0.6 || amplified < -0.6 {
                boosted[i] = tanh(amplified)
            } else {
                boosted[i] = amplified
            }
        }
        return boosted
    }

    public func cancel() {
        liveTimer?.cancel()
        liveTimer = nil
        cloudWatchdogTimer?.cancel()
        cloudWatchdogTimer = nil
        seedASRClient.stopAndReset()
        AudioLevelBus.shared.reset()
        clearSessionBuffers()
        audioControlQueue.async { [weak self] in
            self?.pauseActiveTapOnly()
        }
    }

    private func pauseActiveTapOnly() {
        liveTimer?.cancel()
        liveTimer = nil
        cloudWatchdogTimer?.cancel()
        cloudWatchdogTimer = nil
        sampleLock.lock()
        isCaptureActive = false
        preRollSamples.removeAll(keepingCapacity: true)
        sampleLock.unlock()
        fallbackRequest?.endAudio()
        fallbackTask?.cancel()
        fallbackRequest = nil
        fallbackTask = nil

        // Keep CoreAudio mic warm for 15s for instant 0ms back-to-back dictation;
        // auto-shutdown after 15s of inactivity so the macOS orange mic indicator turns off cleanly.
        scheduleIdleHardwareShutdown()
    }

    private func scheduleIdleHardwareShutdown() {
        idleHardwareShutdownWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.sampleLock.lock()
            let capturing = self.isCaptureActive
            self.sampleLock.unlock()
            guard !capturing else { return }
            self.shutdownAudioHardwareCompletely()
        }
        idleHardwareShutdownWorkItem = work
        audioControlQueue.asyncAfter(deadline: .now() + hotMicKeepAliveSeconds, execute: work)
    }

    private func shutdownAudioHardwareCompletely() {
        idleHardwareShutdownWorkItem?.cancel()
        idleHardwareShutdownWorkItem = nil
        sampleLock.lock()
        isCaptureActive = false
        preRollSamples.removeAll(keepingCapacity: false)
        sampleLock.unlock()
        if let engine = audioEngine {
            if engine.isRunning {
                engine.stop()
            }
            engine.inputNode.removeTap(onBus: 0)
            engine.prepare()
        }
        isTapInstalled = false
        pcm16Converter = nil
    }

    private func clearSessionBuffers() {
        sampleLock.lock()
        activeSessionUsesCloudSeedASR = false
        activeSessionUsesOpenAIASR = false
        openAIActiveHotwords = []
        activeSegmentSamples.removeAll(keepingCapacity: true)
        cloudFailoverBackupSamples.removeAll(keepingCapacity: false)
        frozenTranscriptPrefix = ""
        hasDetectedSpeechInSegment = false
        hasDetectedSpeechOverall = false
        consecutiveSilentSamples = 0
        sampleLock.unlock()
    }

    private static func calculateRMSMetrics(buffer: AVAudioPCMBuffer) -> (normalized: Float, rawRMS: Float) {
        guard let channelData = buffer.floatChannelData?[0] else { return (0.05, 0.0) }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return (0.05, 0.0) }

        var sum: Float = 0
        var count: Int = 0
        for i in stride(from: 0, to: frameLength, by: 4) {
            let sample = channelData[i]
            sum += sample * sample
            count += 1
        }
        let rms = sqrt(sum / Float(max(1, count)))
        let db = 20 * log10(max(rms, 0.000_1))
        let norm = max(0.06, min(1.0, (db + 50) / 42))
        return (norm, rms)
    }
}
