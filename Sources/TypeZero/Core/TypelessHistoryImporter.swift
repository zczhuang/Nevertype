import Foundation
import CryptoKit
import SQLite3

// MARK: - Typeless history import
//
// One-way, read-only sync of the dictations recorded by the Typeless app into Nevertype's History. It is opt-in
// (`LLMConfig.enableTypelessImport`, off by default): while the setting is off, nothing in here opens the database or
// the recordings.
//
//   typeless.db (SQLite, opened read-only)  ->  eligible rows  ->  DictationRecord  ->  AppState.history + history.json
//
// Which rows are importable, how a row maps onto a record and how the result is merged are plain functions in this
// file, so `TypelessImportSelfTests` can check them against a throw-away SQLite fixture. Nothing in here ever writes
// to Typeless's files: the database is opened with SQLITE_OPEN_READONLY, and the fallback works on a private copy. The same
// goes for the recordings (`TypelessRecordings`): each audio file is opened read-only, measured and closed, and none is copied.

// MARK: Rows and candidates

/// The columns of a Typeless `history_v2` row that the importer needs.
struct TypelessRow: Equatable, Sendable {
    var id: String
    var status: String
    var mode: String
    var refinedText: String
    var duration: Double
    var createdAt: String
    /// `audio_local_path`: where Typeless says it saved this dictation's audio. Empty when the column is NULL.
    var audioLocalPath: String = ""
}

/// A row that passed every filter, already mapped to a Nevertype record.
struct TypelessCandidate {
    /// The row's primary key in Typeless's database. This is what the imported-ids store remembers.
    let typelessID: String
    let record: DictationRecord
}

// MARK: Paths

enum TypelessPaths {
    private static var applicationSupport: URL {
        let fm = FileManager.default
        return fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    /// `~/Library/Application Support/Typeless/typeless.db`
    static var databaseURL: URL {
        applicationSupport
            .appendingPathComponent("Typeless", isDirectory: true)
            .appendingPathComponent("typeless.db")
    }

    /// Whether the Typeless database file exists. Settings uses this to decide whether to offer the import switch. It only
    /// asks the file system (like `ls`); it never opens or reads the file.
    static var databaseExists: Bool {
        FileManager.default.fileExists(atPath: databaseURL.path)
    }

    /// `~/Library/Application Support/Typeless/Recordings`: Typeless keeps one `<id>.ogg` here per dictation.
    static var recordingsURL: URL {
        applicationSupport
            .appendingPathComponent("Typeless", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    /// `~/Library/Application Support/Nevertype/typeless-imported-ids.json`, next to `history.json`.
    static var importedIDsURL: URL {
        AppBrand.applicationSupportDirectory()
            .appendingPathComponent("typeless-imported-ids.json")
    }
}

// MARK: Mapping

/// Parses Typeless's `created_at` values (ISO-8601, normally `2026-11-24T21:21:24.992Z`).
/// Holds two formatters, so make one per batch and don't share it between threads.
struct TypelessDateParser {
    private let withFraction: ISO8601DateFormatter
    private let withoutFraction: ISO8601DateFormatter

    init() {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        withFraction = fractional
        withoutFraction = whole
    }

    func parse(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return withFraction.date(from: text) ?? withoutFraction.date(from: text)
    }
}

/// Result of filtering and mapping every row of `history_v2`.
struct TypelessScan {
    var totalRows = 0
    var skippedStatus = 0
    var skippedMode = 0
    var skippedEmptyText = 0
    var skippedMissingID = 0
    var skippedBadDate = 0
    /// Eligible rows, newest first.
    var candidates: [TypelessCandidate] = []

    var eligibleCount: Int { candidates.count }
}

enum TypelessMapper {
    /// `targetAppName` of every imported record. The History page counts records with this name for its info line.
    static let appName = "Typeless"
    static let completedStatus = "completed"
    static let transcriptMode = "voice_transcript"

    enum Skip: Equatable {
        case status, mode, emptyText, missingID, badDate
    }

    enum Verdict {
        case eligible(TypelessCandidate)
        case skipped(Skip)
    }

    /// Eligible rows are `completed` + `voice_transcript` with non-empty (after trimming) `refined_text`.
    /// Voice commands and dismissed dictations are never imported. A row without an id or with an unreadable
    /// `created_at` cannot be tracked or placed in the timeline, so it is skipped as well.
    static func verdict(for row: TypelessRow, dateParser: TypelessDateParser) -> Verdict {
        guard row.status == completedStatus else { return .skipped(.status) }
        guard row.mode == transcriptMode else { return .skipped(.mode) }
        guard !row.refinedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .skipped(.emptyText) }
        guard !row.id.isEmpty else { return .skipped(.missingID) }
        guard let timestamp = dateParser.parse(row.createdAt) else { return .skipped(.badDate) }

        let seconds = row.duration.isFinite ? max(0, row.duration) : 0
        let record = DictationRecord(
            id: recordID(forTypelessID: row.id),
            timestamp: timestamp,
            rawTranscript: row.refinedText,
            polishedText: row.refinedText,
            durationSeconds: seconds,
            polishLatencyMs: 0,
            targetAppName: appName,
            mode: .dictate,
            matchedTerms: []
        )
        return .eligible(TypelessCandidate(typelessID: row.id, record: record))
    }

    /// Filters and maps `rows`. The candidates come back newest first (ties broken by Typeless id), so the outcome
    /// never depends on the order SQLite happens to return rows in.
    static func scan(_ rows: [TypelessRow]) -> TypelessScan {
        let parser = TypelessDateParser()
        var scan = TypelessScan()
        scan.totalRows = rows.count
        for row in rows {
            switch verdict(for: row, dateParser: parser) {
            case .eligible(let candidate): scan.candidates.append(candidate)
            case .skipped(.status): scan.skippedStatus += 1
            case .skipped(.mode): scan.skippedMode += 1
            case .skipped(.emptyText): scan.skippedEmptyText += 1
            case .skipped(.missingID): scan.skippedMissingID += 1
            case .skipped(.badDate): scan.skippedBadDate += 1
            }
        }
        scan.candidates.sort { lhs, rhs in
            lhs.record.timestamp != rhs.record.timestamp
                ? lhs.record.timestamp > rhs.record.timestamp
                : lhs.typelessID < rhs.typelessID
        }
        return scan
    }

    /// The Nevertype record id for a Typeless row id. A Typeless id that is a UUID is used as it is. Any other id
    /// maps to the first 16 bytes of SHA-256("typeless:" + id), used verbatim (no RFC 4122 version or variant bits),
    /// so the same row always gets the same id on every sync and on every Mac.
    static func recordID(forTypelessID id: String) -> UUID {
        if let uuid = UUID(uuidString: id) { return uuid }
        let b = [UInt8](SHA256.hash(data: Data("typeless:\(id)".utf8)).prefix(16))
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

// MARK: Merging

struct TypelessMergeResult {
    /// The history to keep: newest first, at most `cap` records. Identical to the input when nothing was added.
    var history: [DictationRecord]
    /// The imported-ids set to store.
    var importedIDs: Set<String>
    /// New records that are in `history`.
    var addedCount: Int
}

enum TypelessMerger {
    /// AppState keeps the latest 1,000 dictations.
    static let historyCap = 1000

    /// Folds `candidates` into `existing`.
    ///  - A Typeless id that is already in `importedIDs` is never added again, so a record the user deleted in
    ///    Nevertype stays deleted and a second sync adds nothing.
    ///  - A candidate whose record id is already in `existing` is not added either (it can happen if the ids store
    ///    was lost); its Typeless id is recorded as imported instead, so history never holds a duplicate id.
    ///  - The result is sorted newest first and trimmed to `cap`. Only candidates that survive the trim count as
    ///    imported; one that is too old to fit is simply considered again on the next sync.
    static func merge(existing: [DictationRecord], candidates: [TypelessCandidate], importedIDs: Set<String>, cap: Int = historyCap) -> TypelessMergeResult {
        var knownIDs = importedIDs
        let presentIDs = Set(existing.map(\.id))
        var seen = Set<UUID>()
        var fresh: [TypelessCandidate] = []
        for candidate in candidates {
            if importedIDs.contains(candidate.typelessID) { continue }
            if presentIDs.contains(candidate.record.id) {
                knownIDs.insert(candidate.typelessID)
                continue
            }
            if seen.insert(candidate.record.id).inserted { fresh.append(candidate) }
        }
        guard !fresh.isEmpty else {
            return TypelessMergeResult(history: existing, importedIDs: knownIDs, addedCount: 0)
        }

        // Newest first. A tie keeps existing records ahead of new ones, and each group keeps its own order.
        let combined = existing + fresh.map(\.record)
        let order = combined.indices.sorted { a, b in
            let ta = combined[a].timestamp
            let tb = combined[b].timestamp
            return ta != tb ? ta > tb : a < b
        }
        let kept = order.prefix(max(cap, 0)).map { combined[$0] }
        let keptIDs = Set(kept.map(\.id))

        var added = 0
        for candidate in fresh where keptIDs.contains(candidate.record.id) {
            knownIDs.insert(candidate.typelessID)
            added += 1
        }
        return TypelessMergeResult(history: added > 0 ? kept : existing, importedIDs: knownIDs, addedCount: added)
    }

    /// Gives the records that have no speaking time yet the one measured for them (`measured` is keyed by record id). A record
    /// that already has one is never changed. Returns how many records were updated.
    static func fillSpeakingTimes(in history: inout [DictationRecord], from measured: [UUID: Double]) -> Int {
        guard !measured.isEmpty else { return 0 }
        var updated = 0
        for index in history.indices where history[index].speakingSeconds == nil {
            if let seconds = measured[history[index].id] {
                history[index].speakingSeconds = seconds
                updated += 1
            }
        }
        return updated
    }
}

// MARK: Imported-ids store

/// The Typeless ids that were already imported, kept in a small JSON file so a re-sync never duplicates a record
/// and never brings back one the user deleted.
struct TypelessImportedIDStore {
    let url: URL

    private struct Payload: Codable {
        var version: Int
        var ids: [String]
    }

    /// An absent or unreadable file counts as "nothing imported yet".
    func load() -> Set<String> {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return [] }
        return Set(payload.ids)
    }

    func save(_ ids: Set<String>) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Payload(version: 1, ids: ids.sorted()))
        try data.write(to: url, options: .atomic)
    }
}

// MARK: Recordings (speaking time)

/// The audio Typeless keeps for each dictation, and the speaking time measured from it. Recordings are only ever read: a file is
/// opened read-only, decoded in chunks and closed, and nothing is copied, moved or changed.
enum TypelessRecordings {
    /// The audio file of a dictation: `storedPath` (its `audio_local_path`) when that is an absolute path that resolves to
    /// something inside `directory`, otherwise `<directory>/<id>.ogg`. nil when neither does. Whether the file exists is not
    /// checked here.
    ///
    /// A path is standardized (`.` and `..` removed) and its symbolic links are resolved before it is compared with the
    /// resolved `directory`, and the resolved path is what comes back, so a link or a `..` cannot lead out of the folder.
    static func audioURL(id: String, storedPath: String, in directory: URL) -> URL? {
        var candidates: [URL] = []
        let stored = storedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if stored.hasPrefix("/") { candidates.append(URL(fileURLWithPath: stored)) }
        candidates.append(directory.appendingPathComponent("\(id).ogg"))
        for candidate in candidates {
            if let inside = resolved(candidate, insideDirectory: directory) { return inside }
        }
        return nil
    }

    /// `url` standardized and with its symbolic links resolved, if that is a path below `directory` (never `directory` itself).
    private static func resolved(_ url: URL, insideDirectory directory: URL) -> URL? {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard target.path.hasPrefix(prefix), target.path.count > prefix.count else { return nil }
        return target
    }

    /// Measures the speaking time of the dictations that need one, from their recordings in `directory`:
    ///  - every eligible row not yet imported (`importedIDs`) that can still fit in a history of `historyCap` records, which
    ///    are the `historyCap` newest of them, because the sync will add those;
    ///  - every eligible row whose record is already in the history without a speaking time (`needing`, a set of record ids).
    ///
    /// Returns record id -> speaking seconds. A dictation whose file is missing, outside `directory` or cannot be decoded is
    /// left out: it stays unknown and is tried again by the next sync. Reads files, so call it off the main thread.
    ///
    /// `shouldContinue` is asked before each recording is looked at. When it says no, the loop stops and what was measured so
    /// far is returned; no further file is touched. `measureFile` measures one file (the self-tests replace it).
    static func measureSpeakingTimes(
        rows: [TypelessRow],
        importedIDs: Set<String>,
        needing: Set<UUID>,
        historyCap: Int,
        in directory: URL,
        shouldContinue: () -> Bool = { true },
        measureFile: (URL) -> SpeakingTimeMeter.Measurement? = { SpeakingTimeMeter.measure(fileAt: $0) }
    ) -> [UUID: Double] {
        let candidates = TypelessMapper.scan(rows).candidates
        let fresh = candidates.filter { !importedIDs.contains($0.typelessID) }.prefix(max(historyCap, 0))
        let backfill = candidates.filter { needing.contains($0.record.id) }
        guard !fresh.isEmpty || !backfill.isEmpty else { return [:] }

        let rowsByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var measured: [UUID: Double] = [:]
        var tried = Set<UUID>()
        for candidate in fresh + backfill {
            guard shouldContinue() else { break }
            guard tried.insert(candidate.record.id).inserted,
                  let row = rowsByID[candidate.typelessID],
                  let url = audioURL(id: row.id, storedPath: row.audioLocalPath, in: directory),
                  let measurement = measureFile(url) else { continue }
            measured[candidate.record.id] = measurement.speakingSeconds
        }
        return measured
    }
}

// MARK: Reading Typeless's database

struct TypelessReadError: Error, LocalizedError, CustomStringConvertible {
    let code: Int32
    let message: String

    var description: String { "\(message) (SQLite \(code))" }
    var errorDescription: String? { message }
}

struct TypelessReadOptions: Sendable {
    /// Pause before the retry of a failed direct read, and between attempts to copy a database that is still changing.
    var retryDelay: TimeInterval = 0.25
    /// How long SQLite itself waits on a busy or locked database before reporting an error.
    var busyTimeoutMs: Int32 = 750
    /// Skip the direct read and go straight to the private copy.
    var forceCopy = false
    /// Where the private copy is made.
    var tempRoot: URL = FileManager.default.temporaryDirectory
    /// Called after every attempt to copy the database, with the attempt number (0, 1, 2). Lets the self-tests make
    /// the source change while it is being copied.
    var afterCopyAttempt: (@Sendable (Int) -> Void)?
}

enum TypelessReadOutcome: Sendable {
    case missing
    case rows([TypelessRow], usedCopy: Bool)
}

enum TypelessDatabaseReader {
    /// The `history_v2` columns every version of Typeless has.
    private static let baseColumns = "id, status, mode, refined_text, duration, created_at"
    /// Where Typeless says it saved a dictation's audio. Not every version of Typeless has this column.
    private static let audioPathColumn = "audio_local_path"

    /// The query for the rows. The audio path column is left out when the table does not have it (an older Typeless, or a later
    /// one that dropped it): the import then works as before, with every recording path empty.
    static func selectSQL(withAudioPath: Bool) -> String {
        "SELECT \(baseColumns)\(withAudioPath ? ", \(audioPathColumn)" : "") FROM history_v2"
    }

    /// Reads every `history_v2` row. Returns `.missing` when there is no `typeless.db` (nothing to do).
    ///
    /// 1. Opens the database with SQLITE_OPEN_READONLY and reads it. SQLite shares a WAL-mode database with a running
    ///    Typeless through its own locking, and a read-only connection never changes the database file.
    /// 2. If that fails for any reason (busy, locked, a hot journal left by a crash, a WAL database SQLite cannot open
    ///    read-only, ...), tries once more.
    /// 3. If that fails too, copies `typeless.db` plus any `-journal` / `-wal` / `-shm` into a private temporary folder,
    ///    reads the copy and deletes the folder again. When both routes fail, the error from the direct read is thrown.
    ///
    /// Call this off the main thread: it blocks on file and database I/O.
    static func read(from dbURL: URL, options: TypelessReadOptions = TypelessReadOptions()) throws -> TypelessReadOutcome {
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return .missing }

        var directError: Error?
        if !options.forceCopy {
            for attempt in 0..<2 {
                do {
                    let rows = try query(dbURL, flags: SQLITE_OPEN_READONLY, busyTimeoutMs: options.busyTimeoutMs)
                    return .rows(rows, usedCopy: false)
                } catch {
                    directError = directError ?? error
                    if attempt == 0, options.retryDelay > 0 { Thread.sleep(forTimeInterval: options.retryDelay) }
                }
            }
        }
        do {
            return .rows(try queryCopy(of: dbURL, options: options), usedCopy: true)
        } catch {
            throw directError ?? error
        }
    }

    /// The files that make up one SQLite database, in the order they are copied.
    private static let databaseFileSuffixes = ["", "-journal", "-wal", "-shm"]

    /// Copies the database and its side files into a folder only this process uses, and reads the copy.
    ///
    /// - The `-journal` matters: after a crash, or while Typeless is writing, the main file can hold half of a
    ///   transaction that only the journal can undo. SQLite does the undo inside the copy (the real files are never
    ///   touched). Without the journal such a copy reads fine and `integrity_check` passes, but it shows data that was
    ///   never committed.
    /// - A copy that lost its `-shm` needs WAL recovery, which a read-only connection cannot do, and nobody else can
    ///   see the copy, so it is opened read-write.
    /// - Copying files is not atomic, so the copy is only trusted if the main, `-journal` and `-wal` files kept the
    ///   same inode, size and modification time while it was made (`-shm` is left out: readers touch it constantly,
    ///   and SQLite rebuilds it). Otherwise it is made again, and after three tries the read fails.
    /// - The folder is removed on every exit path.
    private static func queryCopy(of dbURL: URL, options: TypelessReadOptions) throws -> [TypelessRow] {
        let fm = FileManager.default
        let workDir = options.tempRoot.appendingPathComponent("typezero-typeless-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: workDir) }

        let name = dbURL.lastPathComponent
        func source(_ suffix: String) -> String { dbURL.path + suffix }
        func target(_ suffix: String) -> URL { workDir.appendingPathComponent(name + suffix) }
        func signature() -> [String] { ["", "-journal", "-wal"].map { fileSignature(source($0)) } }

        var stable = false
        for attempt in 0..<3 {
            for suffix in databaseFileSuffixes { try? fm.removeItem(at: target(suffix)) }
            let before = signature()
            for suffix in databaseFileSuffixes where fm.fileExists(atPath: source(suffix)) {
                try fm.copyItem(atPath: source(suffix), toPath: target(suffix).path)
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target(suffix).path)
            }
            options.afterCopyAttempt?(attempt)
            if signature() == before {
                stable = true
                break
            }
            if attempt < 2, options.retryDelay > 0 { Thread.sleep(forTimeInterval: options.retryDelay) }
        }
        guard stable else {
            throw TypelessReadError(code: SQLITE_BUSY, message: "typeless.db kept changing while it was being copied")
        }
        return try query(target(""), flags: SQLITE_OPEN_READWRITE, busyTimeoutMs: options.busyTimeoutMs)
    }

    /// Inode, size and modification time (to the nanosecond) of a file, or "absent".
    private static func fileSignature(_ path: String) -> String {
        var info = stat()
        guard stat(path, &info) == 0 else { return "absent" }
        return "\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
    }

    private static func query(_ url: URL, flags: Int32, busyTimeoutMs: Int32) throws -> [TypelessRow] {
        var handle: OpaquePointer?
        let openCode = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard openCode == SQLITE_OK, let db = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open the database"
            if let handle { sqlite3_close_v2(handle) }
            throw TypelessReadError(code: openCode, message: message)
        }
        defer { sqlite3_close_v2(db) }
        sqlite3_busy_timeout(db, busyTimeoutMs)

        let hasAudioPath = try historyColumnNames(db).contains(audioPathColumn)
        var prepared: OpaquePointer?
        let prepareCode = sqlite3_prepare_v2(db, selectSQL(withAudioPath: hasAudioPath), -1, &prepared, nil)
        guard prepareCode == SQLITE_OK, let statement = prepared else {
            throw TypelessReadError(code: prepareCode, message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        var rows: [TypelessRow] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                rows.append(TypelessRow(
                    id: text(statement, 0),
                    status: text(statement, 1),
                    mode: text(statement, 2),
                    refinedText: text(statement, 3),
                    duration: number(statement, 4),
                    createdAt: text(statement, 5),
                    audioLocalPath: hasAudioPath ? text(statement, 6) : ""
                ))
            } else if step == SQLITE_DONE {
                return rows
            } else {
                throw TypelessReadError(code: step, message: String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    /// The (lowercased) column names of `history_v2`, from `PRAGMA table_info`; empty when there is no such table (the query
    /// then fails and names it). A failure of the PRAGMA itself is an ordinary read error, so a busy or hot-journal database is
    /// retried and copied as before, never mistaken for a table that lacks a column.
    private static func historyColumnNames(_ db: OpaquePointer) throws -> Set<String> {
        var prepared: OpaquePointer?
        let prepareCode = sqlite3_prepare_v2(db, "PRAGMA table_info(history_v2)", -1, &prepared, nil)
        guard prepareCode == SQLITE_OK, let statement = prepared else {
            throw TypelessReadError(code: prepareCode, message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        var names = Set<String>()
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                names.insert(text(statement, 1).lowercased())
            } else if step == SQLITE_DONE {
                return names
            } else {
                throw TypelessReadError(code: step, message: String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL, let raw = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: raw)
    }

    private static func number(_ statement: OpaquePointer, _ column: Int32) -> Double {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? 0 : sqlite3_column_double(statement, column)
    }
}

// MARK: Sync

/// The part of `AppState` a sync touches. `AppState` conforms below; the self-tests use a fake, so they never go
/// near the real `history.json`.
@MainActor
protocol TypelessHistoryHost: AnyObject {
    var history: [DictationRecord] { get set }
    var statusBanner: String { get set }
    /// The opt-in switch (for AppState: `llmConfig.enableTypelessImport`, saved with the other settings). Off by default.
    var typelessImportEnabled: Bool { get set }
    /// Writes `history` to disk (for AppState: the same `history.json` it uses itself).
    func persistHistory()
}

extension AppState: TypelessHistoryHost {
    func persistHistory() { tzPersistHistory() }

    var typelessImportEnabled: Bool {
        get { llmConfig.enableTypelessImport }
        set { llmConfig.enableTypelessImport = newValue }
    }
}

enum TypelessSyncResult: Equatable, Sendable {
    case imported(Int)
    case upToDate
    case databaseMissing
    case failed(String)
    /// The import switch is off, so the database was not opened.
    case disabled

    /// Banner text in the main window's status style (a leading check mark or warning sign picks the icon).
    /// Automatic syncs stay quiet unless something was imported.
    func bannerText(manual: Bool) -> String? {
        switch self {
        case .imported(let count):
            return "✅ Synced \(TZStats.formatGrouped(count)) \(count == 1 ? "dictation" : "dictations") from Typeless"
        case .upToDate:
            return manual ? "✅ Typeless history is already up to date" : nil
        case .databaseMissing:
            return manual ? "Typeless history wasn't found on this Mac." : nil
        case .failed(let reason):
            return manual ? "⚠️ Couldn't read Typeless history: \(reason)" : nil
        case .disabled:
            return manual ? "Turn on “Import history from Typeless” in Settings first." : nil
        }
    }
}

/// Set on the main actor and read on a background thread, to tell a pass that is measuring recordings to stop. The thread
/// reads this, never the import switch itself, which belongs to the main actor.
private final class TypelessStopSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false

    var isRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    func set(_ value: Bool) {
        lock.lock()
        requested = value
        lock.unlock()
    }
}

/// Runs syncs one at a time: the database is read off the main thread, the result is merged into the history on the
/// main actor, then `history.json` and the imported-ids file are written.
///
/// Every sync, automatic or manual, first asks the host whether the user switched the import on. While it is off neither
/// the database nor the recordings are opened, and nothing is read or written. A pass that is already measuring recordings
/// when the switch is turned off (see `setImportEnabled`) opens no further one.
@MainActor
final class TypelessSyncCoordinator {
    static let shared = TypelessSyncCoordinator()

    struct Configuration {
        var databaseURL: URL = TypelessPaths.databaseURL
        /// The folder the dictations' audio files must be in to be measured.
        var recordingsURL: URL = TypelessPaths.recordingsURL
        var store = TypelessImportedIDStore(url: TypelessPaths.importedIDsURL)
        var readOptions = TypelessReadOptions()
        var historyCap = TypelessMerger.historyCap
        /// Reads the database. Replaced by the self-tests; always called off the main thread.
        var read: @Sendable (URL, TypelessReadOptions) throws -> TypelessReadOutcome = { url, options in
            try TypelessDatabaseReader.read(from: url, options: options)
        }
        /// Measures one recording. Replaced by the self-tests; always called off the main thread.
        var measureFile: @Sendable (URL) -> SpeakingTimeMeter.Measurement? = { SpeakingTimeMeter.measure(fileAt: $0) }
    }

    var configuration: Configuration
    private var running: Task<TypelessSyncResult, Never>?
    private var launchSyncStarted = false
    /// Set when the switch is turned off, cleared when a pass starts.
    private let stopSignal = TypelessStopSignal()

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    var isSyncing: Bool { running != nil }

    /// Syncs `host`'s history with Typeless. Returns the outcome, or nil when an automatic request was skipped
    /// because a sync was already running.
    ///
    /// A manual request that arrives while a sync is running waits for it and reports its outcome. Either kind posts
    /// its banner (see `TypelessSyncResult.bannerText`); an automatic one never replaces a banner already on screen,
    /// so it cannot hide a permission warning.
    @discardableResult
    func sync(into host: any TypelessHistoryHost, manual: Bool) async -> TypelessSyncResult? {
        guard host.typelessImportEnabled else {
            present(.disabled, manual: manual, on: host)
            return .disabled
        }
        if let current = running {
            guard manual else { return nil }
            let result = await current.value
            present(result, manual: true, on: host)
            return result
        }
        let task = Task { @MainActor [self] () -> TypelessSyncResult in
            let result = await runPass(into: host)
            running = nil
            return result
        }
        running = task
        let result = await task.value
        present(result, manual: manual, on: host)
        return result
    }

    /// The sync that runs once per launch, when the main window first appears. Later calls do nothing. While the import
    /// switch is off it does nothing either (and the database is not opened).
    func syncOnLaunch(into host: any TypelessHistoryHost) async {
        guard !launchSyncStarted else { return }
        launchSyncStarted = true
        await sync(into: host, manual: false)
    }

    /// Flips the import switch. Turning it on runs one import right away, as a manual sync, so its outcome shows in the
    /// status banner; the returned task is that import. Turning it off clears the switch, so nothing opens the database
    /// again, and tells a pass that is measuring recordings to stop before it opens the next one.
    @discardableResult
    func setImportEnabled(_ enabled: Bool, on host: any TypelessHistoryHost) -> Task<TypelessSyncResult?, Never>? {
        host.typelessImportEnabled = enabled
        guard enabled else {
            stopSignal.set(true)
            return nil
        }
        return Task { @MainActor [self] in await sync(into: host, manual: true) }
    }

    private func present(_ result: TypelessSyncResult, manual: Bool, on host: any TypelessHistoryHost) {
        guard let text = result.bannerText(manual: manual) else { return }
        if manual || host.statusBanner.isEmpty { host.statusBanner = text }
    }

    /// Reads the database and measures the missing speaking times, both off the main thread, then merges on the main actor.
    private func runPass(into host: any TypelessHistoryHost) async -> TypelessSyncResult {
        // The switch may have been turned off since this pass was requested. Looked at before the stop signal is cleared below,
        // so that a request made in that gap is not lost: nothing is opened at all then.
        guard host.typelessImportEnabled else { return .disabled }
        let config = configuration
        // A pass starts with no stop request. Turning the switch off while it runs sets one (`setImportEnabled`), and the
        // measuring below, which is off the main thread, looks at that instead of at the switch.
        let stop = stopSignal
        stop.set(false)
        // Records already in the history that have no speaking time yet: their recordings are measured along with the new ones.
        let needing = Set(host.history.filter { $0.speakingSeconds == nil }.map(\.id))
        let outcome: Result<(TypelessReadOutcome, [UUID: Double]), Error> = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Result {
                    let outcome = try config.read(config.databaseURL, config.readOptions)
                    guard case .rows(let rows, _) = outcome else { return (outcome, [:]) }
                    let measured = TypelessRecordings.measureSpeakingTimes(
                        rows: rows,
                        importedIDs: config.store.load(),
                        needing: needing,
                        historyCap: config.historyCap,
                        in: config.recordingsURL,
                        shouldContinue: { !stop.isRequested },
                        measureFile: config.measureFile
                    )
                    return (outcome, measured)
                })
            }
        }
        // The switch may have been turned off while the database was being read: honor the latest choice.
        guard host.typelessImportEnabled else { return .disabled }
        switch outcome {
        case .failure(let error): return .failed(error.localizedDescription)
        case .success((.missing, _)): return .databaseMissing
        case .success((.rows(let rows, _), let measured)): return apply(rows: rows, speakingSeconds: measured, to: host)
        }
    }

    /// Merges `rows` into `host.history` and sets the speaking times in `speakingSeconds` (record id -> seconds) on the new
    /// records and on records that have none yet. History is written before the imported-ids file: if the app stops in
    /// between, the next sync finds the records already in history and only records their ids, rather than losing them.
    ///
    /// A pass that only filled in speaking times still writes the history, but reports `.upToDate`: nothing was imported, so
    /// it gets no "Synced N dictations" banner.
    func apply(rows: [TypelessRow], speakingSeconds: [UUID: Double] = [:], to host: any TypelessHistoryHost) -> TypelessSyncResult {
        let store = configuration.store
        let known = store.load()
        let scan = TypelessMapper.scan(rows)
        let candidates = scan.candidates.map { candidate -> TypelessCandidate in
            guard let seconds = speakingSeconds[candidate.record.id] else { return candidate }
            var record = candidate.record
            record.speakingSeconds = seconds
            return TypelessCandidate(typelessID: candidate.typelessID, record: record)
        }
        let merged = TypelessMerger.merge(
            existing: host.history,
            candidates: candidates,
            importedIDs: known,
            cap: configuration.historyCap
        )
        var history = merged.addedCount > 0 ? merged.history : host.history
        let filled = TypelessMerger.fillSpeakingTimes(in: &history, from: speakingSeconds)
        if merged.addedCount > 0 || filled > 0 {
            host.history = history
            host.persistHistory()
        }
        if merged.importedIDs != known {
            try? store.save(merged.importedIDs)
        }
        return merged.addedCount > 0 ? .imported(merged.addedCount) : .upToDate
    }
}

// MARK: Dry run

enum TypelessHistoryImporter {
    /// The lines `--typeless-import-dry-run` prints, and its exit status. Counts only: no record text, no ids.
    /// Reads `databaseURL` and `store` and writes nothing.
    static func dryRunReport(
        databaseURL: URL,
        store: TypelessImportedIDStore,
        options: TypelessReadOptions = TypelessReadOptions()
    ) -> (lines: [String], status: Int32) {
        var lines = ["==> Typeless import dry run (read-only: nothing is imported or written)"]
        let outcome: TypelessReadOutcome
        do {
            outcome = try TypelessDatabaseReader.read(from: databaseURL, options: options)
        } catch {
            lines.append("  ✗ Could not read typeless.db: \(error.localizedDescription)")
            return (lines, 1)
        }
        switch outcome {
        case .missing:
            lines.append("  typeless.db was not found; a sync would do nothing.")
        case .rows(let rows, let usedCopy):
            let scan = TypelessMapper.scan(rows)
            let imported = store.load()
            let alreadyImported = scan.candidates.filter { imported.contains($0.typelessID) }.count
            lines.append("  Read method:        \(usedCopy ? "temporary copy (direct read-only open failed)" : "direct read-only open")")
            lines.append("  Total rows:         \(scan.totalRows)")
            lines.append("  Eligible rows:      \(scan.eligibleCount)  (completed voice_transcript with text)")
            lines.append("  Already imported:   \(alreadyImported)")
            lines.append("  Would import now:   \(scan.eligibleCount - alreadyImported)")
            lines.append("  Skipped rows:       \(scan.skippedStatus) not completed, \(scan.skippedMode) not voice_transcript, \(scan.skippedEmptyText) empty text, \(scan.skippedMissingID) without id, \(scan.skippedBadDate) with unreadable date")
        }
        return (lines, 0)
    }

    /// `Nevertype --typeless-import-dry-run`: reads the real typeless.db read-only and prints counts only. It writes
    /// nothing, and does not look at history.json or any record text.
    static func runDryRun() -> Int32 {
        let report = dryRunReport(
            databaseURL: TypelessPaths.databaseURL,
            store: TypelessImportedIDStore(url: TypelessPaths.importedIDsURL)
        )
        for line in report.lines { print(line) }
        return report.status
    }
}
