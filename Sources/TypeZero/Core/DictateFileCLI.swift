import Foundation
import AVFoundation
import CSherpaOnnx

/// Headless end-to-end test without a microphone or any GUI:
///
///     Nevertype --dictate-file <path.wav> [--style structured|light] [--scene chat|email|notes|terminal]
///
/// Decodes the WAV with the configured local model through the same handle/bridge path the app uses (Parakeet by default),
/// then runs the text through the real `PolishEngine` dictate path with the config the app would use: the persisted
/// `config.json` if present, otherwise the fork's fresh defaults. Preceding text, recent context and lexicon are empty.
/// It never writes anything (no config, history or model files) and never starts the app.
///
/// Exit codes: 0 success · 1 setup error (file, model) · 2 usage error · 3 the LLM call failed and the raw transcript was used.
public enum DictateFileCLI {
    enum Scene: String, CaseIterable {
        case chat, email, notes, terminal

        var context: ActiveScreenContext {
            switch self {
            case .chat:
                return ActiveScreenContext(appName: "Slack", bundleID: "com.tinyspeck.slackmacgap", windowTitle: "", selectedText: "", precedingText: "")
            case .email:
                return ActiveScreenContext(appName: "Mail", bundleID: "com.apple.mail", windowTitle: "", selectedText: "", precedingText: "")
            case .notes:
                return ActiveScreenContext(appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "", selectedText: "", precedingText: "")
            case .terminal:
                return ActiveScreenContext(appName: "Terminal", bundleID: "com.apple.Terminal", windowTitle: "", selectedText: "", precedingText: "")
            }
        }
    }

    struct Options: Equatable {
        var wavPath: String
        var style: FormattingStyle?
        var scene: Scene
    }

    enum ParseOutcome {
        case options(Options)
        case help
        case failure(String)
    }

    static let usage = """
    usage: \(AppBrand.name) --dictate-file <path.wav> [--style structured|light] [--scene chat|email|notes|terminal]
      <path.wav>   16 kHz mono WAV (other rates are resampled; extra channels are ignored)
      --style      cleanup strength (default: the configured style, structured on a fresh config)
      --scene      simulated target app (default: notes)
    """

    /// `arguments` are the process arguments without the executable path.
    static func parse(arguments: [String]) -> ParseOutcome {
        if arguments.contains("--help") || arguments.contains("-h") { return .help }
        var wavPath: String?
        var style: FormattingStyle?
        var scene: Scene = .notes
        var index = 0
        func value(for flag: String) -> String? {
            index += 1
            return index < arguments.count ? arguments[index] : nil
        }
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--dictate-file":
                guard let v = value(for: arg), !v.hasPrefix("--") else { return .failure("--dictate-file needs a WAV path") }
                wavPath = v
            case "--style":
                guard let v = value(for: arg) else { return .failure("--style needs a value (structured|light)") }
                switch v {
                case "structured": style = .structured
                case "light": style = .lightPolish
                default: return .failure("unknown --style '\(v)' (use structured or light)")
                }
            case "--scene":
                guard let v = value(for: arg), let parsed = Scene(rawValue: v) else {
                    return .failure("unknown --scene (use chat, email, notes or terminal)")
                }
                scene = parsed
            case "--help", "-h":
                return .help
            default:
                return .failure("unknown argument '\(arg)'")
            }
            index += 1
        }
        guard let path = wavPath else { return .failure("missing --dictate-file <path.wav>") }
        return .options(Options(wavPath: path, style: style, scene: scene))
    }

    private final class ResultBox: @unchecked Sendable {
        var code: Int32 = 0
    }

    public static func run(arguments: [String]) -> Int32 {
        switch parse(arguments: arguments) {
        case .help:
            print(usage)
            return 0
        case .failure(let message):
            FileHandle.standardError.write(Data("error: \(message)\n\(usage)\n".utf8))
            return 2
        case .options(let options):
            let box = ResultBox()
            let done = DispatchSemaphore(value: 0)
            Task {
                box.code = await execute(options)
                done.signal()
            }
            done.wait()
            return box.code
        }
    }

    // MARK: - Pipeline

    private static func fail(_ message: String, code: Int32 = 1) -> Int32 {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        return code
    }

    /// The config the app would start with: persisted `config.json` when present and decodable, otherwise the fork defaults.
    static func loadEffectiveConfig() -> (config: LLMConfig, source: String) {
        let configURL = LocalASRModel.defaultModelsRoot()
            .deletingLastPathComponent()
            .appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: configURL),
           let decoded = try? JSONDecoder().decode(LLMConfig.self, from: data) {
            return (decoded, "persisted \(configURL.path)")
        }
        return (LLMConfig.default, "fork defaults (no persisted config.json)")
    }

    static func readWAV(path: String) throws -> (samples: [Float], sampleRate: Double, channels: Int) {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let format = file.processingFormat
        guard file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw NSError(domain: "TypeZero.CLI", code: 1, userInfo: [NSLocalizedDescriptionKey: "empty or unreadable audio"])
        }
        try file.read(into: buffer)
        guard let channel0 = buffer.floatChannelData?[0], buffer.frameLength > 0 else {
            throw NSError(domain: "TypeZero.CLI", code: 2, userInfo: [NSLocalizedDescriptionKey: "no PCM data in file"])
        }
        let samples = Array(UnsafeBufferPointer(start: channel0, count: Int(buffer.frameLength)))
        return (samples, format.sampleRate, Int(format.channelCount))
    }

    private static func ms(since start: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }

    private static func execute(_ options: Options) async -> Int32 {
        // 1. Audio
        let audio: (samples: [Float], sampleRate: Double, channels: Int)
        do {
            audio = try readWAV(path: options.wavPath)
        } catch {
            return fail("cannot read \(options.wavPath): \(error.localizedDescription)")
        }
        let durationSec = Double(audio.samples.count) / max(1, audio.sampleRate)

        // 2. Config exactly as the app would load it
        let loaded = loadEffectiveConfig()
        var config = loaded.config
        let configSource = loaded.source
        if let style = options.style {
            config.formattingStyle = style
        }

        // 3. Local ASR model through the app's own selection + handle construction
        guard let files = LocalASRModel.resolve(preferred: config.localASRModel) else {
            return fail("no local speech model installed under \(LocalASRModel.defaultModelsRoot().path) (download Parakeet or SenseVoice in Settings)")
        }
        let loadStart = DispatchTime.now()
        guard let handle = StreamingASREngine.createLocalRecognizerHandle(files: files, speechLocale: config.speechLocale) else {
            return fail("failed to load \(files.model.displayName) from \(files.modelPath)")
        }
        let loadMs = ms(since: loadStart)
        defer { tz_sensevoice_destroy(handle) }

        // One short warm-up decode (the app's recognizer is already warm from the live partials while recording).
        _ = StreamingASREngine.runSenseVoice(
            handle: handle,
            samples: [Float](repeating: 0, count: Int(audio.sampleRate * 0.4)),
            sampleRate: Int32(audio.sampleRate),
            applyWhisperAGC: false
        )
        let asrStart = DispatchTime.now()
        let rawText = StreamingASREngine.runSenseVoice(
            handle: handle,
            samples: audio.samples,
            sampleRate: Int32(audio.sampleRate),
            applyWhisperAGC: config.enableWhisperAGC
        )
        let asrMs = ms(since: asrStart)

        // 4. Cleanup LLM: same prewarm + model-load call the app issues when recording starts, awaited so a cold Ollama load
        //    cannot hit the 8s/10s cloud timeouts.
        let isLocalLLM = PolishEngine.isKeylessLocalEndpoint(config.baseURL)
        let apiKey = isLocalLLM ? "" : KeychainHelper.loadAPIKey(for: config.selectedProvider)
        let polishEngine = PolishEngine()
        polishEngine.prewarmConnection(baseURL: config.baseURL, apiKey: apiKey, model: config.modelName)
        var warmMs = 0
        if isLocalLLM {
            warmMs = await polishEngine.warmLocalModel(baseURL: config.baseURL, model: config.modelName)
        } else {
            try? await Task.sleep(nanoseconds: 180_000_000)
        }

        let context = options.scene.context
        let outcome = await polishEngine.polishWithDiagnostics(
            rawTranscript: rawText,
            mode: .dictate,
            screenContext: context,
            recalledTerms: [],
            recentOutputs: [],
            config: config,
            apiKey: apiKey,
            isHighAccuracyLocalASR: true,
            isPunctuatedCloudASR: false
        )

        // 5. Report
        let fileNote = String(format: "%.1f s, %.0f Hz, %d ch", durationSec, audio.sampleRate, audio.channels)
        print("== \(AppBrand.name) --dictate-file ==")
        print("file: \(options.wavPath) (\(fileNote))")
        print("config: \(configSource)")
        print("asr model: \(files.model.displayName) [\(files.model.rawValue)]")
        print("asr load ms: \(loadMs)")
        print("asr ms: \(asrMs) (decode after warm-up)")
        print("llm: \(config.modelName) @ \(config.baseURL)")
        print("llm style: \(config.formattingStyle.rawValue) | scene: \(options.scene.rawValue) -> \"\(context.toneProfile.rawValue)\"")
        if isLocalLLM {
            print("llm warm-up ms: \(warmMs) (Ollama model load, keep_alive -1 = stay resident)")
        }
        print("polish ms: \(outcome.totalMs) total, \(outcome.latencyMs) as the app reports it (first token)")
        print("fast path used: \(outcome.usedFastPath ? "yes" : "no") (route=\(outcome.route.rawValue))")
        if let err = outcome.llmError {
            print("llm error: \(err)")
        }
        print("----- raw ASR text -----")
        print(rawText)
        print("----- polished text -----")
        print(outcome.text)
        print("-----")

        if rawText.isEmpty {
            return fail("ASR returned empty text", code: 1)
        }
        if outcome.route == .llmFailedFallback {
            return fail("the LLM call failed (\(outcome.llmError ?? "unknown error")); the raw transcript was used", code: 3)
        }
        return 0
    }
}
