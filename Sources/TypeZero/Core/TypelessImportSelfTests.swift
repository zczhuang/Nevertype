import Foundation
import CryptoKit
import SQLite3

/// Self-tests for the Typeless importer. They run as the third suite of `Nevertype --self-test`.
///
/// Everything happens in a throw-away folder under the system temp directory. Every path the code under test reads or
/// writes is passed in explicitly (database, imported-ids file, copy folder), `TypelessSyncCoordinator.shared` is never
/// used, and syncs run against a fake `TypelessHistoryHost` instead of a real `AppState`, so the suite cannot reach the
/// real history.json, the real imported-ids file or Typeless's database.
///
/// As a second guard the suite points the process's home folder at the sandbox, so an accidental use of a default
/// location would land there too. That takes `CFFIXED_USER_HOME`, the variable Foundation honours (as `TZRenderUI`
/// does); plain `HOME` is ignored by `FileManager`. `pathTests` checks that the redirect is really in effect.
enum TypelessImportSelfTests {
    private final class Checker {
        var passed = 0
        var failed = 0

        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            if condition() {
                passed += 1
                print("  ✓ PASS: \(label)")
            } else {
                failed += 1
                print("  ✗ FAIL: \(label)")
            }
        }
    }

    static func runAll() -> Int32 {
        let t = Checker()
        print("==> Running Typeless import suite...")

        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appendingPathComponent("typezero-typeless-selftest-\(UUID().uuidString)", isDirectory: true)
        let home = sandbox.appendingPathComponent("home", isDirectory: true)
        try? fm.createDirectory(at: home, withIntermediateDirectories: true)
        let homeVariables = ["HOME", "CFFIXED_USER_HOME"]
        let savedHome = homeVariables.map { (name: $0, value: getenv($0).map { String(cString: $0) }) }
        for name in homeVariables { setenv(name, home.path, 1) }
        defer {
            for saved in savedHome {
                if let value = saved.value { setenv(saved.name, value, 1) } else { unsetenv(saved.name) }
            }
            try? fm.removeItem(at: sandbox)
        }

        pathTests(t, home: home)
        dateAndIDTests(t)
        filterAndMappingTests(t)
        databaseTests(t, sandbox: sandbox)
        mergeTests(t)
        storeTests(t, sandbox: sandbox)
        bannerTests(t)
        syncPassTests(t, sandbox: sandbox)
        asyncSyncTests(t, sandbox: sandbox)
        optInTests(t, sandbox: sandbox)
        dryRunTests(t, sandbox: sandbox)

        print("==> Typeless import summary: \(t.passed) passed, \(t.failed) failed.")
        return t.failed == 0 ? 0 : 1
    }

    // MARK: - Fixture data

    private struct FixtureRow {
        var id: String
        var status = "completed"
        var mode = "voice_transcript"
        var text: String?
        var duration: Double? = 3
        var createdAt = "2026-11-24T12:00:00.000Z"
    }

    /// 11 rows: 4 importable, 7 that every filter must reject.
    private static let canonicalRows: [FixtureRow] = [
        FixtureRow(id: "9F1B7C52-3D2A-4E7B-8C11-0A5D6E7F8091", text: "Hello from Typeless.", duration: 4.5, createdAt: "2026-11-24T21:21:24.992Z"),
        FixtureRow(id: "row-two", text: "Second dictation", duration: 12, createdAt: "2026-11-24T20:00:00.000Z"),
        FixtureRow(id: "row-three", text: "  padded with spaces  \n", duration: 1.25, createdAt: "2026-11-23T08:30:15.500Z"),
        FixtureRow(id: "noms-1", text: "no fractional seconds", duration: 3, createdAt: "2026-11-22T10:00:00Z"),
        FixtureRow(id: "dismissed-1", status: "dismissed", text: "dismissed text", createdAt: "2026-11-24T19:00:00.000Z"),
        FixtureRow(id: "command-1", mode: "voice_command", text: "voice command text", createdAt: "2026-11-24T18:00:00.000Z"),
        FixtureRow(id: "empty-1", text: ""),
        FixtureRow(id: "blank-1", text: " \n\t "),
        FixtureRow(id: "null-1", text: nil, duration: nil),
        FixtureRow(id: "baddate-1", text: "has text", createdAt: "yesterday-ish"),
        FixtureRow(id: "", text: "row without an id")
    ]

    /// Fixture rows as `TypelessDatabaseReader` returns them.
    private static func readerRows(_ rows: [FixtureRow]) -> [TypelessRow] {
        rows.map {
            TypelessRow(id: $0.id, status: $0.status, mode: $0.mode, refinedText: $0.text ?? "", duration: $0.duration ?? 0, createdAt: $0.createdAt)
        }
    }

    private static func record(_ epoch: Double, _ text: String, id: UUID = UUID(), app: String = "Notes") -> DictationRecord {
        DictationRecord(
            id: id,
            timestamp: Date(timeIntervalSince1970: epoch),
            rawTranscript: text,
            polishedText: text,
            durationSeconds: 1,
            polishLatencyMs: 0,
            targetAppName: app
        )
    }

    private static func candidate(_ typelessID: String, _ epoch: Double, _ text: String) -> TypelessCandidate {
        TypelessCandidate(typelessID: typelessID, record: record(epoch, text, id: TypelessMapper.recordID(forTypelessID: typelessID), app: TypelessMapper.appName))
    }

    // MARK: - SQLite fixture

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static let schema = """
    CREATE TABLE history_v2 (
        id text PRIMARY KEY NOT NULL,
        status text NOT NULL,
        mode text NOT NULL,
        refined_text text,
        duration real,
        created_at text NOT NULL,
        updated_at text,
        audio_local_path text,
        audio_metadata text,
        debug_info text,
        mode_meta text,
        client_metadata text,
        audio_context text,
        server_updated_at text,
        sync_status text,
        sync_attempt_count integer DEFAULT 0,
        synced_from_cloud integer DEFAULT 0
    );
    CREATE TABLE history (id text PRIMARY KEY NOT NULL, text text, created_at text);
    """

    /// A throw-away copy of Typeless's database layout. Keep the object alive to keep its connection open.
    private final class FixtureDB {
        let url: URL
        private var handle: OpaquePointer?

        init?(url: URL, wal: Bool, rows: [FixtureRow], legacyRows: Int = 0, createHistoryV2: Bool = true) {
            self.url = url
            guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else { return nil }
            if wal, !exec("PRAGMA journal_mode=WAL;") { return nil }
            if createHistoryV2 {
                guard exec(TypelessImportSelfTests.schema) else { return nil }
            } else {
                guard exec("CREATE TABLE unrelated (x integer);") else { return nil }
            }
            for index in 0..<legacyRows {
                guard exec("INSERT INTO history (id, text, created_at) VALUES ('legacy-\(index)', 'legacy text', '2026-11-01T00:00:00.000Z');") else { return nil }
            }
            for row in rows where !insert(row) { return nil }
        }

        deinit { close() }

        @discardableResult
        func exec(_ sql: String) -> Bool {
            sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK
        }

        @discardableResult
        func insert(_ row: FixtureRow) -> Bool {
            let sql = """
            INSERT INTO history_v2 (id, status, mode, refined_text, duration, created_at, updated_at, debug_info, mode_meta, audio_context, sync_status)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6, ?7, '{}', 'encrypted-blob', 'synced')
            """
            var prepared: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &prepared, nil) == SQLITE_OK, let statement = prepared else { return false }
            defer { sqlite3_finalize(statement) }
            let transient = TypelessImportSelfTests.sqliteTransient
            sqlite3_bind_text(statement, 1, row.id, -1, transient)
            sqlite3_bind_text(statement, 2, row.status, -1, transient)
            sqlite3_bind_text(statement, 3, row.mode, -1, transient)
            if let text = row.text { sqlite3_bind_text(statement, 4, text, -1, transient) } else { sqlite3_bind_null(statement, 4) }
            if let duration = row.duration { sqlite3_bind_double(statement, 5, duration) } else { sqlite3_bind_null(statement, 5) }
            sqlite3_bind_text(statement, 6, row.createdAt, -1, transient)
            sqlite3_bind_text(statement, 7, String(repeating: "debug-info ", count: 40), -1, transient)
            return sqlite3_step(statement) == SQLITE_DONE
        }

        /// Adds `count` committed rows ("committed N ...") in one statement.
        @discardableResult
        func insertBulk(count: Int) -> Bool {
            exec("""
            WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < \(count))
            INSERT INTO history_v2 (id, status, mode, refined_text, duration, created_at)
            SELECT printf('bulk-%05d', x), 'completed', 'voice_transcript', 'committed ' || x || ' ' || hex(zeroblob(100)), 1.0, '2026-11-24T10:00:00.000Z' FROM c;
            """)
        }

        /// Starts a write transaction that never commits, with a tiny cache and spilling forced on so SQLite writes
        /// the half-finished changes into the main file. Its rollback journal is what could undo them.
        /// (`cache_size` alone is not enough with the system SQLite: the main file stays untouched until commit.)
        @discardableResult
        func beginSpillingTransaction() -> Bool {
            exec("PRAGMA cache_size=2;") && exec("PRAGMA cache_spill=1;") && exec("BEGIN;")
                && exec("UPDATE history_v2 SET refined_text = 'UNCOMMITTED ' || id || ' ' || hex(zeroblob(100));")
        }

        func close() {
            if let handle { sqlite3_close_v2(handle) }
            handle = nil
        }
    }

    private static func fingerprint(ofFile url: URL) -> String {
        let data = (try? Data(contentsOf: url)) ?? Data()
        let modified = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "\(data.count):\(digest):\(modified)"
    }

    /// File name -> size, SHA-256 and modification time, for every file in `directory`.
    private static func fingerprint(ofDirectory directory: URL) -> [String: String] {
        var result: [String: String] = [:]
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []) {
            result[name] = fingerprint(ofFile: directory.appendingPathComponent(name))
        }
        return result
    }

    private static func fileNames(in directory: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
    }

    private static func isWALDatabase(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 20), header.count == 20 else { return false }
        return header[18] == 2 && header[19] == 2
    }

    private static func makeDirectory(_ parent: URL, _ name: String) -> URL {
        let url = parent.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Reader options for tests: no pause before the retry, copies made under `tempRoot`.
    private static func readOptions(tempRoot: URL, forceCopy: Bool = false) -> TypelessReadOptions {
        var options = TypelessReadOptions()
        options.retryDelay = 0
        options.busyTimeoutMs = 100
        options.forceCopy = forceCopy
        options.tempRoot = tempRoot
        return options
    }

    // MARK: - Fake host and async helpers

    @MainActor
    private final class FakeHost: TypelessHistoryHost {
        var history: [DictationRecord]
        var statusBanner = ""
        var typelessImportEnabled: Bool
        private(set) var persistCount = 0
        var onPersist: (() -> Void)?

        /// The sync tests check the sync itself, so a host starts with the import switched on; the opt-in tests pass `false`.
        init(history: [DictationRecord] = [], importEnabled: Bool = true) {
            self.history = history
            self.typelessImportEnabled = importEnabled
        }

        func persistHistory() {
            persistCount += 1
            onPersist?()
        }
    }

    private final class Box<Value>: @unchecked Sendable {
        var value: Value
        var done = false
        init(_ value: Value) { self.value = value }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    /// Runs `body` on the main actor and spins the main run loop until it finishes (or 20 s pass).
    private static func runOnMain<Value>(_ initial: Value, _ body: @escaping @MainActor @Sendable () async -> Value) -> Value {
        let box = Box(initial)
        Task { @MainActor in
            box.value = await body()
            box.done = true
        }
        pump(until: { box.done })
        return box.value
    }

    private static func pump(timeout: TimeInterval = 20, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }

    // MARK: - Paths

    /// Only builds the default URLs and looks at their text; nothing is read or written.
    private static func pathTests(_ t: Checker, home: URL) {
        let database = TypelessPaths.databaseURL.path
        let ids = TypelessPaths.importedIDsURL.path
        t.expect(database.hasSuffix("/Library/Application Support/Typeless/typeless.db"), "Typeless database path is Application Support/Typeless/typeless.db")
        t.expect(ids.hasSuffix("/Library/Application Support/Nevertype/typeless-imported-ids.json"), "imported-ids file sits in Nevertype's Application Support folder")
        t.expect(TypelessPaths.importedIDsURL.deletingLastPathComponent().lastPathComponent == AppBrand.name && ids != database, "imported-ids file is next to history.json, not inside Typeless's folder")
        t.expect(database.hasPrefix(home.path) && ids.hasPrefix(home.path), "guard rail: while the suite runs, the default paths point into the sandbox, not the real home folder")

        // `databaseExists` (what decides whether Settings offers the switch) is a plain existence check, inside the sandbox only.
        if database.hasPrefix(home.path) {
            let fm = FileManager.default
            let typelessDir = TypelessPaths.databaseURL.deletingLastPathComponent()
            let before = TypelessPaths.databaseExists
            try? fm.createDirectory(at: typelessDir, withIntermediateDirectories: true)
            fm.createFile(atPath: TypelessPaths.databaseURL.path, contents: Data("not even a database".utf8))
            let whilePresent = TypelessPaths.databaseExists
            try? fm.removeItem(at: typelessDir)
            t.expect(!before && whilePresent && !TypelessPaths.databaseExists, "databaseExists follows the file: absent, present, absent again (it never opens it: the placeholder is not a database)")
        }
    }

    // MARK: - Dates and ids

    private static func dateAndIDTests(_ t: Checker) {
        let parser = TypelessDateParser()
        func epoch(_ text: String) -> Double? { parser.parse(text)?.timeIntervalSince1970 }
        func near(_ value: Double?, _ expected: Double) -> Bool { value.map { abs($0 - expected) < 0.0005 } ?? false }

        t.expect(near(epoch("2026-11-24T21:21:24.992Z"), 1795555284.992), "created_at with milliseconds and Z parses, milliseconds kept")
        t.expect(near(epoch("2026-11-22T10:00:00Z"), 1795341600), "created_at without fractional seconds parses")
        t.expect(near(epoch("  2026-11-23T08:30:15.500Z\n"), 1795422615.5), "created_at is trimmed before parsing")
        t.expect(near(epoch("2026-11-24T21:21:24.992+08:00"), 1795555284.992 - 8 * 3600), "a numeric UTC offset is honoured")
        t.expect(epoch("") == nil && epoch("   ") == nil, "empty created_at does not parse")
        t.expect(epoch("not a date") == nil && epoch("2026-13-45T99:00:00Z") == nil, "garbage created_at does not parse")

        let uuidText = "9F1B7C52-3D2A-4E7B-8C11-0A5D6E7F8091"
        let uuid = UUID(uuidString: uuidText)
        t.expect(TypelessMapper.recordID(forTypelessID: uuidText) == uuid, "a Typeless id that is a UUID is used as the record id")
        t.expect(TypelessMapper.recordID(forTypelessID: uuidText.lowercased()) == uuid, "a lowercase UUID id maps to the same record id")
        // Expected values come from `printf 'typeless:<id>' | shasum -a 256`, first 16 bytes of the digest.
        t.expect(TypelessMapper.recordID(forTypelessID: "row-two") == UUID(uuidString: "D4B550A0-DFAA-E0AE-5034-B4BD3C43BDA1"), "a non-UUID id maps to the first 16 bytes of SHA-256(\"typeless:\" + id)")
        t.expect(TypelessMapper.recordID(forTypelessID: "ABC123") == UUID(uuidString: "8F2EF766-49FA-6600-26D6-5266DDA81760"), "the SHA-256 derived id is stable (second sample)")
        t.expect(TypelessMapper.recordID(forTypelessID: "row-two") == TypelessMapper.recordID(forTypelessID: "row-two"), "the same id always maps to the same record id")
        t.expect(TypelessMapper.recordID(forTypelessID: "row-two") != TypelessMapper.recordID(forTypelessID: "row-three"), "different ids map to different record ids")
    }

    // MARK: - Filters and mapping

    private static func filterAndMappingTests(_ t: Checker) {
        let parser = TypelessDateParser()
        let base = TypelessRow(id: "row-two", status: "completed", mode: "voice_transcript", refinedText: "Second dictation", duration: 12, createdAt: "2026-11-24T20:00:00.000Z")

        func skip(_ edit: (inout TypelessRow) -> Void) -> TypelessMapper.Skip? {
            var row = base
            edit(&row)
            if case .skipped(let reason) = TypelessMapper.verdict(for: row, dateParser: parser) { return reason }
            return nil
        }

        if case .eligible(let candidate) = TypelessMapper.verdict(for: base, dateParser: parser) {
            let record = candidate.record
            t.expect(candidate.typelessID == "row-two" && record.id == UUID(uuidString: "D4B550A0-DFAA-E0AE-5034-B4BD3C43BDA1"), "mapping: id is derived from the Typeless id")
            t.expect(record.rawTranscript == "Second dictation" && record.polishedText == "Second dictation", "mapping: raw and polished text are both refined_text")
            t.expect(record.durationSeconds == 12 && record.polishLatencyMs == 0, "mapping: duration is kept and polish latency is 0")
            t.expect(record.targetAppName == "Typeless" && record.mode == .dictate && record.matchedTerms.isEmpty, "mapping: app is Typeless, mode is dictation, no matched terms")
            t.expect(abs(record.timestamp.timeIntervalSince1970 - 1795550400) < 0.0005, "mapping: timestamp comes from created_at")
        } else {
            t.expect(false, "a completed voice_transcript row with text is eligible")
        }

        t.expect(skip { $0.status = "dismissed" } == .status, "filter: dismissed rows are skipped")
        t.expect(skip { $0.status = "processing" } == .status, "filter: rows that are not completed are skipped")
        t.expect(skip { $0.mode = "voice_command" } == .mode, "filter: voice_command rows are skipped")
        t.expect(skip { $0.refinedText = "" } == .emptyText, "filter: empty text is skipped")
        t.expect(skip { $0.refinedText = " \n\t " } == .emptyText, "filter: whitespace-only text is skipped")
        t.expect(skip { $0.id = "" } == .missingID, "filter: a row without an id is skipped")
        t.expect(skip { $0.createdAt = "soon" } == .badDate, "filter: a row with an unreadable date is skipped")
        t.expect(skip { $0.duration = 7 } == nil && skip { $0.refinedText = "  keep my spaces \n" } == nil, "filter: ordinary variations stay eligible")

        var padded = base
        padded.refinedText = "  keep my spaces \n"
        if case .eligible(let candidate) = TypelessMapper.verdict(for: padded, dateParser: parser) {
            t.expect(candidate.record.polishedText == "  keep my spaces \n" && candidate.record.rawTranscript == "  keep my spaces \n", "mapping: text is stored exactly as Typeless has it (only the emptiness check trims)")
        } else {
            t.expect(false, "padded text stays eligible")
        }

        var zero = base
        zero.duration = 0
        if case .eligible(let candidate) = TypelessMapper.verdict(for: zero, dateParser: parser) {
            t.expect(candidate.record.durationSeconds >= 0.2, "mapping: a zero or missing duration is clamped by DictationRecord")
        } else {
            t.expect(false, "a zero-duration row stays eligible")
        }

        let scan = TypelessMapper.scan(readerRows(canonicalRows))
        t.expect(scan.totalRows == 11 && scan.eligibleCount == 4, "scan: 11 rows, 4 eligible")
        t.expect(scan.skippedStatus == 1 && scan.skippedMode == 1 && scan.skippedEmptyText == 3 && scan.skippedMissingID == 1 && scan.skippedBadDate == 1, "scan: every rejected row is counted under exactly one reason")
        t.expect(scan.candidates.map(\.typelessID) == ["9F1B7C52-3D2A-4E7B-8C11-0A5D6E7F8091", "row-two", "row-three", "noms-1"], "scan: candidates come back newest first")
    }

    // MARK: - Reading the database

    private static func databaseTests(_ t: Checker, sandbox: URL) {
        let fm = FileManager.default

        // Rollback-journal database (what Typeless's file looks like today), with rows in the legacy table too.
        do {
            let dir = makeDirectory(sandbox, "db-rollback")
            let tempRoot = makeDirectory(sandbox, "db-rollback-tmp")
            let url = dir.appendingPathComponent("typeless.db")
            if let fixture = FixtureDB(url: url, wal: false, rows: canonicalRows, legacyRows: 3) {
                fixture.close()
                let before = fingerprint(ofDirectory: dir)
                let outcome = try? TypelessDatabaseReader.read(from: url, options: readOptions(tempRoot: tempRoot))
                if case .rows(let rows, let usedCopy)? = outcome {
                    t.expect(rows.count == 11 && !usedCopy, "reader: reads all 11 history_v2 rows with a direct read-only open")
                    t.expect(!rows.contains { $0.id.hasPrefix("legacy-") }, "reader: rows of the legacy history table are ignored")
                    let hello = rows.first { $0.id == "9F1B7C52-3D2A-4E7B-8C11-0A5D6E7F8091" }
                    t.expect(hello?.refinedText == "Hello from Typeless." && hello?.duration == 4.5 && hello?.createdAt == "2026-11-24T21:21:24.992Z" && hello?.status == "completed" && hello?.mode == "voice_transcript", "reader: columns come back intact")
                    let null = rows.first { $0.id == "null-1" }
                    t.expect(null?.refinedText == "" && null?.duration == 0, "reader: NULL text and duration come back as empty and 0")
                } else {
                    t.expect(false, "reader: reads a rollback-journal database")
                }
                t.expect(fingerprint(ofDirectory: dir) == before, "reader: the source folder is byte-for-byte unchanged (no new files, no changed file)")
                t.expect(fileNames(in: tempRoot).isEmpty, "reader: a direct read makes no temporary copy")
            } else {
                t.expect(false, "fixture: rollback-journal database could be created")
            }
        }

        // WAL database with the writer (Typeless) still running and a row that exists only in the -wal file.
        do {
            let dir = makeDirectory(sandbox, "db-wal-live")
            let tempRoot = makeDirectory(sandbox, "db-wal-live-tmp")
            let url = dir.appendingPathComponent("typeless.db")
            if let writer = FixtureDB(url: url, wal: true, rows: canonicalRows) {
                writer.insert(FixtureRow(id: "wal-only", text: "only in the WAL", createdAt: "2026-11-24T22:00:00.000Z"))
                t.expect(isWALDatabase(url), "fixture: the database is in WAL mode")
                t.expect(fileNames(in: dir).contains("typeless.db-wal"), "fixture: a -wal file exists while the writer is open")
                let namesBefore = fileNames(in: dir)
                let mainBefore = fingerprint(ofFile: url)

                let direct = try? TypelessDatabaseReader.read(from: url, options: readOptions(tempRoot: tempRoot))
                if case .rows(let rows, let usedCopy)? = direct {
                    t.expect(rows.count == 12 && rows.contains { $0.id == "wal-only" } && !usedCopy, "reader: a live WAL database is read directly and includes rows that are only in the -wal file")
                } else {
                    t.expect(false, "reader: reads a WAL database while its writer is open")
                }
                t.expect(fingerprint(ofFile: url) == mainBefore && fileNames(in: dir) == namesBefore, "reader: the live database file is unchanged and no file was added next to it")

                let copied = try? TypelessDatabaseReader.read(from: url, options: readOptions(tempRoot: tempRoot, forceCopy: true))
                if case .rows(let rows, let usedCopy)? = copied {
                    t.expect(usedCopy && rows.count == 12 && rows.contains { $0.id == "wal-only" }, "fallback: the copy includes the -wal rows")
                } else {
                    t.expect(false, "fallback: reads a copy of a live WAL database")
                }
                t.expect(fileNames(in: tempRoot).isEmpty, "fallback: the temporary copy is deleted afterwards")
                t.expect(fingerprint(ofFile: url) == mainBefore && fileNames(in: dir) == namesBefore, "fallback: copying leaves the live database file and its folder unchanged")
                writer.close()
            } else {
                t.expect(false, "fixture: WAL database could be created")
            }
        }

        // WAL database whose -wal / -shm are gone (Typeless closed). A read-only open cannot work without them.
        do {
            let dir = makeDirectory(sandbox, "db-wal-idle")
            let tempRoot = makeDirectory(sandbox, "db-wal-idle-tmp")
            let url = dir.appendingPathComponent("typeless.db")
            if let writer = FixtureDB(url: url, wal: true, rows: canonicalRows) {
                writer.exec("PRAGMA wal_checkpoint(TRUNCATE);")
                writer.close()
                for suffix in ["-wal", "-shm"] { try? fm.removeItem(atPath: url.path + suffix) }
                t.expect(isWALDatabase(url) && fileNames(in: dir) == ["typeless.db"], "fixture: a WAL-mode database file with no -wal / -shm next to it")
                let before = fingerprint(ofDirectory: dir)
                let outcome = try? TypelessDatabaseReader.read(from: url, options: readOptions(tempRoot: tempRoot))
                if case .rows(let rows, _)? = outcome {
                    t.expect(rows.count == 11, "reader: an idle WAL database is readable (directly, or through the copy fallback)")
                } else {
                    t.expect(false, "reader: reads an idle WAL database")
                }
                t.expect(fingerprint(ofDirectory: dir) == before, "reader: reading an idle WAL database creates no -wal / -shm files in the source folder")
                t.expect(fileNames(in: tempRoot).isEmpty, "reader: no temporary copy is left behind")
            } else {
                t.expect(false, "fixture: idle WAL database could be created")
            }
        }

        // Typeless crashed (or the copy is made mid-write): main file holds half a transaction, the -journal can undo it.
        do {
            let liveDir = makeDirectory(sandbox, "db-hot-live")
            let crashedDir = makeDirectory(sandbox, "db-hot-crashed")
            let tempRoot = makeDirectory(sandbox, "db-hot-tmp")
            let liveURL = liveDir.appendingPathComponent("typeless.db")
            if let writer = FixtureDB(url: liveURL, wal: false, rows: []), writer.insertBulk(count: 1500) {
                let committed = fingerprint(ofFile: liveURL)
                writer.beginSpillingTransaction()
                let journalURL = URL(fileURLWithPath: liveURL.path + "-journal")
                t.expect(fm.fileExists(atPath: journalURL.path) && fingerprint(ofFile: liveURL) != committed, "fixture: an open transaction left a rollback journal and a half-written main file")
                for suffix in ["", "-journal"] {
                    try? fm.copyItem(atPath: liveURL.path + suffix, toPath: crashedDir.appendingPathComponent("typeless.db" + suffix).path)
                }
                writer.exec("ROLLBACK;")
                writer.close()

                let crashedURL = crashedDir.appendingPathComponent("typeless.db")
                let before = fingerprint(ofDirectory: crashedDir)
                let outcome = try? TypelessDatabaseReader.read(from: crashedURL, options: readOptions(tempRoot: tempRoot))
                if case .rows(let rows, let usedCopy)? = outcome {
                    t.expect(usedCopy, "journal: a database with a hot journal cannot be read read-only, so the copy fallback is used")
                    t.expect(rows.count == 1500 && rows.allSatisfy { $0.refinedText.hasPrefix("committed ") }, "journal: the copy includes the -journal, so only committed rows come back (nothing half-written)")
                } else {
                    t.expect(false, "journal: reads a database that has a hot journal")
                }
                t.expect(fingerprint(ofDirectory: crashedDir) == before, "journal: the source (including its journal) is left exactly as it was")
                t.expect(fileNames(in: tempRoot).isEmpty, "journal: the copy is deleted afterwards")
            } else {
                t.expect(false, "fixture: database for the hot-journal test could be created")
            }
        }

        // The source changes while it is being copied: the copy is made again; if it never settles, the read fails.
        do {
            let dir = makeDirectory(sandbox, "db-changing")
            let tempRoot = makeDirectory(sandbox, "db-changing-tmp")
            let url = dir.appendingPathComponent("typeless.db")
            if let fixture = FixtureDB(url: url, wal: false, rows: canonicalRows) {
                fixture.close()
                @Sendable func touch() { try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path) }

                let attempts = Counter()
                var settles = readOptions(tempRoot: tempRoot, forceCopy: true)
                settles.afterCopyAttempt = { attempt in
                    attempts.increment()
                    if attempt == 0 { touch() }
                }
                var settledRows = 0
                if case .rows(let rows, true)? = try? TypelessDatabaseReader.read(from: url, options: settles) { settledRows = rows.count }
                t.expect(settledRows == 11 && attempts.value == 2, "copy: a source that changed during the first attempt is copied again and then read")

                let tries = Counter()
                var neverSettles = readOptions(tempRoot: tempRoot, forceCopy: true)
                neverSettles.afterCopyAttempt = { _ in
                    tries.increment()
                    touch()
                }
                var message = ""
                do { _ = try TypelessDatabaseReader.read(from: url, options: neverSettles) } catch { message = error.localizedDescription }
                t.expect(message.contains("kept changing") && tries.value == 3, "copy: a source that never stops changing fails the read after three attempts instead of returning a torn copy")
                t.expect(fileNames(in: tempRoot).isEmpty, "copy: no temporary files are left after either outcome")
            } else {
                t.expect(false, "fixture: database for the changing-source test could be created")
            }
        }

        // A missing database is not an error.
        do {
            let url = sandbox.appendingPathComponent("no-such-dir", isDirectory: true).appendingPathComponent("typeless.db")
            let outcome = try? TypelessDatabaseReader.read(from: url, options: readOptions(tempRoot: sandbox))
            var isMissing = false
            if case .missing? = outcome { isMissing = true }
            t.expect(isMissing, "reader: a missing typeless.db is reported as missing, not as an error")
            t.expect(!fm.fileExists(atPath: sandbox.appendingPathComponent("no-such-dir").path), "reader: a missing database creates nothing")
        }

        // Unusable databases throw, and still clean up.
        do {
            let dir = makeDirectory(sandbox, "db-garbage")
            let tempRoot = makeDirectory(sandbox, "db-garbage-tmp")
            let url = dir.appendingPathComponent("typeless.db")
            try? Data(String(repeating: "this is not a SQLite database. ", count: 200).utf8).write(to: url)
            var threw = false
            do { _ = try TypelessDatabaseReader.read(from: url, options: readOptions(tempRoot: tempRoot)) } catch { threw = true }
            t.expect(threw, "reader: a file that is not a database throws")
            t.expect(fileNames(in: tempRoot).isEmpty, "reader: the copy is deleted even when reading it fails")

            let otherURL = makeDirectory(sandbox, "db-other").appendingPathComponent("typeless.db")
            if let other = FixtureDB(url: otherURL, wal: false, rows: [], createHistoryV2: false) {
                other.close()
                var message = ""
                do { _ = try TypelessDatabaseReader.read(from: otherURL, options: readOptions(tempRoot: tempRoot)) } catch { message = error.localizedDescription }
                t.expect(message.contains("history_v2"), "reader: a database without history_v2 throws an error that names the table")
            } else {
                t.expect(false, "fixture: database without history_v2 could be created")
            }
        }
    }

    // MARK: - Merging

    private static func mergeTests(_ t: Checker) {
        // Order: newest first, a tie keeps the existing record ahead of the new one.
        do {
            let existing = [record(100, "existing-100"), record(50, "existing-50"), record(10, "existing-10")]
            let fresh = [candidate("n75", 75, "new-75"), candidate("n100", 100, "new-100"), candidate("n5", 5, "new-5")]
            let merged = TypelessMerger.merge(existing: existing, candidates: fresh, importedIDs: [])
            t.expect(merged.history.map(\.polishedText) == ["existing-100", "new-100", "new-75", "existing-50", "existing-10", "new-5"], "merge: result is newest first and a timestamp tie keeps the existing record first")
            t.expect(merged.addedCount == 3 && merged.importedIDs == ["n75", "n100", "n5"], "merge: all three new records are counted and remembered")
            t.expect(zip(merged.history, merged.history.dropFirst()).allSatisfy { $0.timestamp >= $1.timestamp }, "merge: history stays sorted newest first")
        }

        // Cap, case 1: new records newer than everything push the oldest existing ones out.
        do {
            let existing = (0..<1000).map { record(Double(10_999 - $0), "e\(10_999 - $0)") }
            let newer = (0..<5).map { candidate("new-\($0)", Double(20_000 + $0), "newer-\($0)") }
            let older = (0..<3).map { candidate("old-\($0)", Double($0 + 1), "older-\($0)") }
            let merged = TypelessMerger.merge(existing: existing, candidates: newer + older, importedIDs: [])
            t.expect(merged.history.count == 1000, "cap: history is trimmed to 1,000 records")
            t.expect(merged.history.first?.polishedText == "newer-4" && merged.history.last?.polishedText == "e10005", "cap: the newest records are kept, the oldest existing ones fall off")
            t.expect(merged.addedCount == 5 && merged.importedIDs == Set((0..<5).map { "new-\($0)" }), "cap: only the records that survive the cap count as imported")
        }

        // Cap, case 2: older new records are the ones trimmed, nothing existing is lost.
        do {
            let existing = (0..<990).map { record(Double(10_989 - $0), "e\(10_989 - $0)") }
            let newer = (0..<10).map { candidate("new-\($0)", Double(20_000 + $0), "newer-\($0)") }
            let older = (0..<10).map { candidate("old-\($0)", Double($0 + 1), "older-\($0)") }
            let merged = TypelessMerger.merge(existing: existing, candidates: newer + older, importedIDs: [])
            t.expect(merged.history.count == 1000 && merged.addedCount == 10, "cap: 990 + 20 new -> 1,000 kept, the 10 oldest new records dropped")
            t.expect(Set(existing.map(\.id)).isSubset(of: Set(merged.history.map(\.id))), "cap: every existing record is still there")
            t.expect(merged.importedIDs.count == 10 && merged.importedIDs.allSatisfy { $0.hasPrefix("new-") }, "cap: dropped records are not marked as imported")
        }

        // Cap, case 3: nothing fits -> nothing changes; room appearing later lets the newest of them in.
        do {
            let existing = (0..<1000).map { record(Double(10_999 - $0), "e\(10_999 - $0)") }
            let older = (0..<3).map { candidate("old-\($0)", Double($0 + 1), "older-\($0)") }
            let none = TypelessMerger.merge(existing: existing, candidates: older, importedIDs: [])
            t.expect(none.addedCount == 0 && none.history.map(\.id) == existing.map(\.id) && none.importedIDs.isEmpty, "cap: when every new record is older than a full history, nothing is added or remembered")
            let roomy = TypelessMerger.merge(existing: Array(existing.dropLast(2)), candidates: older, importedIDs: [])
            t.expect(roomy.addedCount == 2 && roomy.history.count == 1000 && roomy.history.last?.polishedText == "older-1", "cap: if the user later frees room, the newest of the left-out records come in")
        }

        // Idempotency, deleted records, lost store, duplicate ids inside one batch.
        do {
            let existing = [record(500, "mine")]
            let fresh = [candidate("n1", 300, "one"), candidate("n2", 200, "two"), candidate("n3", 100, "three")]
            let first = TypelessMerger.merge(existing: existing, candidates: fresh, importedIDs: [])
            t.expect(first.addedCount == 3 && first.history.count == 4, "idempotency: first merge adds three records")

            let second = TypelessMerger.merge(existing: first.history, candidates: fresh, importedIDs: first.importedIDs)
            t.expect(second.addedCount == 0 && second.history.map(\.id) == first.history.map(\.id) && second.importedIDs == first.importedIDs, "idempotency: merging the same rows again changes nothing")

            let twoID = TypelessMapper.recordID(forTypelessID: "n2")
            let afterDelete = first.history.filter { $0.id != twoID }
            let third = TypelessMerger.merge(existing: afterDelete, candidates: fresh, importedIDs: first.importedIDs)
            t.expect(third.addedCount == 0 && !third.history.contains { $0.id == twoID } && third.history.count == 3, "deleted record: a record deleted in Nevertype is not added back")
            t.expect(third.importedIDs.contains("n2"), "deleted record: its Typeless id stays remembered")

            let healed = TypelessMerger.merge(existing: first.history, candidates: fresh, importedIDs: [])
            t.expect(healed.addedCount == 0 && healed.history.count == 4 && Set(healed.history.map(\.id)).count == 4, "lost ids file: records already in history are not duplicated")
            t.expect(healed.importedIDs == ["n1", "n2", "n3"], "lost ids file: their Typeless ids are recorded again")

            let upper = "AAAAAAAA-0000-0000-0000-000000000001"
            let dups = TypelessMerger.merge(existing: [], candidates: [candidate(upper, 20, "upper"), candidate(upper.lowercased(), 10, "lower")], importedIDs: [])
            t.expect(dups.addedCount == 1 && dups.history.count == 1, "duplicates: two Typeless ids that map to one record id add a single record")
        }
    }

    // MARK: - Imported-ids store

    private static func storeTests(_ t: Checker, sandbox: URL) {
        let fm = FileManager.default
        let dir = makeDirectory(sandbox, "store")
        let url = dir.appendingPathComponent("nested", isDirectory: true).appendingPathComponent("ids.json")
        let store = TypelessImportedIDStore(url: url)

        t.expect(store.load().isEmpty, "store: a missing file means nothing imported yet")
        do {
            try store.save(["b", "a", "c"])
            t.expect(store.load() == ["a", "b", "c"], "store: ids survive a save and a load (the folder is created when missing)")
            let json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any]
            t.expect((json?["ids"] as? [String]) == ["a", "b", "c"] && (json?["version"] as? Int) == 1, "store: file is small JSON with a version and a sorted id list")
            t.expect(fileNames(in: url.deletingLastPathComponent()) == ["ids.json"], "store: saving leaves no temporary files behind")
        } catch {
            t.expect(false, "store: save succeeds (\(error.localizedDescription))")
        }
        try? Data("not json".utf8).write(to: url)
        t.expect(store.load().isEmpty, "store: a corrupt file is treated as empty")
        try? fm.removeItem(at: url)
    }

    // MARK: - Banner text

    private static func bannerTests(_ t: Checker) {
        t.expect(TypelessSyncResult.imported(195).bannerText(manual: true) == "✅ Synced 195 dictations from Typeless", "banner: manual import message")
        t.expect(TypelessSyncResult.imported(195).bannerText(manual: false) == "✅ Synced 195 dictations from Typeless", "banner: an automatic sync that imported something says so")
        t.expect(TypelessSyncResult.imported(1).bannerText(manual: true) == "✅ Synced 1 dictation from Typeless", "banner: singular for one dictation")
        t.expect(TypelessSyncResult.imported(1000).bannerText(manual: true) == "✅ Synced 1,000 dictations from Typeless", "banner: large counts are grouped")
        t.expect(TypelessSyncResult.upToDate.bannerText(manual: true) == "✅ Typeless history is already up to date", "banner: manual up-to-date message")
        t.expect(TypelessSyncResult.upToDate.bannerText(manual: false) == nil, "banner: an automatic sync with nothing new stays quiet")
        t.expect(TypelessSyncResult.databaseMissing.bannerText(manual: true) != nil && TypelessSyncResult.databaseMissing.bannerText(manual: false) == nil, "banner: a missing database is explained after a manual sync only")
        t.expect(TypelessSyncResult.failed("boom").bannerText(manual: true) == "⚠️ Couldn't read Typeless history: boom" && TypelessSyncResult.failed("boom").bannerText(manual: false) == nil, "banner: a failure is shown after a manual sync only")
        t.expect(TypelessSyncResult.disabled.bannerText(manual: false) == nil && TypelessSyncResult.disabled.bannerText(manual: true)?.contains("Settings") == true, "banner: a disabled import is silent when automatic and points at Settings when manual")
        let parsed = TZStatusMessage.parse(TypelessSyncResult.imported(195).bannerText(manual: true) ?? "")
        t.expect(parsed.tone == .success && parsed.text == "Synced 195 dictations from Typeless", "banner: the toast renders it with the success icon")
    }

    // MARK: - One sync pass (merge into a host, persist)

    private static func syncPassTests(_ t: Checker, sandbox: URL) {
        let dir = makeDirectory(sandbox, "pass")
        let idsURL = dir.appendingPathComponent("ids.json")
        let tempRoot = makeDirectory(sandbox, "pass-tmp")
        let dbURL = dir.appendingPathComponent("typeless.db")
        guard let fixture = FixtureDB(url: dbURL, wal: false, rows: canonicalRows) else {
            t.expect(false, "fixture: database for the sync pass could be created")
            return
        }

        var config = TypelessSyncCoordinator.Configuration()
        config.databaseURL = dbURL
        config.store = TypelessImportedIDStore(url: idsURL)
        config.readOptions = readOptions(tempRoot: tempRoot)

        let mine = [
            record(1795557000, "TZ newest"),            // 2026-11-24T21:30:00Z, newer than every Typeless row
            record(1795527600, "TZ middle"),            // 2026-11-23T12:00:00Z, between two Typeless rows
            record(1795200000, "TZ oldest")             // 2026-11-19, older than all of them
        ]
        let rows: [TypelessRow] = {
            guard case .rows(let rows, _)? = try? TypelessDatabaseReader.read(from: dbURL, options: config.readOptions) else { return [] }
            return rows
        }()
        t.expect(rows.count == 11, "sync pass: fixture rows read back")

        MainActor.assumeIsolated {
            let host = FakeHost(history: mine)
            let coordinator = TypelessSyncCoordinator(configuration: config)
            var idsFileExistedWhenHistoryWasWritten: Bool?
            host.onPersist = { idsFileExistedWhenHistoryWasWritten = FileManager.default.fileExists(atPath: idsURL.path) }

            let first = coordinator.apply(rows: rows, to: host)
            t.expect(first == .imported(4), "sync pass: first sync imports the 4 eligible rows")
            t.expect(host.history.map(\.polishedText) == ["TZ newest", "Hello from Typeless.", "Second dictation", "TZ middle", "  padded with spaces  \n", "no fractional seconds", "TZ oldest"], "sync pass: imported records are merged into the history newest first")
            t.expect(host.persistCount == 1, "sync pass: history.json is written once")
            t.expect(idsFileExistedWhenHistoryWasWritten == false, "sync pass: history is written before the imported-ids file")
            t.expect(config.store.load() == ["9F1B7C52-3D2A-4E7B-8C11-0A5D6E7F8091", "row-two", "row-three", "noms-1"], "sync pass: the four Typeless ids are remembered")
            t.expect(Set(host.history.map(\.id)).count == host.history.count, "sync pass: record ids are unique")
            // history.json is a plain JSONEncoder dump of the array (see tzPersistHistory / AppState.loadHistory).
            let reloaded = (try? JSONEncoder().encode(host.history)).flatMap { try? JSONDecoder().decode([DictationRecord].self, from: $0) }
            let imported = host.history.filter { $0.targetAppName == "Typeless" }
            let reloadedImported = reloaded?.filter { $0.targetAppName == "Typeless" } ?? []
            t.expect(reloaded?.map(\.id) == host.history.map(\.id) && reloadedImported.map(\.timestamp) == imported.map(\.timestamp) && reloadedImported.map(\.polishedText) == imported.map(\.polishedText) && reloadedImported.allSatisfy { $0.mode == .dictate }, "sync pass: imported records survive the history.json encode/decode round trip unchanged")

            let second = coordinator.apply(rows: rows, to: host)
            t.expect(second == .upToDate && host.persistCount == 1 && host.history.count == 7, "sync pass: syncing again imports nothing and writes nothing")

            let secondRow = TypelessMapper.recordID(forTypelessID: "row-two")
            host.history.removeAll { $0.id == secondRow }
            let third = coordinator.apply(rows: rows, to: host)
            t.expect(third == .upToDate && host.history.count == 6 && !host.history.contains { $0.id == secondRow } && host.persistCount == 1, "sync pass: a record deleted in Nevertype stays deleted")

            host.history = []
            t.expect(coordinator.apply(rows: rows, to: host) == .upToDate && host.history.isEmpty, "sync pass: clearing the whole history does not bring the Typeless records back")

            var more = rows
            more.append(TypelessRow(id: "later-1", status: "completed", mode: "voice_transcript", refinedText: "A newer Typeless dictation", duration: 2, createdAt: "2026-11-25T09:00:00.000Z"))
            let fourth = coordinator.apply(rows: more, to: host)
            t.expect(fourth == .imported(1) && host.history.map(\.polishedText) == ["A newer Typeless dictation"] && host.persistCount == 2, "sync pass: a Typeless dictation made later is picked up on the next sync")

            // The ids file is lost while the records are still in history: no duplicates, ids recorded again.
            let lostStore = TypelessImportedIDStore(url: dir.appendingPathComponent("lost-ids.json"))
            var lostConfig = config
            lostConfig.store = lostStore
            let healHost = FakeHost(history: mine)
            let healer = TypelessSyncCoordinator(configuration: lostConfig)
            _ = healer.apply(rows: rows, to: healHost)
            let countBefore = healHost.history.count
            try? FileManager.default.removeItem(at: lostStore.url)
            let healed = healer.apply(rows: rows, to: healHost)
            t.expect(healed == .upToDate && healHost.history.count == countBefore && Set(healHost.history.map(\.id)).count == countBefore, "sync pass: with the ids file lost, records already in history are not imported twice")
            t.expect(lostStore.load().count == 4, "sync pass: ...and the ids file is rebuilt")

            // The cap applies to the merged result.
            var capConfig = config
            capConfig.store = TypelessImportedIDStore(url: dir.appendingPathComponent("cap-ids.json"))
            capConfig.historyCap = 5
            let capHost = FakeHost(history: mine)
            let capped = TypelessSyncCoordinator(configuration: capConfig).apply(rows: rows, to: capHost)
            // 3 Nevertype + 4 Typeless = 7 records, cap 5: the two oldest ("no fractional seconds", "TZ oldest") are dropped.
            t.expect(capHost.history.map(\.polishedText) == ["TZ newest", "Hello from Typeless.", "Second dictation", "TZ middle", "  padded with spaces  \n"], "sync pass: the history cap is enforced after merging (keeps the newest)")
            t.expect(capped == .imported(3) && capConfig.store.load().count == 3 && !capConfig.store.load().contains("noms-1"), "sync pass: a Typeless record dropped by the cap is not counted or remembered as imported")
        }
        fixture.close()
    }

    // MARK: - The async coordinator (real reader thread, banner, ordering)

    private static func asyncSyncTests(_ t: Checker, sandbox: URL) {
        let dir = makeDirectory(sandbox, "async")
        let tempRoot = makeDirectory(sandbox, "async-tmp")
        let dbURL = dir.appendingPathComponent("typeless.db")
        guard let fixture = FixtureDB(url: dbURL, wal: false, rows: canonicalRows) else {
            t.expect(false, "fixture: database for the async sync could be created")
            return
        }

        @Sendable func makeConfig(_ idsName: String) -> TypelessSyncCoordinator.Configuration {
            var config = TypelessSyncCoordinator.Configuration()
            config.databaseURL = dbURL
            config.store = TypelessImportedIDStore(url: dir.appendingPathComponent(idsName))
            config.readOptions = readOptions(tempRoot: tempRoot)
            return config
        }

        // Manual and automatic syncs end to end: read off the main thread, merge on the main actor, post the banner.
        struct FlowLog {
            var auto1: TypelessSyncResult?
            var auto1Banner = "unset"
            var auto1Count = 0
            var auto2: TypelessSyncResult?
            var auto2Banner = "unset"
            var manual: TypelessSyncResult?
            var manualBanner = "unset"
            var manualSyncing = true
        }
        let flow = makeConfig("flow-ids.json")
        let log: FlowLog = runOnMain(FlowLog()) {
            let host = FakeHost(history: [])
            let coordinator = TypelessSyncCoordinator(configuration: flow)
            var log = FlowLog()

            host.statusBanner = "⚠️ Accessibility is off"
            log.auto1 = await coordinator.sync(into: host, manual: false)
            log.auto1Banner = host.statusBanner
            log.auto1Count = host.history.count

            host.statusBanner = ""
            log.auto2 = await coordinator.sync(into: host, manual: false)
            log.auto2Banner = host.statusBanner

            log.manual = await coordinator.sync(into: host, manual: true)
            log.manualBanner = host.statusBanner
            log.manualSyncing = coordinator.isSyncing
            return log
        }
        t.expect(log.auto1 == .imported(4) && log.auto1Count == 4 && log.auto1Banner == "⚠️ Accessibility is off", "async: an automatic sync imports, but does not replace a warning already on screen")
        t.expect(log.auto2 == .upToDate && log.auto2Banner.isEmpty, "async: an automatic sync with nothing new stays quiet")
        t.expect(log.manual == .upToDate && log.manualBanner == "✅ Typeless history is already up to date" && !log.manualSyncing, "async: a manual sync with nothing new says so, and the coordinator is idle afterwards")

        // A manual sync that imports posts its banner, replacing whatever was showing; an automatic one posts into an empty banner.
        let bannerResult: [String] = runOnMain([]) {
            var log: [String] = []
            let manualHost = FakeHost(history: [])
            manualHost.statusBanner = "something else"
            _ = await TypelessSyncCoordinator(configuration: makeConfig("banner-a.json")).sync(into: manualHost, manual: true)
            log.append(manualHost.statusBanner)
            let autoHost = FakeHost(history: [])
            _ = await TypelessSyncCoordinator(configuration: makeConfig("banner-b.json")).sync(into: autoHost, manual: false)
            log.append(autoHost.statusBanner)
            return log
        }
        t.expect(bannerResult == ["✅ Synced 4 dictations from Typeless", "✅ Synced 4 dictations from Typeless"], "async: the import banner is posted by manual syncs and by automatic syncs that find an empty banner")

        // The launch sync runs once.
        let launchResult: [Int] = runOnMain([]) {
            let host = FakeHost(history: [])
            let coordinator = TypelessSyncCoordinator(configuration: makeConfig("launch-ids.json"))
            await coordinator.syncOnLaunch(into: host)
            let afterFirst = host.history.count
            host.history = []
            await coordinator.syncOnLaunch(into: host)    // ignored: the launch sync already ran
            return [afterFirst, host.history.count]
        }
        t.expect(launchResult == [4, 0], "async: the launch sync happens once per launch")

        // Missing database and unreadable database.
        let edgeResult: [String] = runOnMain([]) {
            var log: [String] = []
            var missing = makeConfig("missing-ids.json")
            missing.databaseURL = dir.appendingPathComponent("nope", isDirectory: true).appendingPathComponent("typeless.db")
            let host = FakeHost(history: [])
            _ = await TypelessSyncCoordinator(configuration: missing).sync(into: host, manual: false)
            log.append("quiet=\(host.statusBanner.isEmpty) persists=\(host.persistCount)")
            _ = await TypelessSyncCoordinator(configuration: missing).sync(into: host, manual: true)
            log.append(host.statusBanner)

            let garbageURL = dir.appendingPathComponent("garbage.db")
            try? Data(String(repeating: "not a database ", count: 300).utf8).write(to: garbageURL)
            var broken = makeConfig("broken-ids.json")
            broken.databaseURL = garbageURL
            let brokenHost = FakeHost(history: [])
            _ = await TypelessSyncCoordinator(configuration: broken).sync(into: brokenHost, manual: false)
            log.append("quiet=\(brokenHost.statusBanner.isEmpty)")
            _ = await TypelessSyncCoordinator(configuration: broken).sync(into: brokenHost, manual: true)
            log.append(brokenHost.statusBanner.hasPrefix("⚠️ Couldn't read Typeless history: ") ? "warned" : brokenHost.statusBanner)
            return log
        }
        t.expect(edgeResult == ["quiet=true persists=0", "Typeless history wasn't found on this Mac.", "quiet=true", "warned"], "async: a missing or unreadable database does nothing quietly, and explains itself after a manual sync")

        // Only one sync runs at a time: an automatic request is skipped, a manual one waits and shares the outcome.
        let started = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        let reads = Counter()
        var gated = makeConfig("gated-ids.json")
        gated.read = { url, options in
            reads.increment()
            started.signal()
            gate.wait()
            return try TypelessDatabaseReader.read(from: url, options: options)
        }
        let hostBox = Box<FakeHost?>(nil)
        let coordinatorBox = Box<TypelessSyncCoordinator?>(nil)
        let firstBox = Box<TypelessSyncResult??>(nil)
        let autoBox = Box<TypelessSyncResult??>(nil)
        let joinBox = Box<TypelessSyncResult??>(nil)
        MainActor.assumeIsolated {
            hostBox.value = FakeHost(history: [])
            coordinatorBox.value = TypelessSyncCoordinator(configuration: gated)
        }
        Task { @MainActor in
            firstBox.value = .some(await coordinatorBox.value?.sync(into: hostBox.value!, manual: true))
            firstBox.done = true
        }
        var readerStarted = false
        pump { readerStarted = started.wait(timeout: .now()) == .success; return readerStarted }
        t.expect(readerStarted, "ordering: the first sync reached the database reader")
        Task { @MainActor in
            autoBox.value = .some(await coordinatorBox.value?.sync(into: hostBox.value!, manual: false))
            autoBox.done = true
        }
        Task { @MainActor in
            joinBox.value = .some(await coordinatorBox.value?.sync(into: hostBox.value!, manual: true))
            joinBox.done = true
        }
        pump { autoBox.done }
        var skippedWhileRunning = false
        if case .some(.none) = autoBox.value { skippedWhileRunning = true }
        t.expect(skippedWhileRunning, "ordering: an automatic sync requested while one is running is skipped")
        t.expect(!firstBox.done && !joinBox.done, "ordering: the running sync and the waiting manual sync are still in flight")
        gate.signal()
        pump { firstBox.done && joinBox.done }
        t.expect(firstBox.value == .some(.some(.imported(4))) && joinBox.value == .some(.some(.imported(4))), "ordering: the waiting manual sync reports the same outcome as the sync it waited for")
        t.expect(reads.value == 1, "ordering: the database was read once, not once per request")
        MainActor.assumeIsolated {
            t.expect(hostBox.value?.history.count == 4 && hostBox.value?.persistCount == 1 && coordinatorBox.value?.isSyncing == false, "ordering: history was merged and written once, and the coordinator is idle again")
        }
        fixture.close()
    }

    // MARK: - Opt-in

    /// The import is opt-in: off by default, silent while off (the database is never opened), and one import right away when
    /// the user turns it on.
    private static func optInTests(_ t: Checker, sandbox: URL) {
        // The setting: off by default, for old configs, and for unreadable values; on only when saved as on.
        let oldConfig = try? JSONDecoder().decode(LLMConfig.self, from: Data(#"{"baseURL":"http://127.0.0.1:11434/v1","modelName":"gemma4:12b-mlx"}"#.utf8))
        let wrongType = try? JSONDecoder().decode(LLMConfig.self, from: Data(#"{"enableTypelessImport":"yes"}"#.utf8))
        var switchedOn = LLMConfig.default
        switchedOn.enableTypelessImport = true
        let savedOn = (try? JSONEncoder().encode(switchedOn)).flatMap { try? JSONDecoder().decode(LLMConfig.self, from: $0) }
        let savedOff = (try? JSONEncoder().encode(LLMConfig.default)).flatMap { try? JSONDecoder().decode(LLMConfig.self, from: $0) }
        t.expect(
            LLMConfig.default.enableTypelessImport == false && LLMConfig().enableTypelessImport == false
                && oldConfig?.enableTypelessImport == false && wrongType?.enableTypelessImport == false
                && savedOff?.enableTypelessImport == false && savedOn?.enableTypelessImport == true,
            "opt-in: the Typeless import is off by default and for configs saved without it, and an explicit on survives a save and load"
        )

        let dir = makeDirectory(sandbox, "optin")
        let tempRoot = makeDirectory(sandbox, "optin-tmp")
        let dbURL = dir.appendingPathComponent("typeless.db")
        guard let fixture = FixtureDB(url: dbURL, wal: false, rows: canonicalRows) else {
            t.expect(false, "fixture: database for the opt-in tests could be created")
            return
        }
        defer { fixture.close() }

        // Every read of the database is counted, so "never opened" can be checked directly.
        let reads = Counter()
        @Sendable func makeConfig(_ idsName: String) -> TypelessSyncCoordinator.Configuration {
            var config = TypelessSyncCoordinator.Configuration()
            config.databaseURL = dbURL
            config.store = TypelessImportedIDStore(url: dir.appendingPathComponent(idsName))
            config.readOptions = readOptions(tempRoot: tempRoot)
            config.read = { url, options in
                reads.increment()
                return try TypelessDatabaseReader.read(from: url, options: options)
            }
            return config
        }

        // Off: no automatic import (launch sync, History-open sync) and no manual one; nothing is read, merged or written.
        struct OffLog {
            var results: [TypelessSyncResult?] = []
            var historyCount = -1
            var persistCount = -1
            var autoBanner = "unset"
            var manualBanner = "unset"
            var syncing = true
        }
        let idsOff = dir.appendingPathComponent("off-ids.json")
        let off: OffLog = runOnMain(OffLog()) {
            let host = FakeHost(history: [], importEnabled: false)
            let coordinator = TypelessSyncCoordinator(configuration: makeConfig("off-ids.json"))
            var log = OffLog()
            await coordinator.syncOnLaunch(into: host)                               // the launch-time sync
            log.results.append(await coordinator.sync(into: host, manual: false))   // the History-open sync
            log.autoBanner = host.statusBanner
            log.results.append(await coordinator.sync(into: host, manual: true))    // "Sync from Typeless"
            log.manualBanner = host.statusBanner
            log.historyCount = host.history.count
            log.persistCount = host.persistCount
            log.syncing = coordinator.isSyncing
            return log
        }
        t.expect(
            off.results == [.disabled, .disabled] && off.historyCount == 0 && off.persistCount == 0 && !off.syncing
                && off.autoBanner.isEmpty && off.manualBanner.contains("Settings"),
            "opt-in: with the switch off, the launch sync, the History-open sync and a manual sync all do nothing (quietly, except a pointer to Settings after a manual one)"
        )
        t.expect(reads.value == 0 && !FileManager.default.fileExists(atPath: idsOff.path), "opt-in: with the switch off the database is never read and the imported-ids file is never created")

        // Turning it on imports right away; the switch is set at once and the outcome is the manual sync's.
        struct OnLog {
            var enabledImmediately = false
            var result: TypelessSyncResult??
            var historyCount = -1
            var persistCount = -1
            var banner = ""
            var readsAfterOn = -1
            var afterOffResult: TypelessSyncResult??
            var readsAfterOff = -1
            var offFlag = true
            var offTaskIsNil = false
            var relaunchResult: TypelessSyncResult??
        }
        let onLog: OnLog = runOnMain(OnLog()) {
            let host = FakeHost(history: [], importEnabled: false)
            let coordinator = TypelessSyncCoordinator(configuration: makeConfig("on-ids.json"))
            var log = OnLog()
            let task = coordinator.setImportEnabled(true, on: host)
            log.enabledImmediately = host.typelessImportEnabled
            log.result = .some(await task?.value)
            log.historyCount = host.history.count
            log.persistCount = host.persistCount
            log.banner = host.statusBanner
            log.readsAfterOn = reads.value

            // Turning it off again stops everything: no task, and later syncs do not read.
            let offTask = coordinator.setImportEnabled(false, on: host)
            log.offTaskIsNil = (offTask == nil)
            log.offFlag = host.typelessImportEnabled
            log.afterOffResult = .some(await coordinator.sync(into: host, manual: false))
            log.readsAfterOff = reads.value
            // Turned on again, the launch sync (once per launch) and later syncs work like any other.
            host.typelessImportEnabled = true
            await coordinator.syncOnLaunch(into: host)
            log.relaunchResult = .some(await coordinator.sync(into: host, manual: false))
            return log
        }
        t.expect(
            onLog.enabledImmediately && onLog.result == .some(.some(.imported(4))) && onLog.historyCount == 4 && onLog.persistCount == 1
                && onLog.banner == "✅ Synced 4 dictations from Typeless" && onLog.readsAfterOn == 1,
            "opt-in: turning the switch on imports once right away (4 dictations from the fixture, history written once, banner shown)"
        )
        t.expect(
            onLog.offTaskIsNil && !onLog.offFlag && onLog.afterOffResult == .some(.some(.disabled)) && onLog.readsAfterOff == 1,
            "opt-in: turning the switch off again stops all syncs; the database is not read again"
        )
        t.expect(
            onLog.relaunchResult == .some(.some(.upToDate)) && reads.value >= 2,
            "opt-in: with the switch on again, the automatic syncs run (here there is nothing new)"
        )

        // The switch turned off while the database is being read: the rows already read are not merged.
        let started = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        var gated = makeConfig("midway-ids.json")
        gated.read = { url, options in
            started.signal()
            gate.wait()
            return try TypelessDatabaseReader.read(from: url, options: options)
        }
        let hostBox = Box<FakeHost?>(nil)
        let resultBox = Box<TypelessSyncResult??>(nil)
        MainActor.assumeIsolated { hostBox.value = FakeHost(history: [], importEnabled: true) }
        let coordinatorBox = Box<TypelessSyncCoordinator?>(nil)
        MainActor.assumeIsolated { coordinatorBox.value = TypelessSyncCoordinator(configuration: gated) }
        Task { @MainActor in
            resultBox.value = .some(await coordinatorBox.value?.sync(into: hostBox.value!, manual: false))
            resultBox.done = true
        }
        var readerStarted = false
        pump { readerStarted = started.wait(timeout: .now()) == .success; return readerStarted }
        MainActor.assumeIsolated { hostBox.value?.typelessImportEnabled = false }
        gate.signal()
        pump { resultBox.done }
        MainActor.assumeIsolated {
            t.expect(
                readerStarted && resultBox.value == .some(.some(.disabled)) && hostBox.value?.history.isEmpty == true && hostBox.value?.persistCount == 0,
                "opt-in: if the switch is turned off while a sync is reading, nothing is merged or written"
            )
        }
    }

    // MARK: - Dry run

    private static func dryRunTests(_ t: Checker, sandbox: URL) {
        let dir = makeDirectory(sandbox, "dry")
        let tempRoot = makeDirectory(sandbox, "dry-tmp")
        let dbURL = dir.appendingPathComponent("typeless.db")
        guard let fixture = FixtureDB(url: dbURL, wal: false, rows: canonicalRows) else {
            t.expect(false, "fixture: database for the dry run could be created")
            return
        }
        fixture.close()
        let store = TypelessImportedIDStore(url: dir.appendingPathComponent("ids.json"))
        let options = readOptions(tempRoot: tempRoot)
        let dirBefore = fingerprint(ofDirectory: dir)

        let fresh = TypelessHistoryImporter.dryRunReport(databaseURL: dbURL, store: store, options: options)
        let freshText = fresh.lines.joined(separator: "\n")
        t.expect(fresh.status == 0 && freshText.contains("Total rows:         11") && freshText.contains("Eligible rows:      4 ") && freshText.contains("Already imported:   0") && freshText.contains("Would import now:   4"), "dry run: reports total, eligible and already-imported counts")
        t.expect(freshText.contains("1 not completed, 1 not voice_transcript, 3 empty text, 1 without id, 1 with unreadable date"), "dry run: breaks the skipped rows down by reason")
        t.expect(!freshText.contains("Hello from Typeless") && !freshText.contains("row-two"), "dry run: prints counts only, no record text or ids")

        try? store.save(["row-two", "noms-1", "some-id-not-in-the-database"])
        let partial = TypelessHistoryImporter.dryRunReport(databaseURL: dbURL, store: store, options: options)
        let partialText = partial.lines.joined(separator: "\n")
        t.expect(partialText.contains("Already imported:   2") && partialText.contains("Would import now:   2"), "dry run: counts eligible rows that are already in the imported-ids file")

        let missing = TypelessHistoryImporter.dryRunReport(databaseURL: dir.appendingPathComponent("gone.db"), store: store, options: options)
        t.expect(missing.status == 0 && missing.lines.joined().contains("not found"), "dry run: a missing database is reported, not an error")
        t.expect(fingerprint(ofDirectory: dir).filter { $0.key != "ids.json" } == dirBefore, "dry run: the database folder is untouched")
    }
}
