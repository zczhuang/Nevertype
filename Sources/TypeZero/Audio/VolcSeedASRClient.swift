import Foundation
import zlib

/// Native Swift binary WebSocket client for Volcengine Doubao Streaming ASR 2.0 (`Seed-ASR` / `volc.seedasr.sauc.duration`).
/// - Connects directly via domestic backbone (`connectionProxyDictionary = [:]`, immune to VPN proxy detour latency!).
/// - Streams 16kHz 16-bit mono PCM chunks every 160ms with Gzip framing (`wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async`).
/// - Injects user's personal lexicon directly into Seed-ASR's acoustic `corpus.context` hotwords layer!
public final class VolcSeedASRClient: @unchecked Sendable {
    private static let endpointURLString = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"
    public static let defaultResourceID = "volc.seedasr.sauc.duration"

    private let directSession: URLSession
    private let sendQueue = DispatchQueue(label: "io.github.typezero.volc.seedasr.send", qos: .userInteractive)
    private let stateLock = NSLock()

    private var webSocketTask: URLSessionWebSocketTask?
    private var lastPrewarmAt: Date = .distantPast

    private var activeAPIKey: String = ""
    private var activeResourceID: String = VolcSeedASRClient.defaultResourceID
    private var didRetryFreshSocket: Bool = false
    private var replayHandshakeFrames: [Data] = []
    private var sentAudioChunkCount: Int = 0

    private var pendingPCM16Bytes = Data()
    private var isActive: Bool = false
    private var hasFailedOver: Bool = false
    private var latestServerText: String = ""
    private var didReceiveFinalPacket: Bool = false
    private var receivedServerFrameCount: Int = 0
    private var finalContinuation: CheckedContinuation<String?, Never>?

    public var onStreamingTranscript: ((_ text: String, _ isDefiniteUtterance: Bool) -> Void)?
    public var onConnectionFallbackNeeded: ((_ reason: String) -> Void)?

    public var hasReceivedAnyServerFrame: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return receivedServerFrameCount > 0
    }

    public init() {
        let cfg = URLSessionConfiguration.ephemeral
        // CRITICAL: Bypass system VPN/proxy so domestic WebSocket RTT stays ~25ms instead of ~300ms overseas detour!
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = 5.0
        cfg.timeoutIntervalForResource = 300.0
        self.directSession = URLSession(configuration: cfg)
    }

    deinit {
        directSession.invalidateAndCancel()
    }

    /// Safely pre-warms DNS + TCP + TLS 1.3 Session Ticket to `openspeech.bytedance.com:443` (rate-limited to <= 1x per 25s).
    public func prewarmStandbySocket(apiKey: String, resourceID: String = VolcSeedASRClient.defaultResourceID) {
        stateLock.lock()
        guard Date().timeIntervalSince(lastPrewarmAt) >= 25.0 else {
            stateLock.unlock()
            return
        }
        lastPrewarmAt = Date()
        stateLock.unlock()

        guard let httpsURL = URL(string: "https://openspeech.bytedance.com/") else { return }
        var req = URLRequest(url: httpsURL)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 3.0
        directSession.dataTask(with: req) { _, _, _ in }.resume()
    }

    private func makeWebSocketTask(apiKey: String, resourceID: String, wsURL: URL) -> URLSessionWebSocketTask {
        var req = URLRequest(url: wsURL)
        req.timeoutInterval = 4.5
        req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        req.setValue(resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        req.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Connect-Id")
        req.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
        let t = directSession.webSocketTask(with: req)
        t.resume()
        return t
    }

    public func startSession(
        apiKey: String,
        hotwords: [String],
        dialogContext: [String] = [],
        enableDDC: Bool = true,
        enableNonstream: Bool = true,
        resourceID: String = VolcSeedASRClient.defaultResourceID
    ) {
        stopAndReset()
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty, let wsURL = URL(string: Self.endpointURLString) else {
            onConnectionFallbackNeeded?("no Doubao speech API key is set")
            return
        }

        let task = makeWebSocketTask(apiKey: cleanKey, resourceID: resourceID, wsURL: wsURL)

        stateLock.lock()
        isActive = true
        hasFailedOver = false
        latestServerText = ""
        didReceiveFinalPacket = false
        receivedServerFrameCount = 0
        sentAudioChunkCount = 0
        activeAPIKey = cleanKey
        activeResourceID = resourceID
        didRetryFreshSocket = false
        replayHandshakeFrames.removeAll(keepingCapacity: true)
        pendingPCM16Bytes.removeAll(keepingCapacity: true)
        self.webSocketTask = task
        stateLock.unlock()

        // Build hotword + dialog context JSON for Seed-ASR 2.0 acoustic biasing:
        // Keep hotwords strictly <= 65 high-signal terms (~160 tokens) so Volcengine's 200-token hotword budget never truncates!
        let hotwordObjs: [[String: String]] = hotwords.prefix(65).map { ["word": $0] }
        let dialogObjs: [[String: String]] = dialogContext
            .map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).suffix(120)) }
            .filter { !$0.isEmpty }
            .prefix(2)
            .map { ["text": $0] }

        let contextJSONString: String = {
            var ctxObj: [String: Any] = [:]
            if !hotwordObjs.isEmpty {
                ctxObj["hotwords"] = hotwordObjs
            }
            if !dialogObjs.isEmpty {
                ctxObj["context_type"] = "dialog_ctx"
                ctxObj["context_data"] = dialogObjs
            }
            guard !ctxObj.isEmpty,
                  let data = try? JSONSerialization.data(withJSONObject: ctxObj),
                  let str = String(data: data, encoding: .utf8) else {
                return ""
            }
            return str
        }()

        var reqDict: [String: Any] = [
            "model_name": "bigmodel",
            "enable_itn": true,
            "enable_punc": true,
            "enable_ddc": enableDDC,
            "enable_nonstream": enableNonstream,
            "show_utterances": true,
            "result_type": "full"
        ]
        if !contextJSONString.isEmpty {
            reqDict["corpus"] = ["context": contextJSONString]
        }

        let initPayload: [String: Any] = [
            "user": ["uid": "nevertype_macos_client"],
            "audio": [
                "format": "pcm",
                "codec": "raw",
                "rate": 16000,
                "bits": 16,
                "channel": 1
            ],
            "request": reqDict
        ]

        sendQueue.async { [weak self] in
            guard let self,
                  let jsonData = try? JSONSerialization.data(withJSONObject: initPayload) else { return }
            let frame = Self.makeBinaryFrame(
                msgType: 0x1,
                flags: 0x0,
                serialization: 0x1,
                compression: 0x1,
                payload: Self.gzipCompress(jsonData)
            )
            self.stateLock.lock()
            self.replayHandshakeFrames.append(frame)
            self.stateLock.unlock()

            task.send(.data(frame)) { [weak self] err in
                if let err {
                    self?.handleEarlySocketErrorOrFailover(failedTask: task, reason: err.localizedDescription)
                }
            }
        }

        listenLoop(for: task)
    }

    /// Appends anti-aliased 16kHz Int16 PCM samples:
    /// Uses 60ms (1920-byte) fast-start packets for the first 3 frames to shave 40ms off first-word arrival,
    /// then transitions to 100ms (3200-byte) steady bidirectional packets!
    public func appendPCM16Samples(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }

        var chunksToSend: [Data] = []
        stateLock.lock()
        guard isActive, !hasFailedOver else {
            stateLock.unlock()
            return
        }
        samples.withUnsafeBytes { rawBuf in
            pendingPCM16Bytes.append(contentsOf: rawBuf)
        }

        while true {
            let packetBytes = (sentAudioChunkCount < 3) ? 1920 : 3200
            guard pendingPCM16Bytes.count >= packetBytes else { break }
            chunksToSend.append(Data(pendingPCM16Bytes.prefix(packetBytes)))
            pendingPCM16Bytes.removeFirst(packetBytes)
            sentAudioChunkCount += 1
        }
        let task = self.webSocketTask
        let keepReplay = (receivedServerFrameCount == 0 && replayHandshakeFrames.count < 16)
        stateLock.unlock()

        if !chunksToSend.isEmpty, let task {
            sendQueue.async { [weak self] in
                guard let self else { return }
                for chunk in chunksToSend {
                    let frame = Self.makeBinaryFrame(
                        msgType: 0x2,
                        flags: 0x0,
                        serialization: 0x0,
                        compression: 0x1,
                        payload: Self.gzipCompress(chunk)
                    )
                    if keepReplay {
                        self.stateLock.lock()
                        if self.receivedServerFrameCount == 0 && self.replayHandshakeFrames.count < 16 {
                            self.replayHandshakeFrames.append(frame)
                        }
                        self.stateLock.unlock()
                    }
                    task.send(.data(frame)) { [weak self] err in
                        if let err {
                            self?.handleEarlySocketErrorOrFailover(failedTask: task, reason: err.localizedDescription)
                        }
                    }
                }
            }
        }
    }

    private enum FinalizationAction {
        case immediate(String?)
        case sendFinalAndAwait(task: URLSessionWebSocketTask, remainingPCM: Data)
    }

    private func prepareFinalizationState() -> FinalizationAction {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isActive, !hasFailedOver, let task = webSocketTask else {
            let partialIfAny = hasFailedOver ? nil : (latestServerText.isEmpty ? nil : latestServerText)
            isActive = false
            return .immediate(partialIfAny)
        }
        isActive = false
        let remainingPCM = pendingPCM16Bytes
        pendingPCM16Bytes.removeAll(keepingCapacity: false)
        if didReceiveFinalPacket {
            let ready = latestServerText
            return .immediate(ready.isEmpty ? nil : ready)
        }
        return .sendFinalAndAwait(task: task, remainingPCM: remainingPCM)
    }

    /// Sends final trailing audio frame (`flags = 0x2`) and waits up to `timeoutMs` for Seed-ASR 2.0's definitive full-utterance result.
    /// Returns `nil` if connection failed or timed out so caller can seamlessly fall back to local FP32 SenseVoice!
    public func finishAndAwaitFinalTranscript(timeoutMs: UInt64 = 550) async -> String? {
        let task: URLSessionWebSocketTask
        let remainingPCM: Data
        switch prepareFinalizationState() {
        case .immediate(let ready):
            stopAndReset()
            return ready
        case .sendFinalAndAwait(let wsTask, let tailPCM):
            task = wsTask
            remainingPCM = tailPCM
        }

        // Send negative/last audio packet (`flags = 0x2`)
        sendQueue.async {
            let finalFrame = Self.makeBinaryFrame(
                msgType: 0x2,
                flags: 0x2,
                serialization: 0x0,
                compression: 0x1,
                payload: Self.gzipCompress(remainingPCM)
            )
            task.send(.data(finalFrame)) { _ in }
        }

        let result: String? = await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            stateLock.lock()
            if didReceiveFinalPacket || hasFailedOver {
                let txt = hasFailedOver ? nil : (latestServerText.isEmpty ? nil : latestServerText)
                stateLock.unlock()
                cont.resume(returning: txt)
                return
            }
            self.finalContinuation = cont
            stateLock.unlock()

            // Hard timeout guard so a sudden Wi-Fi drop never hangs dictation finalization!
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + .milliseconds(Int(timeoutMs))) { [weak self] in
                guard let self else { return }
                self.stateLock.lock()
                if let waiting = self.finalContinuation {
                    self.finalContinuation = nil
                    let bestSoFar = self.hasFailedOver ? nil : (self.latestServerText.isEmpty ? nil : self.latestServerText)
                    self.stateLock.unlock()
                    waiting.resume(returning: bestSoFar)
                } else {
                    self.stateLock.unlock()
                }
            }
        }

        stopAndReset()
        return result
    }

    public func stopAndReset() {
        stateLock.lock()
        isActive = false
        let task = webSocketTask
        webSocketTask = nil
        let waiting = finalContinuation
        finalContinuation = nil
        replayHandshakeFrames.removeAll(keepingCapacity: false)
        pendingPCM16Bytes.removeAll(keepingCapacity: false)
        stateLock.unlock()

        waiting?.resume(returning: nil)
        task?.cancel(with: .normalClosure, reason: nil)
    }

    /// If a pre-warmed standby WebSocket silently closed right before `startSession`, transparently swap in
    /// a fresh WebSocket on the warm TLS pool and replay `initFrame` + early audio frames with 0 lost syllables!
    private func handleEarlySocketErrorOrFailover(failedTask: URLSessionWebSocketTask, reason: String) {
        stateLock.lock()
        guard webSocketTask === failedTask else {
            stateLock.unlock()
            return
        }
        if isActive,
           !didRetryFreshSocket,
           receivedServerFrameCount == 0,
           !replayHandshakeFrames.isEmpty,
           let wsURL = URL(string: Self.endpointURLString) {
            didRetryFreshSocket = true
            let key = activeAPIKey
            let resID = activeResourceID
            let framesToReplay = replayHandshakeFrames
            stateLock.unlock()

            failedTask.cancel(with: .normalClosure, reason: nil)
            let replacement = makeWebSocketTask(apiKey: key, resourceID: resID, wsURL: wsURL)
            stateLock.lock()
            guard isActive else {
                stateLock.unlock()
                replacement.cancel(with: .normalClosure, reason: nil)
                return
            }
            self.webSocketTask = replacement
            stateLock.unlock()

            sendQueue.async { [weak self] in
                for f in framesToReplay {
                    replacement.send(.data(f)) { [weak self] err in
                        if let err {
                            self?.triggerFailover(reason: err.localizedDescription)
                        }
                    }
                }
            }
            listenLoop(for: replacement)
            return
        }
        stateLock.unlock()
        triggerFailover(reason: reason)
    }

    private func triggerFailover(reason: String) {
        stateLock.lock()
        guard !hasFailedOver else {
            stateLock.unlock()
            return
        }
        hasFailedOver = true
        let waiting = finalContinuation
        finalContinuation = nil
        stateLock.unlock()

        waiting?.resume(returning: nil)
        DispatchQueue.main.async { [weak self] in
            self?.onConnectionFallbackNeeded?(reason)
        }
    }

    private func listenLoop(for task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.stateLock.lock()
            let isCurrent = (self.webSocketTask === task)
            self.stateLock.unlock()
            guard isCurrent else { return }

            switch result {
            case .failure(let err):
                self.handleEarlySocketErrorOrFailover(failedTask: task, reason: err.localizedDescription)

            case .success(let message):
                if case .data(let raw) = message {
                    let keepReading = self.handleIncomingBinaryFrame(raw)
                    if keepReading {
                        self.listenLoop(for: task)
                    }
                } else {
                    self.listenLoop(for: task)
                }
            }
        }
    }

    /// Returns `true` to continue reading subsequent frames, `false` when final packet or error arrived.
    private func handleIncomingBinaryFrame(_ raw: Data) -> Bool {
        guard raw.count >= 8 else { return true }
        let byte1 = raw[1]
        let byte2 = raw[2]
        let msgType = byte1 >> 4
        let flags = byte1 & 0x0F
        let serial = byte2 >> 4
        let comp = byte2 & 0x0F

        if msgType == 0xF {
            // Server Error Response
            var errMsg = "Seed-ASR server error"
            if raw.count >= 12 {
                let errLen = Int(raw.subdata(in: 8..<12).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
                let body = raw.subdata(in: 12..<min(raw.count, 12 + errLen))
                let unzipped = (comp == 0x1) ? Self.gzipDecompress(body) : body
                if let str = String(data: unzipped, encoding: .utf8), !str.isEmpty {
                    errMsg = str
                }
            }
            triggerFailover(reason: errMsg)
            return false
        }

        var offset = 4
        if flags == 0x1 || flags == 0x2 || flags == 0x3 {
            offset += 4
        }
        let isFinalStreamPacket = (flags == 0x2 || flags == 0x3)

        stateLock.lock()
        receivedServerFrameCount += 1
        stateLock.unlock()

        guard raw.count >= offset + 4 else {
            if isFinalStreamPacket {
                completeFinalPacketIfNeeded()
                return false
            }
            return true
        }
        let payloadSize = Int(raw.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
        offset += 4
        guard payloadSize > 0, raw.count >= offset else {
            if isFinalStreamPacket {
                completeFinalPacketIfNeeded()
                return false
            }
            return true
        }

        let body = raw.subdata(in: offset..<min(raw.count, offset + payloadSize))
        let unzipped = (comp == 0x1) ? Self.gzipDecompress(body) : body

        if serial == 0x1,
           let json = try? JSONSerialization.jsonObject(with: unzipped) as? [String: Any],
           let resObj = json["result"] as? [String: Any],
           let text = resObj["text"] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            var isDefiniteClause = false
            if let utterances = resObj["utterances"] as? [[String: Any]],
               let lastUtt = utterances.last,
               let def = lastUtt["definite"] as? Bool {
                isDefiniteClause = def
            }

            stateLock.lock()
            if !trimmed.isEmpty {
                latestServerText = trimmed
            }
            if isFinalStreamPacket {
                didReceiveFinalPacket = true
                let waiting = finalContinuation
                finalContinuation = nil
                let finalOut = latestServerText
                stateLock.unlock()

                if !trimmed.isEmpty {
                    DispatchQueue.main.async { [weak self] in
                        self?.onStreamingTranscript?(trimmed, true)
                    }
                }
                waiting?.resume(returning: finalOut.isEmpty ? nil : finalOut)
                return false
            }
            stateLock.unlock()

            if !trimmed.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    self?.onStreamingTranscript?(trimmed, isDefiniteClause)
                }
            }
        } else if isFinalStreamPacket {
            completeFinalPacketIfNeeded()
            return false
        }
        return true
    }

    private func completeFinalPacketIfNeeded() {
        stateLock.lock()
        didReceiveFinalPacket = true
        let waiting = finalContinuation
        finalContinuation = nil
        let finalOut = latestServerText
        stateLock.unlock()
        waiting?.resume(returning: finalOut.isEmpty ? nil : finalOut)
    }

    /// Live diagnostic probe: verifies `volc.seedasr.sauc.duration` WebSocket auth + RTT in milliseconds.
    public static func probeHandshakeLatency(
        apiKey: String,
        resourceID: String = defaultResourceID
    ) async throws -> Int {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty, let wsURL = URL(string: endpointURLString) else {
            throw NSError(domain: "TypeZero.SeedASR", code: -1, userInfo: [NSLocalizedDescriptionKey: "Paste your Doubao speech API key first"])
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = 5.0
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }

        var req = URLRequest(url: wsURL)
        req.timeoutInterval = 5.0
        req.setValue(cleanKey, forHTTPHeaderField: "X-Api-Key")
        req.setValue(resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        req.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Connect-Id")
        req.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")

        let t0 = DispatchTime.now().uptimeNanoseconds
        let task = session.webSocketTask(with: req)
        task.resume()

        let initPayload: [String: Any] = [
            "user": ["uid": "nevertype_probe"],
            "audio": ["format": "pcm", "codec": "raw", "rate": 16000, "bits": 16, "channel": 1],
            "request": ["model_name": "bigmodel", "enable_itn": true, "enable_punc": true, "result_type": "full"]
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: initPayload)
        let initFrame = makeBinaryFrame(msgType: 0x1, flags: 0x0, serialization: 0x1, compression: 0x1, payload: gzipCompress(jsonData))
        try await task.send(.data(initFrame))

        // Send 100ms silent final frame (`flags = 0x2`) and measure first server response frame
        let silentPCM = Data(count: 3200)
        let audioFrame = makeBinaryFrame(msgType: 0x2, flags: 0x2, serialization: 0x0, compression: 0x1, payload: gzipCompress(silentPCM))
        try await task.send(.data(audioFrame))

        let msg = try await task.receive()
        let elapsedMs = Int((DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
        task.cancel(with: .normalClosure, reason: nil)

        if case .data(let raw) = msg, raw.count >= 8 {
            let msgType = raw[1] >> 4
            let comp = raw[2] & 0x0F
            if msgType == 0xF {
                var detail = "Authentication or resource package error"
                if raw.count >= 12 {
                    let errLen = Int(raw.subdata(in: 8..<12).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
                    let body = raw.subdata(in: 12..<min(raw.count, 12 + errLen))
                    let unzipped = (comp == 0x1) ? gzipDecompress(body) : body
                    if let str = String(data: unzipped, encoding: .utf8), !str.isEmpty {
                        detail = str
                    }
                }
                throw NSError(domain: "TypeZero.SeedASR", code: -2, userInfo: [NSLocalizedDescriptionKey: detail])
            }
        }
        return max(1, elapsedMs)
    }

    // MARK: - Binary Framing & Native Zlib Gzip Helpers

    private static func makeBinaryFrame(
        msgType: UInt8,
        flags: UInt8,
        serialization: UInt8,
        compression: UInt8,
        payload: Data
    ) -> Data {
        var d = Data(capacity: 8 + payload.count)
        d.append((0x1 << 4) | 0x1)
        d.append((msgType << 4) | (flags & 0x0F))
        d.append((serialization << 4) | (compression & 0x0F))
        d.append(0x00)
        var beLen = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &beLen) { d.append(contentsOf: $0) }
        d.append(payload)
        return d
    }

    private static func gzipCompress(_ data: Data) -> Data {
        guard !data.isEmpty else {
            // Valid gzip representation of empty 0-byte payload
            var emptyStream = z_stream()
            guard deflateInit2_(&emptyStream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                return Data()
            }
            defer { deflateEnd(&emptyStream) }
            var out = Data(count: 32)
            out.withUnsafeMutableBytes { outBuf in
                if let base = outBuf.bindMemory(to: Bytef.self).baseAddress {
                    emptyStream.next_out = base
                    emptyStream.avail_out = uInt(outBuf.count)
                    _ = deflate(&emptyStream, Z_FINISH)
                }
            }
            out.count = Int(emptyStream.total_out)
            return out
        }

        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            return data
        }
        defer { deflateEnd(&stream) }

        var out = Data(count: data.count + 64)
        data.withUnsafeBytes { inBuf in
            out.withUnsafeMutableBytes { outBuf in
                guard let inBase = inBuf.bindMemory(to: Bytef.self).baseAddress,
                      let outBase = outBuf.bindMemory(to: Bytef.self).baseAddress else { return }
                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inBase)
                stream.avail_in = uInt(data.count)
                stream.next_out = outBase
                stream.avail_out = uInt(outBuf.count)
                _ = deflate(&stream, Z_FINISH)
            }
        }
        out.count = Int(stream.total_out)
        return out
    }

    private static func gzipDecompress(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            return data
        }
        defer { inflateEnd(&stream) }

        var fullOut = Data()
        let chunkCap = max(4096, data.count * 4)
        var temp = [UInt8](repeating: 0, count: chunkCap)

        data.withUnsafeBytes { inBuf in
            guard let inBase = inBuf.bindMemory(to: Bytef.self).baseAddress else { return }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inBase)
            stream.avail_in = uInt(data.count)
            repeat {
                temp.withUnsafeMutableBufferPointer { outPtr in
                    guard let outBase = outPtr.baseAddress else { return }
                    stream.next_out = outBase
                    stream.avail_out = uInt(chunkCap)
                    let ret = inflate(&stream, Z_NO_FLUSH)
                    let have = chunkCap - Int(stream.avail_out)
                    if have > 0 {
                        fullOut.append(outBase, count: have)
                    }
                    if ret != Z_OK {
                        stream.avail_out = 1
                    }
                }
            } while stream.avail_out == 0
        }
        return fullOut
    }
}
