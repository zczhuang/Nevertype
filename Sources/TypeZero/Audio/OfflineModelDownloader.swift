import Foundation

/// In-app downloader & extractor for the offline speech models (`LocalASRModel`):
/// Parakeet TDT 0.6B v2 (English, ~482MB) and the lossless SenseVoice-Small FP32 pack (~886MB).
/// Downloads the `.tar.bz2` from the official sherpa-onnx GitHub release, checks its SHA-256 against the digest pinned in
/// `LocalASRModel.archiveSHA256`, and only then extracts it into `~/Library/Application Support/Nevertype/Models`.
/// An archive that does not match is discarded and nothing is extracted.
public final class OfflineModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var session: URLSession?
    private var activeTask: URLSessionDownloadTask?
    private var currentMirrorIndex: Int = 0
    private var isCancelledManually: Bool = false
    private var currentModel: LocalASRModel = .default

    /// Test hooks (self-test only): extract into a temp folder / download from `file://` fixtures instead of GitHub /
    /// expect another digest than the pinned one (a fixture archive is not the real release).
    var modelsRootOverride: URL?
    var downloadURLStringsOverride: [String]?
    var expectedSHA256Override: String?

    public var onProgress: (@MainActor (_ fraction: Double, _ statusText: String) -> Void)?
    public var onCompletion: (@MainActor (_ success: Bool, _ message: String) -> Void)?

    public override init() {
        super.init()
    }

    private func model() -> LocalASRModel {
        lock.lock()
        defer { lock.unlock() }
        return currentModel
    }

    public func startDownload(model: LocalASRModel) {
        lock.lock()
        guard activeTask == nil else {
            lock.unlock()
            return
        }
        isCancelledManually = false
        currentMirrorIndex = 0
        currentModel = model
        lock.unlock()

        startFromCurrentMirror()
    }

    public func cancelDownload() {
        lock.lock()
        isCancelledManually = true
        let task = activeTask
        activeTask = nil
        let sess = session
        session = nil
        lock.unlock()

        task?.cancel()
        sess?.invalidateAndCancel()
        Task { @MainActor [weak self] in
            self?.onCompletion?(false, "Local model download canceled")
        }
    }

    private func startFromCurrentMirror() {
        lock.lock()
        let idx = currentMirrorIndex
        let model = currentModel
        lock.unlock()

        let urls = downloadURLStringsOverride ?? model.downloadURLStrings
        guard idx < urls.count,
              let url = URL(string: urls[idx]) else {
            Task { @MainActor [weak self] in
                self?.onCompletion?(false, "❌ Model download failed — check your network connection and try again")
            }
            return
        }

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30.0
        cfg.timeoutIntervalForResource = 3600.0
        let newSession = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        let task = newSession.downloadTask(with: url)

        lock.lock()
        self.session = newSession
        self.activeTask = task
        lock.unlock()

        let mirrorNote = idx == 0 ? "Connecting to the official source…" : "Trying the next source…"
        Task { @MainActor [weak self] in
            self?.onProgress?(0.01, mirrorNote)
        }
        task.resume()
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let model = self.model()
        let fallbackExpected = Int64(model.approxDownloadMB) * 1_048_576
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : fallbackExpected
        let frac = min(0.95, max(0.01, Double(totalBytesWritten) / Double(expected)))
        let mbDone = Int(totalBytesWritten / 1_048_576)
        let mbTotal = max(mbDone, Int(expected / 1_048_576))
        let status = "Downloading \(model.shortName) \(mbDone) / \(mbTotal) MB (\(Int(frac * 100))%)"

        Task { @MainActor [weak self] in
            self?.onProgress?(frac, status)
        }
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            tryNextMirrorOrFail(session: session, errorMsg: "HTTP \(http.statusCode)")
            return
        }

        let model = self.model()
        let fm = FileManager.default
        let modelsRoot = modelsRootOverride ?? LocalASRModel.defaultModelsRoot()
        try? fm.createDirectory(at: modelsRoot, withIntermediateDirectories: true)

        let archiveDest = modelsRoot.appendingPathComponent(model.downloadArchiveFileName)
        if fm.fileExists(atPath: archiveDest.path) {
            discardArchive(archiveDest)
        }

        do {
            try fm.moveItem(at: location, to: archiveDest)
        } catch {
            cleanupSession(session)
            Task { @MainActor [weak self] in
                self?.onCompletion?(false, "❌ Could not save the model archive: \(error.localizedDescription)")
            }
            return
        }

        Task { @MainActor [weak self] in
            self?.onProgress?(0.96, "Download finished — verifying \(model.shortName) (SHA-256)…")
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            // Nothing is unpacked before the archive's SHA-256 matches the pinned digest.
            let expectedDigest = self.expectedSHA256Override ?? model.archiveSHA256
            let failure: String?
            switch ArchiveChecksum.verify(fileAt: archiveDest, expectedSHA256: expectedDigest) {
            case .match:
                failure = nil
            case .mismatch(let actual):
                failure = "❌ The downloaded \(model.shortName) archive failed its SHA-256 check (expected \(expectedDigest.prefix(12))…, got \(actual.prefix(12))…), "
                    + "so it was discarded and nothing was installed. Try again, and if it keeps happening please report an issue."
            case .missing:
                failure = "❌ The downloaded \(model.shortName) archive disappeared before it could be verified, so nothing was installed. Please try again."
            case .unreadable(let reason):
                failure = "❌ The downloaded \(model.shortName) archive could not be read to verify it (\(reason)), so nothing was installed."
            }
            if let failure {
                self.discardArchive(archiveDest)
                self.cleanupSession(session)
                Task { @MainActor in
                    self.onCompletion?(false, failure)
                }
                return
            }

            Task { @MainActor in
                self.onProgress?(0.97, "Checksum OK — extracting \(model.shortName) (~\(model.approxDownloadMB) MB)…")
            }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            proc.arguments = ["-xjf", archiveDest.path, "-C", modelsRoot.path]

            do {
                try proc.run()
                proc.waitUntilExit()
                discardArchive(archiveDest)
                self.cleanupSession(session)

                let extractedDir = modelsRoot.appendingPathComponent(model.extractedFolderName, isDirectory: true)
                let allFilesPresent = model.requiredFileNames.allSatisfy {
                    fm.fileExists(atPath: extractedDir.appendingPathComponent($0).path)
                }
                if proc.terminationStatus == 0 && allFilesPresent {
                    Task { @MainActor in
                        self.onProgress?(1.0, "\(model.shortName) installed")
                        self.onCompletion?(true, "✅ \(model.displayName) downloaded and installed")
                    }
                } else {
                    Task { @MainActor in
                        self.onCompletion?(false, "❌ Extracting the model failed (exit code \(proc.terminationStatus))")
                    }
                }
            } catch {
                discardArchive(archiveDest)
                self.cleanupSession(session)
                Task { @MainActor in
                    self.onCompletion?(false, "❌ Extraction failed: \(error.localizedDescription)")
                }
            }
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        lock.lock()
        let cancelled = isCancelledManually
        lock.unlock()
        if cancelled { return }
        tryNextMirrorOrFail(session: session, errorMsg: error.localizedDescription)
    }

    private func tryNextMirrorOrFail(session: URLSession, errorMsg: String) {
        session.invalidateAndCancel()
        lock.lock()
        activeTask = nil
        self.session = nil
        currentMirrorIndex += 1
        let nextIdx = currentMirrorIndex
        let mirrorCount = (downloadURLStringsOverride ?? currentModel.downloadURLStrings).count
        lock.unlock()

        if nextIdx < mirrorCount {
            startFromCurrentMirror()
        } else {
            Task { @MainActor [weak self] in
                self?.onCompletion?(false, "❌ Model download failed: \(errorMsg)")
            }
        }
    }

    /// Archives go to the Trash (never `rm`); test runs with an overridden models folder delete their throwaway fixture instead.
    private func discardArchive(_ url: URL) {
        let fm = FileManager.default
        if modelsRootOverride != nil {
            try? fm.removeItem(at: url)
        } else {
            try? fm.trashItem(at: url, resultingItemURL: nil)
        }
    }

    private func cleanupSession(_ session: URLSession) {
        session.finishTasksAndInvalidate()
        lock.lock()
        activeTask = nil
        if self.session === session {
            self.session = nil
        }
        lock.unlock()
    }
}
