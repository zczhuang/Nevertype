import Foundation

// MARK: - Insight statistics (English, 40 WPM typing baseline)
//
// Pure functions over `[DictationRecord]` so they can be unit-tested without a UI.

enum TZStats {
    /// Typing speed used for the "Time saved" estimate.
    static let typingWPM: Double = 40
    /// Records with less time than this are ignored when computing the dictation speed: less speaking time, or, while no record
    /// has a speaking time, less recording time.
    static let minSecondsForSpeed: Double = 0.5

    // MARK: Words

    /// Words in `text`: whitespace-separated tokens for Latin scripts (a token needs at least one letter or digit, so a
    /// lone "-" or "—" does not count) and one word per CJK character.
    static func wordCount(_ text: String) -> Int {
        var count = 0
        var inToken = false
        var tokenHasAlnum = false

        @inline(__always) func closeToken() {
            if inToken && tokenHasAlnum { count += 1 }
            inToken = false
            tokenHasAlnum = false
        }

        for scalar in text.unicodeScalars {
            if isCJKWordScalar(scalar) {
                closeToken()
                count += 1
            } else if scalar.properties.isWhitespace || isCJKPunctuation(scalar) {
                closeToken()
            } else {
                inToken = true
                if scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                    tokenHasAlnum = true
                }
            }
        }
        closeToken()
        return count
    }

    private static func isCJKWordScalar(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3400...0x4DBF,      // CJK Extension A
             0x4E00...0x9FFF,      // CJK Unified Ideographs
             0xF900...0xFAFF,      // CJK Compatibility Ideographs
             0x20000...0x2FA1F,    // CJK Extensions B-F, supplement
             0x3040...0x309F,      // Hiragana
             0x30A0...0x30FF,      // Katakana
             0x31F0...0x31FF,      // Katakana phonetic extensions
             0x1100...0x11FF,      // Hangul Jamo
             0xAC00...0xD7AF:      // Hangul syllables
            return true
        default:
            return false
        }
    }

    private static func isCJKPunctuation(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3000...0x303F,                       // CJK symbols and punctuation
             0xFF01...0xFF0F, 0xFF1A...0xFF20,      // full-width punctuation
             0xFF3B...0xFF40, 0xFF5B...0xFF65:
            return true
        default:
            return false
        }
    }

    // MARK: Totals

    struct Totals: Equatable {
        var words: Int = 0
        var dictationMinutes: Double = 0
        var speedWords: Int = 0
        var speedMinutes: Double = 0

        /// Words per minute of speaking: the words of the records that have a speaking time (at least 0.5 s of it) over those
        /// speaking minutes, so pauses do not slow it down. While no record has a speaking time (a history from before it was
        /// measured) it is words per minute of recording time over the records of at least 0.5 s, as it always was. 0 when
        /// there is nothing to measure.
        var wpm: Int {
            guard speedMinutes > 0.0001 else { return 0 }
            return Int((Double(speedWords) / speedMinutes).rounded())
        }

        /// Estimated minutes saved versus typing the same text at `typingWPM`.
        var savedMinutes: Double {
            max(0, Double(words) / TZStats.typingWPM - dictationMinutes)
        }
    }

    /// `words`, `dictationMinutes` (and so `savedMinutes`) always use the recording time. The speed (`speedWords` over
    /// `speedMinutes`) uses the speaking time as soon as one record has it, and then only the records that have it; it uses the
    /// recording time only while none does, so the two kinds of time never mix in one figure.
    static func totals(_ history: [DictationRecord]) -> Totals {
        var t = Totals()
        let measuredSpeakingTime = history.contains { $0.speakingSeconds != nil }
        for record in history {
            let words = wordCount(record.polishedText)
            t.words += words
            t.dictationMinutes += record.durationSeconds / 60.0
            let speedSeconds = measuredSpeakingTime ? record.speakingSeconds : record.durationSeconds
            if let speedSeconds, speedSeconds >= minSecondsForSpeed {
                t.speedWords += words
                t.speedMinutes += speedSeconds / 60.0
            }
        }
        return t
    }

    // MARK: Formatting

    /// "742", "1.2K", "81.8K", "1.4M".
    static func formatCount(_ n: Int) -> String {
        guard n >= 1_000 else { return "\(max(0, n))" }
        let thousands = (Double(n) / 1_000.0 * 10).rounded() / 10
        if thousands < 1_000 {
            return String(format: "%.1fK", thousands)
        }
        let millions = (Double(n) / 1_000_000.0 * 10).rounded() / 10
        return String(format: "%.1fM", millions)
    }

    /// "1,000", "12,345".
    static func formatGrouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// Splits a duration into (number, unit) pairs: [("42","sec")], [("17","min")], [("15","hr"),("1","min")].
    static func durationParts(minutes: Double) -> [(value: String, unit: String)] {
        let totalSeconds = Int((max(0, minutes) * 60).rounded())
        if totalSeconds == 0 { return [("0", "min")] }
        if totalSeconds < 60 { return [("\(totalSeconds)", "sec")] }
        let totalMinutes = Int((Double(totalSeconds) / 60.0).rounded())
        if totalMinutes < 60 { return [("\(totalMinutes)", "min")] }
        let hours = totalMinutes / 60
        let rest = totalMinutes % 60
        return rest == 0 ? [("\(hours)", "hr")] : [("\(hours)", "hr"), ("\(rest)", "min")]
    }

    // MARK: Activity

    struct Activity: Equatable {
        var activeDays: Int = 0
        var currentStreak: Int = 0
        var longestStreak: Int = 0
        /// Dictations per local day.
        var perDay: [Date: Int] = [:]
        var firstDay: Date? = nil

        var maxPerDay: Int { perDay.values.max() ?? 0 }
    }

    /// Sunday-first Gregorian calendar in the user's time zone (the heatmap rows are S M T W T F S).
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone.current
        c.firstWeekday = 1
        c.locale = Locale(identifier: "en_US")
        return c
    }

    static func activity(_ history: [DictationRecord], now: Date = Date()) -> Activity {
        let cal = calendar
        var perDay: [Date: Int] = [:]
        for record in history {
            perDay[cal.startOfDay(for: record.timestamp), default: 0] += 1
        }
        var a = Activity()
        a.perDay = perDay
        a.activeDays = perDay.count
        a.firstDay = perDay.keys.min()

        let days = perDay.keys.sorted()
        // Longest run of consecutive days.
        var longest = 0, run = 0
        var previous: Date? = nil
        for day in days {
            if let p = previous, cal.date(byAdding: .day, value: 1, to: p) == day {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previous = day
        }
        a.longestStreak = longest

        // Current streak: counts back from today, or from yesterday when today has no dictation yet.
        let today = cal.startOfDay(for: now)
        var cursor: Date
        if perDay[today] != nil {
            cursor = today
        } else if let y = cal.date(byAdding: .day, value: -1, to: today), perDay[y] != nil {
            cursor = y
        } else {
            return a
        }
        var streak = 0
        while perDay[cursor] != nil {
            streak += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        a.currentStreak = streak
        return a
    }

    // MARK: Top apps

    /// Friendly app name for a stored `targetAppName` (the in-app practice pad is saved with a "Nevertype …" name).
    static func displayAppName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Unknown app" }
        if trimmed.hasPrefix(AppBrand.name) { return "\(AppBrand.name) practice pad" }
        return trimmed
    }

    static func topApps(_ history: [DictationRecord], limit: Int = 5) -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        var firstSeen: [String: Int] = [:]
        for (index, record) in history.enumerated() {
            let name = displayAppName(record.targetAppName)
            counts[name, default: 0] += 1
            if firstSeen[name] == nil { firstSeen[name] = index }
        }
        return counts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return (firstSeen[lhs.key] ?? 0) < (firstSeen[rhs.key] ?? 0)
            }
            .prefix(limit)
            .map { (name: $0.key, count: $0.value) }
    }
}

// MARK: - Heatmap model

struct TZHeatmapModel {
    enum CellKind: Equatable {
        case future
        case beforeFirst
        case level(Int)   // 0...4
    }

    struct Cell: Identifiable {
        let id: Int
        let date: Date
        let count: Int
        let kind: CellKind
    }

    /// `columns[c][row]`, row 0 = Sunday.
    let columns: [[Cell]]
    let monthLabels: [(column: Int, text: String)]
    let canPageBack: Bool
    let canPageForward: Bool

    static func level(count: Int, maxCount: Int) -> Int {
        guard count > 0, maxCount > 0 else { return 0 }
        let ratio = Double(count) / Double(maxCount)
        if ratio <= 0.25 { return 1 }
        if ratio <= 0.5 { return 2 }
        if ratio <= 0.75 { return 3 }
        return 4
    }

    static func make(activity: TZStats.Activity, today todayRaw: Date, columns columnCount: Int, monthOffset: Int) -> TZHeatmapModel {
        let cal = TZStats.calendar
        let today = cal.startOfDay(for: todayRaw)
        let first = activity.firstDay ?? today
        let maxCount = activity.maxPerDay

        let endDate: Date
        if monthOffset <= 0 {
            endDate = today
        } else {
            let shifted = cal.date(byAdding: .month, value: -monthOffset, to: today) ?? today
            let comps = cal.dateComponents([.year, .month], from: shifted)
            let monthStart = cal.date(from: comps) ?? shifted
            let nextMonth = cal.date(byAdding: .month, value: 1, to: monthStart) ?? shifted
            endDate = cal.date(byAdding: .day, value: -1, to: nextMonth) ?? shifted
        }

        func weekStart(_ d: Date) -> Date {
            let weekday = cal.component(.weekday, from: d)   // 1 = Sunday
            return cal.date(byAdding: .day, value: -(weekday - 1), to: cal.startOfDay(for: d)) ?? d
        }

        let endWeek = weekStart(endDate)
        let startWeek = cal.date(byAdding: .day, value: -7 * (columnCount - 1), to: endWeek) ?? endWeek

        var grid: [[Cell]] = []
        for c in 0..<columnCount {
            var column: [Cell] = []
            for r in 0..<7 {
                let offset = c * 7 + r
                let date = cal.date(byAdding: .day, value: offset, to: startWeek) ?? startWeek
                let count = activity.perDay[date] ?? 0
                let kind: CellKind
                if date > today {
                    kind = .future
                } else if date < first {
                    kind = .beforeFirst
                } else {
                    kind = .level(level(count: count, maxCount: maxCount))
                }
                column.append(Cell(id: offset, date: date, count: count, kind: kind))
            }
            grid.append(column)
        }

        // Month labels: the first column whose Sunday falls in a new month; a crowded label is dropped.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM"
        var labels: [(column: Int, text: String)] = []
        var previousMonth: Int? = nil
        for c in 0..<columnCount {
            guard let sunday = grid[c].first?.date else { continue }
            let month = cal.component(.month, from: sunday)
            if previousMonth == nil || month != previousMonth {
                labels.append((c, formatter.string(from: sunday)))
            }
            previousMonth = month
        }
        // Drop the first label if it would collide with the second.
        if labels.count >= 2, labels[1].column - labels[0].column < 3 {
            labels.removeFirst()
        }

        let firstWeek = weekStart(first)
        return TZHeatmapModel(
            columns: grid,
            monthLabels: labels,
            canPageBack: startWeek > firstWeek,
            canPageForward: monthOffset > 0
        )
    }
}
