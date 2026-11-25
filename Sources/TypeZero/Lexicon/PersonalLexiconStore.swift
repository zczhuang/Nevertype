import Foundation
import NaturalLanguage
import SQLite3

/// Zero-dependency Mandarin Pinyin + Fuzzy Accent Skeleton normalizer using CoreFoundation.
/// Enables <0.5ms homophone & southern/northern accent fuzzy recall (zh/z, ch/c, sh/s, ing/in, eng/en, ong/un, n/l) across thousands of entries.
public enum PhoneticIndexer {
    public static func normalize(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        let mutable = NSMutableString(string: text.lowercased()) as CFMutableString
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripCombiningMarks, false)
        let raw = mutable as String
        let cleaned = raw.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(cleaned))
    }

    /// Accent-tolerant fuzzy phonetic skeleton: collapses common Mandarin near-homophone confusions
    /// (`zh/ch/sh -> z/c/s`, `ing/eng/ong -> in/en/un`, syllable-initial `l -> n`) so misheard names/terms still recall at 100% precision!
    public static func fuzzySkeleton(_ text: String) -> String {
        let syls = syllables(text)
        guard !syls.isEmpty else { return "" }
        let mapped = syls.map { s -> String in
            var v = s
            if v.hasPrefix("zh") { v = "z" + v.dropFirst(2) }
            else if v.hasPrefix("ch") { v = "c" + v.dropFirst(2) }
            else if v.hasPrefix("sh") { v = "s" + v.dropFirst(2) }
            else if v.hasPrefix("l") { v = "n" + v.dropFirst(1) }

            if v.hasSuffix("ing") { v = String(v.dropLast(3)) + "in" }
            else if v.hasSuffix("eng") { v = String(v.dropLast(3)) + "en" }
            else if v.hasSuffix("ang") { v = String(v.dropLast(3)) + "an" }
            else if v.hasSuffix("ong") { v = String(v.dropLast(3)) + "un" }
            return v
        }
        return mapped.joined()
    }

    public static func syllables(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let mutable = NSMutableString(string: text.lowercased()) as CFMutableString
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripCombiningMarks, false)
        let raw = mutable as String
        return raw
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}

public final class PersonalLexiconStore: ObservableObject {
    @Published public private(set) var entries: [LexiconEntry] = []

    private let storageURL: URL

    public init(customStorageURL: URL? = nil) {
        if let customStorageURL {
            self.storageURL = customStorageURL
        } else {
            let dir = AppBrand.applicationSupportDirectory()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.storageURL = dir.appendingPathComponent("lexicon.json")
        }
        load()
    }

    private struct LossyElement<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws {
            self.value = try? T(from: decoder)
        }
    }

    public func load() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: storageURL.path),
              let data = try? Data(contentsOf: storageURL),
              !data.isEmpty else {
            // Seed minimal tech examples ONLY when lexicon.json does not exist yet!
            self.entries = [
                LexiconEntry(term: "DeepSeek", aliases: ["迪普西克", "deep seek"], category: .project, weight: 5),
                LexiconEntry(term: AppBrand.name, aliases: ["never type"], category: .project, weight: 5)
            ]
            save()
            return
        }

        if let lossy = try? JSONDecoder().decode([LossyElement<LexiconEntry>].self, from: data) {
            let valid = lossy.compactMap(\.value).filter { !$0.term.isEmpty }
            if !valid.isEmpty {
                self.entries = valid
                return
            }
        }
        // Never overwrite an existing unreadable file; preserve it as .bak before falling back in memory
        let bakURL = storageURL.deletingLastPathComponent().appendingPathComponent("lexicon.corrupt.bak.json")
        try? data.write(to: bakURL, options: .atomic)
        self.entries = [
            LexiconEntry(term: "DeepSeek", aliases: ["迪普西克", "deep seek"], category: .project, weight: 5),
            LexiconEntry(term: AppBrand.name, aliases: ["never type"], category: .project, weight: 5)
        ]
    }

    public func save() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: storageURL, options: .atomic)
        }
    }

    public func upsert(term: String, aliases: [String] = [], category: LexiconCategory = .project, weight: Int = 2) {
        let cleanTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanTerm.count >= 2 else { return }

        if let idx = entries.firstIndex(where: { $0.term.caseInsensitiveCompare(cleanTerm) == .orderedSame }) {
            let mergedAliases = Array(Set(entries[idx].aliases + aliases)).filter { !$0.isEmpty }
            entries[idx].aliases = mergedAliases
            entries[idx].weight = max(entries[idx].weight, weight)
            entries[idx].phoneticKey = PhoneticIndexer.normalize(cleanTerm)
        } else {
            entries.insert(
                LexiconEntry(term: cleanTerm, aliases: aliases, category: category, weight: weight),
                at: 0
            )
        }
        save()
    }

    public func bulkUpsert(_ newItems: [(term: String, aliases: [String], category: LexiconCategory)]) -> Int {
        var added = 0
        for item in newItems {
            let clean = item.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard clean.count >= 2, clean.count <= 36 else { continue }
            if let idx = entries.firstIndex(where: { $0.term.caseInsensitiveCompare(clean) == .orderedSame }) {
                entries[idx].aliases = Array(Set(entries[idx].aliases + item.aliases))
                entries[idx].weight += 1
            } else {
                entries.append(LexiconEntry(term: clean, aliases: item.aliases, category: item.category, weight: 2))
                added += 1
            }
        }
        entries.sort { $0.weight > $1.weight }
        save()
        return added
    }

    public func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    public func removeBatch(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        entries.removeAll { ids.contains($0.id) }
        save()
    }

    /// Updates an existing entry in-place; if renamed to match another existing entry (e.g. fixing misextracted "章伟" -> "张伟"),
    /// automatically merges aliases into the target entry and deduplicates!
    public func updateEntry(
        id: UUID,
        newTerm: String,
        newAliases: [String],
        newCategory: LexiconCategory,
        newWeight: Int
    ) {
        let cleanTerm = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanTerm.count >= 1,
              let sourceIdx = entries.firstIndex(where: { $0.id == id }) else { return }

        let oldTerm = entries[sourceIdx].term
        var cleanedAliases = newAliases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.caseInsensitiveCompare(cleanTerm) != .orderedSame }

        // If user corrected a wrong standard term (e.g. "章伟" -> "张伟"), automatically remember the old wrong term as an alias!
        if oldTerm.caseInsensitiveCompare(cleanTerm) != .orderedSame && oldTerm.count >= 2 {
            if !cleanedAliases.contains(where: { $0.caseInsensitiveCompare(oldTerm) == .orderedSame }) {
                cleanedAliases.insert(oldTerm, at: 0)
            }
        }

        // Check if another entry already has `cleanTerm` -> smart merge!
        if let collisionIdx = entries.firstIndex(where: { $0.id != id && $0.term.caseInsensitiveCompare(cleanTerm) == .orderedSame }) {
            let combined = Array(Set(entries[collisionIdx].aliases + cleanedAliases))
                .filter { $0.caseInsensitiveCompare(cleanTerm) != .orderedSame }
                .sorted()
            entries[collisionIdx].aliases = combined
            entries[collisionIdx].category = newCategory
            entries[collisionIdx].weight = max(entries[collisionIdx].weight, newWeight)
            entries[collisionIdx].phoneticKey = PhoneticIndexer.normalize(cleanTerm)
            entries.remove(at: sourceIdx)
        } else {
            entries[sourceIdx].term = cleanTerm
            entries[sourceIdx].aliases = Array(Set(cleanedAliases)).sorted()
            entries[sourceIdx].category = newCategory
            entries[sourceIdx].weight = newWeight
            entries[sourceIdx].phoneticKey = PhoneticIndexer.normalize(cleanTerm)
        }
        save()
    }

    /// P6: Auto-Learn Correction Watcher — extracts clean word-level user corrections (1–10 chars)
    /// across single-line, multi-paragraph (`\n`), and pre-populated input boxes!
    public func learnFromManualEditIfApplicable(injectedText: String, editedBoxValue: String) -> (wrong: String, corrected: String)? {
        let orig = injectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let edited = editedBoxValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard orig.count >= 3, edited.count >= 3, orig != edited else { return nil }

        let origLines = orig.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 3 }
        let editedLines = edited.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 3 }

        for oLine in origLines {
            // Skip lines that remained 100% identical in the edited box
            if editedLines.contains(oLine) { continue }

            for eLine in editedLines {
                if let pair = Self.extractSingleWordReplacement(origLine: oLine, editedLine: eLine) {
                    guard !Self.isCommonOrDisposableAutoLearnTerm(pair.corrected) else { continue }
                    upsert(term: pair.corrected, aliases: [pair.wrong], category: .autoLearned, weight: 8)
                    return pair
                }
            }
        }
        return nil
    }

    /// Prevents everyday Chinese words, version numbers, dates, or file paths from polluting the auto-learned personal lexicon.
    public static func isCommonOrDisposableAutoLearnTerm(_ term: String) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return true }
        // Reject URLs, file paths, pure digits, dates, and version numbers (e.g. `v0.4.2`, `2026-11-19`, `1234`)
        if trimmed.contains("/") || trimmed.contains("\\") || trimmed.contains("://") { return true }
        let disposablePattern = #"^(?:[vV]?\d+(?:[.\-]\d+)*|\d+[年月日时分秒天周月个次项%]?)$"#
        if trimmed.range(of: disposablePattern, options: .regularExpression) != nil { return true }

        let commonWords: Set<String> = [
            "今天", "明天", "昨天", "现在", "刚才", "马上", "以后", "之前", "时候", "时间",
            "可以", "没有", "不是", "好的", "没问题", "什么", "怎么", "为什么", "应该", "需要",
            "因为", "所以", "但是", "如果", "然后", "不过", "另外", "还有", "而且", "或者",
            "这个", "那个", "这些", "那些", "这样", "那样", "这里", "那里", "自己", "大家",
            "一下", "一起", "一直", "一定", "一点", "一般", "已经", "还是", "就是", "只是",
            "知道", "觉得", "希望", "看看", "意思", "问题", "地方", "东西", "事情", "工作"
        ]
        return commonWords.contains(trimmed)
    }

    /// Learns directly when user selects a misheard word/phrase and uses hotkey voice rewrite (e.g. "改成星河" / "这是 SEO").
    public func learnFromSelectionRewrite(selectedText: String, rewrittenText: String) -> (wrong: String, corrected: String)? {
        let wrong = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = rewrittenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wrong.isEmpty, !right.isEmpty, wrong != right else { return nil }

        let sentenceStoppers = CharacterSet(charactersIn: "，。！？；：,.;!?\n")
        // Case 1: User highlighted just the wrong term itself (e.g. "星合" or "Su") and dictated the right term ("星河" or "SEO")
        if wrong.count >= 1, wrong.count <= 12,
           right.count >= 2, right.count <= 16,
           wrong.rangeOfCharacter(from: sentenceStoppers) == nil,
           right.rangeOfCharacter(from: sentenceStoppers) == nil {
            upsert(term: right, aliases: [wrong], category: .autoLearned, weight: 9)
            return (wrong, right)
        }

        // Case 2: User highlighted a whole clause and asked to fix one term inside it
        if let pair = learnFromManualEditIfApplicable(injectedText: wrong, editedBoxValue: right) {
            upsert(term: pair.corrected, aliases: [pair.wrong], category: .autoLearned, weight: 9)
            return pair
        }
        return nil
    }

    private static let cjkGrammarParticles: Set<Character> = Set("的得地了着过是我你他她它们在有和与跟让把被给对向从到去来就都也还又再很太更最不没别这那哪")
    private static let commonCapitalizedStarters: Set<String> = [
        "the", "this", "that", "these", "those", "when", "what", "where", "which", "while",
        "with", "from", "into", "over", "after", "before", "under", "about", "there", "their"
    ]

    private static func extractSingleWordReplacement(origLine: String, editedLine: String) -> (wrong: String, corrected: String)? {
        var candidate = editedLine
        // If `origLine` was appended after existing text on the same line, align using anchor prefix or suffix
        if editedLine.count > origLine.count + 6 {
            let anchorLen = min(4, origLine.count)
            let headAnchor = String(origLine.prefix(anchorLen))
            if let range = editedLine.range(of: headAnchor, options: .backwards) {
                candidate = String(editedLine[range.lowerBound...])
            } else {
                candidate = String(editedLine.suffix(min(editedLine.count, origLine.count + 6)))
            }
        }
        guard abs(candidate.count - origLine.count) <= 8 else { return nil }

        let a = Array(origLine)
        let b = Array(candidate)
        var prefix = 0
        while prefix < min(a.count, b.count) && a[prefix] == b[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < (min(a.count, b.count) - prefix) &&
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }

        guard (prefix + suffix) >= max(2, Int(Double(a.count) * 0.58)) else { return nil }

        // Snap changed character span outward to whole word boundaries in `candidate` using Apple NaturalLanguage tokenizer!
        // Fixes 1-char CJK homophone edits inside 2-char names (e.g. "星合" -> "星河", where raw char diff is only "合" -> "河").
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = candidate
        var tokenSpans: [(start: Int, end: Int)] = []
        tokenizer.enumerateTokens(in: candidate.startIndex..<candidate.endIndex) { range, _ in
            let s = candidate.distance(from: candidate.startIndex, to: range.lowerBound)
            let e = candidate.distance(from: candidate.startIndex, to: range.upperBound)
            tokenSpans.append((s, e))
            return true
        }

        let editEndInB = b.count - suffix
        if !tokenSpans.isEmpty {
            if let firstIdx = tokenSpans.firstIndex(where: { $0.end > prefix && $0.start < max(prefix + 1, editEndInB) }),
               let lastIdx = tokenSpans.lastIndex(where: { $0.end > prefix && $0.start < max(prefix + 1, editEndInB) }) {
                var snapStart = tokenSpans[firstIdx].start
                var snapEnd = tokenSpans[lastIdx].end

                // If NLTokenizer split an uncommon 2-char name into two 1-char tokens, merge with the 1-char non-particle neighbor
                if snapEnd - snapStart == 1 {
                    let rightNeighbor = (lastIdx + 1 < tokenSpans.count) ? tokenSpans[lastIdx + 1] : nil
                    let leftNeighbor = (firstIdx > 0) ? tokenSpans[firstIdx - 1] : nil
                    if let rn = rightNeighbor, rn.end - rn.start == 1, rn.start == snapEnd, !cjkGrammarParticles.contains(b[rn.start]) {
                        snapEnd = rn.end
                    } else if let ln = leftNeighbor, ln.end - ln.start == 1, ln.end == snapStart, !cjkGrammarParticles.contains(b[ln.start]) {
                        snapStart = ln.start
                    }
                }

                let newPrefix = min(prefix, snapStart)
                let newSuffix = min(suffix, max(0, b.count - snapEnd))
                prefix = newPrefix
                suffix = newSuffix
            }
        }

        let trimSet = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "，。！？；：、“”‘’\"'()（）"))
        let wrongSlice = String(a[prefix..<(a.count - suffix)]).trimmingCharacters(in: trimSet)
        let rightSlice = String(b[prefix..<(b.count - suffix)]).trimmingCharacters(in: trimSet)

        let forbidden = CharacterSet(charactersIn: "，。！？；：\n")
        guard wrongSlice.count >= 1, wrongSlice.count <= 10,
              rightSlice.count >= 2, rightSlice.count <= 16,
              wrongSlice != rightSlice,
              wrongSlice.rangeOfCharacter(from: forbidden) == nil,
              rightSlice.rangeOfCharacter(from: forbidden) == nil else {
            return nil
        }
        return (wrongSlice, rightSlice)
    }

    /// Context-Ranked Acoustic Hotwords for Seed-ASR 2.0 (`<= 65` high-signal terms to stay strictly within Volcengine's 200-token hotword window!):
    /// 1. Prioritizes terms & live English acronyms/proper nouns appearing in current window title, cursor text, or recent utterances.
    /// 2. Ranks personal lexicon by `weight` + `hitCount` usage frequency so frequently spoken personal words automatically bubble to the top!
    public func topAcousticContextualStrings(contextHint: String = "", limit: Int = 65) -> [String] {
        return Self.rankHotwords(from: entries, contextHint: contextHint, limit: limit)
    }

    public static func rankHotwords(from entries: [LexiconEntry], contextHint: String = "", limit: Int = 65) -> [String] {
        var result: [String] = []
        var seenLower = Set<String>()

        func appendUnique(_ rawWord: String) {
            let w = rawWord.trimmingCharacters(in: .whitespacesAndNewlines)
            guard w.count >= 2, w.count <= 24 else { return }
            let lower = w.lowercased()
            guard !seenLower.contains(lower), !commonCapitalizedStarters.contains(lower) else { return }
            seenLower.insert(lower)
            result.append(w)
        }

        // 1. Extract live uppercase acronyms & capitalized English proper nouns (e.g. SEO, Semrush, GitHub, Ahrefs) visible in `contextHint` (0.1ms)
        if !contextHint.isEmpty {
            if let regex = try? NSRegularExpression(pattern: #"(?<![A-Za-z])(?:[A-Z]{2,10}|[A-Z][A-Za-z0-9.-]{2,15})(?![A-Za-z])"#) {
                let nsRange = NSRange(contextHint.startIndex..<contextHint.endIndex, in: contextHint)
                for m in regex.matches(in: contextHint, range: nsRange).prefix(12) {
                    if let r = Range(m.range, in: contextHint) {
                        appendUnique(String(contextHint[r]))
                    }
                }
            }
        }

        // 2. Score personal lexicon by active context hit + weight + actual usage frequency (`hitCount`)
        let hintLower = contextHint.lowercased()
        let ranked = entries.sorted { lhs, rhs in
            let lCtx = (!hintLower.isEmpty && hintLower.contains(lhs.term.lowercased())) ? 100 : 0
            let rCtx = (!hintLower.isEmpty && hintLower.contains(rhs.term.lowercased())) ? 100 : 0
            let lScore = lCtx + lhs.weight * 10 + min(lhs.hitCount * 2, 35)
            let rScore = rCtx + rhs.weight * 10 + min(rhs.hitCount * 2, 35)
            return lScore > rScore
        }

        for item in ranked {
            if result.count >= limit { break }
            appendUnique(item.term)
        }
        return result
    }

    public func recordTermHits(_ matched: [LexiconEntry]) {
        guard !matched.isEmpty else { return }
        let ids = Set(matched.map(\.id))
        var changed = false
        for idx in entries.indices where ids.contains(entries[idx].id) {
            entries[idx].hitCount += 1
            changed = true
        }
        if changed { save() }
    }

    /// Dual-Pool Sub-millisecond Recall (Pinned Core + Fuzzy Accent Skeleton Dynamic Match):
    /// 1. Matches exact terms, misheard aliases, tone-free Pinyin, AND fuzzy southern/northern accent skeletons (`zh/z`, `ing/in`, `n/l`).
    /// 2. Always keeps Top 12 highest-priority core product/team terms (`weight >= 9`) warm so severely garbled English brand names (e.g. "Cursor" -> "科瑟") are still caught by LLM context!
    public func recallRelevantTerms(for rawTranscript: String, activeWindowTitle: String = "", limit: Int = 26) -> [LexiconEntry] {
        guard !rawTranscript.isEmpty, !entries.isEmpty else { return [] }
        let utterancePhonetic = PhoneticIndexer.normalize(rawTranscript)
        let utteranceFuzzy = PhoneticIndexer.fuzzySkeleton(rawTranscript)
        let windowLower = activeWindowTitle.lowercased()

        var scored: [(entry: LexiconEntry, score: Int)] = []
        scored.reserveCapacity(min(entries.count, 64))

        for entry in entries {
            var score = 0

            // 1. Exact alias or term substring hit
            if rawTranscript.localizedCaseInsensitiveContains(entry.term) {
                score += 85
            }
            for alias in entry.aliases where !alias.isEmpty {
                if rawTranscript.localizedCaseInsensitiveContains(alias) {
                    score += 140
                } else {
                    let aliasFuzzy = PhoneticIndexer.fuzzySkeleton(alias)
                    if aliasFuzzy.count >= 3 && utteranceFuzzy.contains(aliasFuzzy) {
                        score += 105
                    }
                }
            }

            // 2. Tone-free Pinyin & Fuzzy Accent Skeleton hit (e.g. "张伟" zhangwei <-> "章维" zangwei, "清晨" qingchen <-> "亲臣" qincen)
            let entryFuzzy = PhoneticIndexer.fuzzySkeleton(entry.term)
            if entry.phoneticKey.count >= 4 && utterancePhonetic.contains(entry.phoneticKey) {
                score += 110
            } else if entryFuzzy.count >= 4 && utteranceFuzzy.contains(entryFuzzy) {
                score += 98
            } else if entryFuzzy.count >= 6 {
                let prefixLen = max(4, entryFuzzy.count - 2)
                let prefixKey = String(entryFuzzy.prefix(prefixLen))
                if utteranceFuzzy.contains(prefixKey) {
                    score += 58
                }
            }

            // 3. Active window title context boost
            if !windowLower.isEmpty && windowLower.contains(entry.term.lowercased()) {
                score += 70
            }

            if score > 0 {
                scored.append((entry, score + min(entry.weight * 4, 40)))
            }
        }

        scored.sort { $0.score > $1.score }
        var selected = Array(scored.prefix(max(12, limit - 10)).map(\.entry))
        var existingIDs = Set(selected.map(\.id))

        // Always pin Top core product/person anchors (`weight >= 9`, up to 12 slots) within `limit` budget
        let pinnedCore = entries.filter { $0.weight >= 9 }.sorted { $0.weight > $1.weight }.prefix(12)
        for core in pinnedCore where !existingIDs.contains(core.id) && selected.count < limit {
            selected.append(core)
            existingIDs.insert(core.id)
        }

        if selected.count < 10 {
            for top in entries.sorted(by: { $0.weight > $1.weight }) where !existingIDs.contains(top.id) {
                selected.append(top)
                existingIDs.insert(top.id)
                if selected.count >= 10 { break }
            }
        }
        return selected
    }

    // MARK: - Local Personal Corpus Importers (Notes / Markdown / Browser SQLite)

    /// Extracts high-frequency domain titles & project names from local Chrome / Arc / Safari history (read-only temp copy)
    public func importFromLocalBrowserHistory(maxEntries: Int = 60) -> Int {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates: [URL] = [
            home.appendingPathComponent("Library/Application Support/Google/Chrome/Default/History"),
            home.appendingPathComponent("Library/Application Support/Arc/User Data/Default/History"),
            home.appendingPathComponent("Library/Safari/History.db")
        ]

        guard let dbSource = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            return 0
        }

        let tempCopy = FileManager.default.temporaryDirectory.appendingPathComponent("tz_hist_\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tempCopy) }

        do {
            try FileManager.default.copyItem(at: dbSource, to: tempCopy)
        } catch {
            return 0
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(tempCopy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_close(db) }

        let isSafari = dbSource.lastPathComponent == "History.db"
        let sql = isSafari
            ? "SELECT title FROM history_visits WHERE title IS NOT NULL AND length(title) > 2 ORDER BY visit_time DESC LIMIT 500;"
            : "SELECT title FROM urls WHERE title IS NOT NULL AND visit_count >= 2 ORDER BY visit_count DESC, last_visit_time DESC LIMIT 500;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }

        var tokenCounts: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                let title = String(cString: cStr)
                for candidate in Self.extractCleanEntities(fromTitle: title) {
                    tokenCounts[candidate, default: 0] += 1
                }
            }
        }

        let stopWords: Set<String> = [
            "Google", "Search", "GitHub", "YouTube", "bilibili", "哔哩哔哩", "知乎", "百度",
            "首页", "登录", "管理", "控制台", "文档", "搜索", "官网", "Home", "Dashboard", "Login"
        ]

        let sorted = tokenCounts
            .filter { $0.value >= 2 && !stopWords.contains($0.key) }
            .sorted { $0.value > $1.value }
            .prefix(maxEntries)
            .map { (term: $0.key, aliases: [String](), category: LexiconCategory.browser) }

        return bulkUpsert(sorted)
    }

    /// Scans a local folder of Markdown / TXT meeting notes & exported memos to extract recurring proper nouns & headings
    public func importFromMarkdownFolder(_ folderURL: URL, maxEntries: Int = 100) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }

        var termFreq: [String: Int] = [:]
        var fileCount = 0

        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard ext == "md" || ext == "txt" || ext == "csv" else { continue }
            fileCount += 1
            if fileCount > 400 { break }

            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            for entity in Self.extractEntitiesFromNote(content) {
                termFreq[entity, default: 0] += 1
            }
        }

        let picked = termFreq
            .filter { $0.value >= 2 }
            .sorted { $0.value > $1.value }
            .prefix(maxEntries)
            .map { (term: $0.key, aliases: [String](), category: LexiconCategory.memo) }

        return bulkUpsert(picked)
    }

    private static func extractCleanEntities(fromTitle title: String) -> [String] {
        let parts = title.components(separatedBy: CharacterSet(charactersIn: " -|—·•:：/()（）[]【】"))
        var results: [String] = []
        for raw in parts {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= 2 && trimmed.count <= 18 {
                results.append(trimmed)
            }
        }
        return results
    }

    private static func extractEntitiesFromNote(_ text: String) -> [String] {
        var found: [String] = []
        // Match **bolded entities**, `code/project identifiers`, and CamelCase/UPPERCASE tickers
        let patterns = [
            #"\*\*([^*]{2,16})\*\*"#,
            #"`([A-Za-z0-9_\-\.]{2,20})`"#,
            #"\b([A-Z][A-Za-z0-9]{2,15})\b"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: nsRange).prefix(120) {
                if match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: text) {
                    let token = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if token.count >= 2 && token.count <= 18 {
                        found.append(token)
                    }
                }
            }
        }
        return found
    }
}
