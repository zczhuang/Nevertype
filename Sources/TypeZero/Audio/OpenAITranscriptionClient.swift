import Foundation

/// Pure-Swift OpenAI-compatible Cloud Audio Transcription Client (`/v1/audio/transcriptions`).
/// Works natively with:
/// - OpenAI (`https://api.openai.com/v1`, `gpt-4o-mini-transcribe`, `gpt-4o-transcribe`, `whisper-1`)
/// - Groq (`https://api.groq.com/openai/v1`, `whisper-large-v3-turbo`, `whisper-large-v3`)
/// - Any OpenAI-compatible relay or local `whisper.cpp` server.
public final class OpenAITranscriptionClient: @unchecked Sendable {
    private let session: URLSession

    public init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 8.5
        cfg.timeoutIntervalForResource = 15.0
        cfg.waitsForConnectivity = false
        cfg.httpMaximumConnectionsPerHost = 4
        self.session = URLSession(configuration: cfg)
    }

    /// Normalizes a user-supplied base URL into the exact `/audio/transcriptions` endpoint.
    public static func normalizeTranscriptionEndpoint(_ rawBaseURL: String) -> String {
        var trimmed = rawBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            trimmed = "https://api.openai.com/v1"
        }
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        let lower = trimmed.lowercased()
        if lower.hasSuffix("/audio/transcriptions") {
            return trimmed
        }
        if lower.hasSuffix("/v1") || lower.hasSuffix("/openai/v1") || lower.contains("/v1/") {
            return trimmed + "/audio/transcriptions"
        }
        return trimmed + "/v1/audio/transcriptions"
    }

    public static func isGroqEndpoint(_ rawBaseURL: String) -> Bool {
        rawBaseURL.lowercased().contains("groq.com")
    }

    /// Encodes 16kHz mono 16-bit signed little-endian PCM into an in-memory standard 44-byte RIFF/WAVE payload (zero disk I/O).
    public static func encodePCM16ToWAV(_ pcm16: [Int16], sampleRate: Int = 16_000) -> Data {
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate: UInt32 = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign: UInt16 = numChannels * (bitsPerSample / 8)
        let dataSize: UInt32 = UInt32(pcm16.count * MemoryLayout<Int16>.size)
        let chunkSize: UInt32 = 36 + dataSize

        var wav = Data(capacity: 44 + Int(dataSize))

        func appendASCII(_ str: String) {
            wav.append(contentsOf: str.utf8)
        }
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { wav.append(contentsOf: $0) }
        }

        appendASCII("RIFF")
        appendLE(chunkSize)
        appendASCII("WAVE")

        appendASCII("fmt ")
        appendLE(UInt32(16))               // Subchunk1Size for PCM
        appendLE(UInt16(1))                // AudioFormat = 1 (PCM)
        appendLE(numChannels)
        appendLE(UInt32(sampleRate))
        appendLE(byteRate)
        appendLE(blockAlign)
        appendLE(bitsPerSample)

        appendASCII("data")
        appendLE(dataSize)

        pcm16.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            let raw = UnsafeRawBufferPointer(start: base, count: buf.count * MemoryLayout<Int16>.size)
            wav.append(contentsOf: raw)
        }
        return wav
    }

    /// Builds a concise, instruction-free vocabulary prompt so Whisper/GPT-4o-transcribe biases toward user lexicon terms
    /// without hallucinating instructions or biasing English audio toward Chinese when `languageLocale` is English.
    public static func buildPromptHint(
        hotwords: [String],
        maxChars: Int = 380,
        languageLocale: String? = nil
    ) -> String {
        let preferLatinOnly = languageLocale.flatMap { Self.isoLanguageCode(from: $0) } == "en"
        var seen = Set<String>()
        var collected: [String] = []
        var totalLen = 0
        for raw in hotwords {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard term.count >= 2, term.count <= 32 else { continue }
            if preferLatinOnly {
                let hasCJK = term.unicodeScalars.contains { ($0.value >= 0x4E00 && $0.value <= 0x9FFF) || ($0.value >= 0x3400 && $0.value <= 0x4DBF) }
                if hasCJK { continue }
            }
            let key = term.lowercased()
            guard !seen.contains(key) else { continue }
            let projected = totalLen + term.count + (collected.isEmpty ? 0 : 2)
            if projected > maxChars { break }
            seen.insert(key)
            collected.append(term)
            totalLen = projected
        }
        return collected.joined(separator: ", ")
    }

    /// Maps `zh-CN` -> `zh`, `en-US` -> `en`, etc. Returns `nil` when auto-detect is preferred.
    public static func isoLanguageCode(from speechLocale: String) -> String? {
        let trimmed = speechLocale.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "auto" else { return nil }
        if let dash = trimmed.firstIndex(of: "-") {
            return String(trimmed[..<dash]).lowercased()
        }
        if let under = trimmed.firstIndex(of: "_") {
            return String(trimmed[..<under]).lowercased()
        }
        return trimmed.lowercased()
    }

    public func prewarmConnection(baseURL: String, apiKey: String = "") {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 2.5
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanKey.isEmpty {
            req.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
        }
        session.dataTask(with: req) { _, _, _ in }.resume()
    }

    /// Sends a 16kHz mono WAV payload to `/audio/transcriptions` and returns the recognized text + latency.
    public func transcribe(
        wavData: Data,
        baseURL: String,
        model: String,
        apiKey: String,
        hotwords: [String] = [],
        languageLocale: String? = nil,
        timeoutSeconds: TimeInterval = 7.5
    ) async throws -> (text: String, latencyMs: Int) {
        let endpoint = Self.normalizeTranscriptionEndpoint(baseURL)
        guard let url = URL(string: endpoint) else {
            throw NSError(domain: "TypeZero.OpenAIASR", code: -10, userInfo: [NSLocalizedDescriptionKey: "Invalid speech endpoint URL: \(endpoint)"])
        }

        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let isLocalKeyless = PolishEngine.isKeylessLocalEndpoint(baseURL)
        guard !cleanKey.isEmpty || isLocalKeyless else {
            throw NSError(domain: "TypeZero.OpenAIASR", code: -11, userInfo: [NSLocalizedDescriptionKey: "No OpenAI / Groq speech API key is set"])
        }

        let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveModel = cleanModel.isEmpty ? "gpt-4o-mini-transcribe" : cleanModel

        let boundary = "Boundary-\(AppBrand.name)-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var body = Data(capacity: wavData.count + 2048)

        func appendField(name: String, value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }

        appendField(name: "model", value: effectiveModel)
        appendField(name: "response_format", value: "json")
        appendField(name: "temperature", value: "0")

        if let locale = languageLocale, let iso = Self.isoLanguageCode(from: locale) {
            // Only send `language` when explicitly locked by user ("zh-CN" / "en-US").
            // When `speechLocale == "auto"`, omit `language` completely so gpt-4o-mini-transcribe / Whisper
            // auto-detects the spoken language instead of translating English speech into Chinese!
            appendField(name: "language", value: iso)
        }

        let promptHint = Self.buildPromptHint(hotwords: hotwords, languageLocale: languageLocale)
        if !promptHint.isEmpty {
            appendField(name: "prompt", value: promptHint)
        }

        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\n".utf8))
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(wavData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeoutSeconds
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !cleanKey.isEmpty {
            req.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = body

        let startNs = DispatchTime.now().uptimeNanoseconds
        let (data, response) = try await session.data(for: req)
        let latencyMs = Int((DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000)

        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "TypeZero.OpenAIASR", code: -12, userInfo: [NSLocalizedDescriptionKey: "No valid HTTP response received"])
        }

        guard (200...299).contains(http.statusCode) else {
            let errDetail = Self.extractErrorMessage(from: data) ?? "HTTP \(http.statusCode)"
            throw NSError(
                domain: "TypeZero.OpenAIASR",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(errDetail)"]
            )
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = json["text"] as? String {
            return (text.trimmingCharacters(in: .whitespacesAndNewlines), latencyMs)
        }
        if let plain = String(data: data, encoding: .utf8) {
            return (plain.trimmingCharacters(in: .whitespacesAndNewlines), latencyMs)
        }
        return ("", latencyMs)
    }

    /// Probes real end-to-end `/audio/transcriptions` auth + model availability + RTT with a tiny 0.35s 16kHz WAV (~11KB).
    public static func probeLatency(
        baseURL: String,
        model: String,
        apiKey: String
    ) async throws -> Int {
        let sampleCount = 5_600 // 0.35s @ 16kHz (~11.2KB)
        var pcm = [Int16](repeating: 0, count: sampleCount)
        // Very quiet gentle tone so strict VAD proxies don't reject all-zero payloads
        for i in 0..<sampleCount {
            let phase = Double(i) * 2.0 * Double.pi * 440.0 / 16_000.0
            pcm[i] = Int16(sin(phase) * 18.0)
        }
        let wav = encodePCM16ToWAV(pcm, sampleRate: 16_000)
        let client = OpenAITranscriptionClient()
        let (_, ms) = try await client.transcribe(
            wavData: wav,
            baseURL: baseURL,
            model: model,
            apiKey: apiKey,
            hotwords: [],
            languageLocale: nil,
            timeoutSeconds: 8.5
        )
        return ms
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String, !msg.isEmpty {
                return msg
            }
            if let msg = obj["message"] as? String, !msg.isEmpty {
                return msg
            }
        }
        if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return String(text.prefix(160))
        }
        return nil
    }
}
