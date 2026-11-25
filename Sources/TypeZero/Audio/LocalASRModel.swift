import Foundation

/// Fully offline speech-recognition models the app can run through sherpa-onnx.
///
/// The raw values are persisted inside `config.json` (`LLMConfig.localASRModel`) — never rename them.
public enum LocalASRModel: String, CaseIterable, Codable, Identifiable, Sendable {
    /// NVIDIA Parakeet TDT 0.6B v2 (English only, int8). Output is already punctuated and cased.
    case parakeetTDTv2 = "parakeetTDTv2"
    /// Multilingual SenseVoice-Small (zh / en / ja / ko / yue), lossless FP32 weights.
    case senseVoice = "senseVoice"

    public var id: String { rawValue }

    /// Selection used by fresh configs and by configs saved before this setting existed.
    public static let `default`: LocalASRModel = .parakeetTDTv2

    // MARK: Display

    public var displayName: String {
        switch self {
        case .parakeetTDTv2: return "Parakeet TDT 0.6B v2 (English)"
        case .senseVoice: return "SenseVoice-Small (multilingual)"
        }
    }

    public var shortName: String {
        switch self {
        case .parakeetTDTv2: return "Parakeet v2"
        case .senseVoice: return "SenseVoice"
        }
    }

    /// One-line description shown in Settings.
    public var detail: String {
        switch self {
        case .parakeetTDTv2:
            return "English only · int8 · punctuation and casing built in · ~\(approxDownloadMB) MB download"
        case .senseVoice:
            return "Chinese / English / Japanese / Korean / Cantonese · FP32 · ~\(approxDownloadMB) MB download"
        }
    }

    // MARK: Download spec

    public var approxDownloadMB: Int {
        switch self {
        case .parakeetTDTv2: return 482
        case .senseVoice: return 886
        }
    }

    private var releaseArchiveURLString: String {
        switch self {
        case .parakeetTDTv2:
            return "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2"
        case .senseVoice:
            return "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2025-09-09.tar.bz2"
        }
    }

    /// Where the archive comes from: the official sherpa-onnx GitHub release and nothing else (no mirror or proxy).
    public var downloadURLStrings: [String] {
        [releaseArchiveURLString]
    }

    /// SHA-256 (lowercase hex) of the release archive, taken from GitHub's release API. The downloader hashes the
    /// archive and refuses to extract it unless it matches (`ArchiveChecksum`).
    public var archiveSHA256: String {
        switch self {
        case .parakeetTDTv2: return "6fc4426b54aa549a0019b8a75b8dea59164e71790a37ac56a045ad57f915f714"   // 482,440,461 bytes
        case .senseVoice: return "bce28acdb0fb3a5b1e0b93f8b202e904ea1d2eca4f3a4c0cd5006626f10d540e"   // 886,547,748 bytes
        }
    }

    /// Folder created by extracting the archive inside `Models/`.
    public var extractedFolderName: String {
        switch self {
        case .parakeetTDTv2: return "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8"
        case .senseVoice: return "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2025-09-09"
        }
    }

    /// Files that must exist inside `extractedFolderName` for a download to count as complete.
    public var requiredFileNames: [String] {
        switch self {
        case .parakeetTDTv2: return ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"]
        case .senseVoice: return ["model.onnx", "tokens.txt"]
        }
    }

    /// Temporary archive name used while downloading (inside `Models/`).
    public var downloadArchiveFileName: String {
        "\(rawValue)-download.tar.bz2"
    }

    // MARK: Install detection

    /// `~/Library/Application Support/Nevertype/Models`
    public static func defaultModelsRoot() -> URL {
        AppBrand.applicationSupportDirectory().appendingPathComponent("Models", isDirectory: true)
    }

    /// Resolves the on-disk files of this model, or `nil` when it is not (fully) installed.
    public func installedFiles(modelsRoot: URL = LocalASRModel.defaultModelsRoot()) -> LocalASRModelFiles? {
        let fm = FileManager.default
        func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

        switch self {
        case .parakeetTDTv2:
            let dir = modelsRoot.appendingPathComponent(extractedFolderName, isDirectory: true)
            let encoder = dir.appendingPathComponent("encoder.int8.onnx")
            let decoder = dir.appendingPathComponent("decoder.int8.onnx")
            let joiner = dir.appendingPathComponent("joiner.int8.onnx")
            let tokens = dir.appendingPathComponent("tokens.txt")
            guard [encoder, decoder, joiner, tokens].allSatisfy(exists) else { return nil }
            return LocalASRModelFiles(
                model: self,
                modelPath: encoder.path,
                decoderPath: decoder.path,
                joinerPath: joiner.path,
                tokensPath: tokens.path,
                isFullPrecision: false
            )

        case .senseVoice:
            // Priority 1: lossless full-precision FP32 model (~930MB) for maximum acoustic & sibilant accuracy.
            let fp32Dir = modelsRoot.appendingPathComponent(extractedFolderName, isDirectory: true)
            let fp32Model = fp32Dir.appendingPathComponent("model.onnx")
            let fp32Tokens = fp32Dir.appendingPathComponent("tokens.txt")
            if exists(fp32Model) && exists(fp32Tokens) {
                return LocalASRModelFiles(
                    model: self, modelPath: fp32Model.path, decoderPath: nil, joinerPath: nil,
                    tokensPath: fp32Tokens.path, isFullPrecision: true
                )
            }
            // Priority 2: compact int8 quantized fallback (~226MB).
            let int8Dir = modelsRoot.appendingPathComponent("sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09", isDirectory: true)
            let int8Model = int8Dir.appendingPathComponent("model.int8.onnx")
            let int8Tokens = int8Dir.appendingPathComponent("tokens.txt")
            if exists(int8Model) && exists(int8Tokens) {
                return LocalASRModelFiles(
                    model: self, modelPath: int8Model.path, decoderPath: nil, joinerPath: nil,
                    tokensPath: int8Tokens.path, isFullPrecision: false
                )
            }
            return nil
        }
    }

    public func isInstalled(modelsRoot: URL = LocalASRModel.defaultModelsRoot()) -> Bool {
        installedFiles(modelsRoot: modelsRoot) != nil
    }

    /// True when at least one local model is installed (what used to be `senseVoiceModelPaths() != nil`).
    public static func anyInstalled(modelsRoot: URL = LocalASRModel.defaultModelsRoot()) -> Bool {
        allCases.contains { $0.isInstalled(modelsRoot: modelsRoot) }
    }

    /// Picks the files to load: the preferred model when installed, otherwise the other installed model, otherwise `nil`.
    public static func resolve(
        preferred: LocalASRModel,
        modelsRoot: URL = LocalASRModel.defaultModelsRoot()
    ) -> LocalASRModelFiles? {
        let ordered = [preferred] + allCases.filter { $0 != preferred }
        for candidate in ordered {
            if let files = candidate.installedFiles(modelsRoot: modelsRoot) {
                return files
            }
        }
        return nil
    }
}

/// Resolved on-disk files of an installed local model.
public struct LocalASRModelFiles: Equatable, Sendable {
    public let model: LocalASRModel
    /// SenseVoice: `model.onnx` / `model.int8.onnx`. Parakeet: the transducer encoder.
    public let modelPath: String
    /// Transducer decoder (Parakeet only).
    public let decoderPath: String?
    /// Transducer joiner (Parakeet only).
    public let joinerPath: String?
    public let tokensPath: String
    /// True only for the lossless SenseVoice FP32 weights.
    public let isFullPrecision: Bool
}
