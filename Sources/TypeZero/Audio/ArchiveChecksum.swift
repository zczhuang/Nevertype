import Foundation
import CryptoKit

/// SHA-256 check of a downloaded archive. `OfflineModelDownloader` runs it after the download and before extracting, so an
/// archive that is corrupt, truncated or not the pinned release (`LocalASRModel.archiveSHA256`) is never unpacked.
public enum ArchiveChecksum {
    public enum Result: Equatable, Sendable {
        /// The file's SHA-256 is the expected one.
        case match
        /// The file was read, but its SHA-256 is another one (`actual`, lowercase hex).
        case mismatch(actual: String)
        /// There is no file at that path.
        case missing
        /// The file is there but could not be read (a folder, no permission, an I/O error).
        case unreadable(String)
    }

    /// The SenseVoice archive is 887 MB, so the file is hashed in chunks of this size and never loaded whole.
    public static let chunkSize = 4 * 1024 * 1024

    /// SHA-256 of the whole file as lowercase hex, streamed through CryptoKit `chunkSize` bytes at a time.
    public static func sha256Hex(of url: URL, chunkSize: Int = ArchiveChecksum.chunkSize) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = max(1, chunkSize)
        var hasher = SHA256()
        while true {
            // The pool frees each chunk before the next one is read, so memory stays at about one chunk.
            let more: Bool = try autoreleasepool {
                guard let chunk = try handle.read(upToCount: size), !chunk.isEmpty else { return false }
                hasher.update(data: chunk)
                return true
            }
            if !more { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Compares the file's SHA-256 with `expectedSHA256` (hex, any case, surrounding whitespace ignored).
    /// An expected value that is not a 64-digit hex string can never match.
    public static func verify(fileAt url: URL, expectedSHA256: String, chunkSize: Int = ArchiveChecksum.chunkSize) -> Result {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return .missing }
        guard !isDirectory.boolValue else { return .unreadable("\(url.lastPathComponent) is a folder, not a file") }
        let expected = expectedSHA256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        do {
            let actual = try sha256Hex(of: url, chunkSize: chunkSize)
            return actual == expected ? .match : .mismatch(actual: actual)
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }
}
