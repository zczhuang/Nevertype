import Foundation
import AppKit
import CoreGraphics
import SwiftUI

/// Self-tests for the pure logic behind the main window (stats, heatmap, summaries, labels).
/// Runs after `SelfTestSuite` as part of `Nevertype --self-test`. The floating pill's error capsule is also drawn
/// offscreen when a window-server session exists (skipped otherwise).
enum TZUISelfTests {
    static func runAll() -> Int32 {
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

        print("==> Running \(AppBrand.name) UI logic suite...")

        let cal = TZStats.calendar
        func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
            cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min)) ?? Date()
        }
        func record(_ day: Date, text: String = "Hello there", seconds: Double = 10, app: String = "Notes", mode: DictationMode = .dictate) -> DictationRecord {
            DictationRecord(timestamp: day, rawTranscript: text, polishedText: text, durationSeconds: seconds, polishLatencyMs: 100, targetAppName: app, mode: mode)
        }

        // 1. Word counting: Latin tokens, CJK characters, markers
        expect(TZStats.wordCount("Hello world") == 2, "wordCount counts whitespace tokens")
        expect(TZStats.wordCount("") == 0 && TZStats.wordCount("   \n ") == 0, "wordCount of empty text is zero")
        expect(TZStats.wordCount("\u{4F60}\u{597D}\u{4E16}\u{754C}") == 4, "wordCount counts one word per CJK character")
        expect(TZStats.wordCount("Hello \u{4F60}\u{597D} world") == 4, "wordCount mixes Latin tokens and CJK characters")
        expect(TZStats.wordCount("- item one") == 2, "wordCount ignores a bare bullet dash")
        expect(TZStats.wordCount("1. First point") == 3, "wordCount counts list numbers")
        expect(TZStats.wordCount("state-of-the-art") == 1, "wordCount keeps hyphenated words together")

        // 2. Number formatting
        expect(TZStats.formatCount(0) == "0" && TZStats.formatCount(742) == "742", "formatCount leaves small numbers alone")
        expect(TZStats.formatCount(1_000) == "1.0K" && TZStats.formatCount(81_800) == "81.8K", "formatCount uses K with one decimal from 1,000")
        expect(TZStats.formatCount(999_960) == "1.0M", "formatCount rolls 1000.0K over to M")
        expect(TZStats.formatGrouped(1000) == "1,000", "formatGrouped uses US separators")

        func joined(_ minutes: Double) -> String {
            TZStats.durationParts(minutes: minutes).map { "\($0.value) \($0.unit)" }.joined(separator: " ")
        }
        expect(joined(0.5) == "30 sec", "durationParts shows seconds under a minute")
        expect(joined(17) == "17 min", "durationParts shows minutes")
        expect(joined(901) == "15 hr 1 min", "durationParts shows hours and minutes")
        expect(joined(2160) == "36 hr", "durationParts drops a zero minute part")
        expect(joined(59.9) == "1 hr", "durationParts rounds 59.9 minutes up to an hour")

        // 3. Totals: WPM ignores records under 0.5 s; time saved uses 40 WPM typing
        let sixty = Array(repeating: "word", count: 60).joined(separator: " ")
        let history = [
            record(date(2026, 11, 24), text: sixty, seconds: 30),
            record(date(2026, 11, 24, 13), text: sixty, seconds: 30),
            record(date(2026, 11, 24, 14), text: "one two three four five", seconds: 0.3)
        ]
        let totals = TZStats.totals(history)
        expect(totals.words == 125, "totals sums words across records")
        expect(totals.wpm == 120, "totals WPM ignores records shorter than 0.5 s")
        expect(abs(totals.dictationMinutes - 1.005) < 0.0001, "totals counts every record in total dictation time")
        expect(abs(totals.savedMinutes - (125.0 / 40.0 - 1.005)) < 0.0001, "totals time saved assumes 40 WPM typing")
        expect(TZStats.totals([]).wpm == 0 && TZStats.totals([]).savedMinutes == 0, "totals of empty history are zero")

        // 4. Activity: streaks relative to a fixed day
        let now = date(2026, 11, 24, 15)
        let streakHistory = [24, 23, 22, 20, 19].map { record(date(2026, 11, $0)) }
        let act = TZStats.activity(streakHistory, now: now)
        expect(act.activeDays == 5 && act.currentStreak == 3 && act.longestStreak == 3, "activity counts days, current streak and longest streak")
        let yesterdayOnly = TZStats.activity([record(date(2026, 11, 23)), record(date(2026, 11, 22))], now: now)
        expect(yesterdayOnly.currentStreak == 2, "current streak survives a day with no dictation yet today")
        let stale = TZStats.activity([record(date(2026, 11, 21))], now: now)
        expect(stale.currentStreak == 0 && stale.longestStreak == 1, "current streak is zero after a missed day")
        let longRun = TZStats.activity((1...10).map { record(date(2026, 11, $0)) } + [record(date(2026, 11, 24))], now: now)
        expect(longRun.longestStreak == 10 && longRun.currentStreak == 1, "longest streak can differ from the current one")

        // 5. Heatmap
        let model = TZHeatmapModel.make(activity: act, today: now, columns: 20, monthOffset: 0)
        expect(model.columns.count == 20 && model.columns.allSatisfy { $0.count == 7 }, "heatmap has 20 week columns of 7 rows")
        expect(cal.component(.weekday, from: model.columns[0][0].date) == 1, "heatmap rows start on Sunday")
        if case .future = model.columns[19][6].kind {
            expect(true, "heatmap leaves days after today blank")
        } else {
            expect(cal.startOfDay(for: model.columns[19][6].date) <= cal.startOfDay(for: now), "heatmap leaves days after today blank")
        }
        if case .beforeFirst = model.columns[0][0].kind {
            expect(true, "heatmap hatches days before the first dictation")
        } else {
            expect(false, "heatmap hatches days before the first dictation")
        }
        expect(TZHeatmapModel.level(count: 0, maxCount: 10) == 0 && TZHeatmapModel.level(count: 1, maxCount: 10) == 1 && TZHeatmapModel.level(count: 10, maxCount: 10) == 4, "heatmap levels scale with the busiest day")
        expect(!model.canPageForward, "heatmap cannot page past today")
        expect(!model.monthLabels.isEmpty && model.monthLabels.allSatisfy { $0.text.count == 3 }, "heatmap labels months with three-letter English names")

        // 6. Top apps and names
        let apps = [
            record(date(2026, 11, 24), app: "Slack"), record(date(2026, 11, 24), app: "Slack"), record(date(2026, 11, 23), app: "Mail"),
            record(date(2026, 11, 22), app: "\(AppBrand.name) Sandbox"), record(date(2026, 11, 22), app: ""), record(date(2026, 11, 21), app: "Mail")
        ]
        let top = TZStats.topApps(apps, limit: 3)
        expect(top.count == 3 && top[0].name == "Slack" && top[0].count == 2 && top[1].name == "Mail", "topApps ranks apps by dictation count")
        expect(TZStats.displayAppName("") == "Unknown app" && TZStats.displayAppName("\(AppBrand.name) Sandbox") == "\(AppBrand.name) practice pad", "displayAppName normalizes empty and in-app names")

        // 7. Labels and shortcuts
        expect(TZShortcutText.keycaps(fromCustomLabel: "\u{2303} + Space") == ["\u{2303}", "Space"], "custom shortcut labels split into keycaps")
        expect(TriggerKeyOption.rightOption.tzKeycaps == ["Right Option"] && TriggerKeyOption.fnKey.tzKeycaps == ["Fn"], "preset triggers become a single keycap")
        expect(TriggerKeyOption.optionSpace.tzKeycaps == ["Option", "Space"], "Option + Space becomes two keycaps")
        expect(LexiconCategory.autoLearned.tzIsAuto && !LexiconCategory.person.tzIsAuto && !LexiconCategory.tzManualCases.contains(.autoLearned), "only the auto-learned category counts as auto-added")
        expect(TZAliasParser.parse("a, b / c; d\u{FF0C}e") == ["a", "b", "c", "d", "e"], "alias parser accepts commas, slashes, semicolons and full-width commas")
        expect(TZDateText.time(date(2026, 11, 17, 15, 7)) == "3:07 PM", "time format is h:mm a")
        expect(TZDateText.longDate(date(2026, 11, 17)) == "November 17, 2026", "long date format is MMMM d, yyyy")
        expect(TZDateText.dayHeading(date(2026, 11, 24, 9), now: now) == "Today" && TZDateText.dayHeading(date(2026, 11, 23, 22), now: now) == "Yesterday", "day headings say Today and Yesterday")
        expect(TZDateText.dayHeading(date(2026, 11, 17), now: now) == "November 17, 2026", "older day headings use the full date")

        // 8. Status message parsing
        expect(TZStatusMessage.parse("✅ Saved").tone == .success && TZStatusMessage.parse("✅ Saved").text == "Saved", "status parser maps the check mark to success")
        expect(TZStatusMessage.parse("❌ Failed to connect").tone == .error, "status parser maps the cross to error")
        expect(TZStatusMessage.parse("⚠️ Slow").tone == .warning, "status parser maps the warning sign to warning")
        expect(TZStatusMessage.parse("✈️ Offline standby took over").text == "Offline standby took over", "status parser drops other leading emoji")
        expect(TZStatusMessage.parse("Plain text").tone == .info && TZStatusMessage.parse("Plain text").text == "Plain text", "status parser leaves plain text alone")

        // 9. Engine and privacy summaries
        var local = TZEngineInputs(config: LLMConfig.default)
        local.localLoaded = true
        local.installedLocal = [.parakeetTDTv2]
        local.activeLocal = .parakeetTDTv2
        let summary = TZEnginesSummary.make(local)
        expect(summary.speech.title == "Parakeet v2" && summary.speech.detail == "On-device" && summary.speech.tone == .green, "engines card describes the on-device speech model")
        expect(summary.cleanup.title == "gemma4:12b-mlx" && summary.cleanup.detail == "Ollama · local", "engines card describes the local Ollama model")
        let privacy = TZPrivacySummary.make(local)
        expect(privacy.isFullyLocal && privacy.text == "Speech recognition runs on-device with Parakeet, and cleanup runs on your local Ollama model. Nothing leaves this Mac.", "privacy text for a fully local setup")

        var verbatim = local
        verbatim.config.formattingStyle = .verbatimLocal
        expect(TZEnginesSummary.make(verbatim).cleanup.title == "No cleanup" && TZPrivacySummary.make(verbatim).isFullyLocal, "verbatim mode counts as local with no cleanup model")

        var cloudCleanup = local
        cloudCleanup.config.selectLocalCloudProvider()
        cloudCleanup.hasCleanupKey = true
        let cloudSummary = TZEnginesSummary.make(cloudCleanup)
        expect(cloudSummary.cleanup.title == "OpenAI" && cloudSummary.cleanup.detail == cloudCleanup.config.modelName, "engines card names a cloud cleanup provider")
        let cloudPrivacy = TZPrivacySummary.make(cloudCleanup)
        expect(!cloudPrivacy.isFullyLocal && cloudPrivacy.text.contains("transcribed text is sent to OpenAI for cleanup") && cloudPrivacy.text.contains("audio stays on this Mac"), "privacy text names the cloud cleanup service")

        var cloudSpeech = local
        cloudSpeech.config.asrProvider = .openAIWhisper
        cloudSpeech.config.openAIASRBaseURL = "https://api.groq.com/openai/v1"
        cloudSpeech.isGroqASR = true
        cloudSpeech.hasOpenAIASRKey = true
        expect(TZEnginesSummary.make(cloudSpeech).speech.title == "Groq Whisper", "engines card names a cloud speech provider")
        expect(TZPrivacySummary.make(cloudSpeech).text.hasPrefix("Your audio is sent to Groq for transcription."), "privacy text names the cloud speech service")

        var noModel = local
        noModel.installedLocal = []
        noModel.localLoaded = false
        noModel.activeLocal = nil
        let noModelLocalCleanup = TZPrivacySummary.make(noModel)
        expect(
            noModelLocalCleanup.text.contains("macOS on-device speech recognition") && noModelLocalCleanup.text.contains("stays on this Mac")
                && noModelLocalCleanup.text.hasSuffix("Nothing leaves this Mac.") && !noModelLocalCleanup.text.contains("Apple") && noModelLocalCleanup.isFullyLocal,
            "privacy text: with no speech model installed, dictation uses macOS on-device recognition, so audio stays on this Mac (nothing is sent to Apple)"
        )
        var noModelCloudCleanup = noModel
        noModelCloudCleanup.config.selectLocalCloudProvider()
        let noModelCloud = TZPrivacySummary.make(noModelCloudCleanup)
        expect(
            !noModelCloud.isFullyLocal && noModelCloud.text.contains("audio stays on this Mac") && noModelCloud.text.contains("transcribed text is sent to OpenAI for cleanup"),
            "privacy text: the macOS on-device fallback with a cloud cleanup model keeps the audio local and names where the text goes"
        )

        // 10. History grouping
        let groups = TZHistoryPage.groupByDay([
            record(date(2026, 11, 24, 15)), record(date(2026, 11, 24, 9)), record(date(2026, 11, 23, 20)), record(date(2026, 11, 20, 8))
        ])
        expect(groups.count == 3 && groups[0].records.count == 2 && groups[1].records.count == 1, "history groups records by calendar day")

        // 11. Floating pill: dictation failure banner and the error capsule (224 x 58 pt panel)
        let panel = FloatingPillLayout.panelSize
        expect(
            DictationFailure.permissionFailures.allSatisfy {
                TZStatusMessage.parse($0.bannerText).tone == .warning && TZStatusMessage.parse($0.bannerText).text == $0.detail
            },
            "dictation failure banners start with the warning emoji, so the main window shows them as warnings with the full explanation"
        )
        expect(
            FloatingPillLayout.errorMaxWidth <= panel.width && FloatingPillLayout.errorMaxWidth >= panel.width - 12
                && FloatingPillLayout.errorMaxLines == 2
                && FloatingPillLayout.errorMaxHeightEstimate <= panel.height - 12,
            "error pill layout: nearly the full 224 pt panel width, at most two lines, and a full pill (about 39 pt) fits the 58 pt panel height with room to spare"
        )
        if TZPillRender.isAvailable {
            let overlong = Array(repeating: "This reason is much too long to fit in the pill.", count: 4).joined(separator: " ")
            let samples = [
                DictationFailure.accessibilityOff.pillText,
                DictationFailure.microphoneOff.pillText,
                DictationFailure.speechRecognitionOff.pillText,
                DictationFailure.engineError(overlong).pillText,
                overlong,
                ""
            ]
            let captures = samples.compactMap { message in TZPillRender.capture { FloatingPillErrorView(message: message) } }
            expect(
                captures.count == samples.count
                    && captures.allSatisfy { !$0.ink.isNull && $0.ink.minX >= 3 && $0.ink.maxX <= panel.width - 3 && $0.ink.minY >= 6 && $0.ink.maxY <= panel.height - 6 },
                "error pill is drawn inside the 224 x 58 pt panel, with margins, for short, two-line, over-long and empty messages (nothing clipped)"
            )
            if captures.count == samples.count {
                let overlongInk = captures[4].ink
                expect(
                    overlongInk.width >= 190 && overlongInk.height > 28 && overlongInk.height <= 46,
                    "an over-long message wraps to two lines, is cut there, and uses nearly the full panel width"
                )
                let again = TZPillRender.capture { FloatingPillErrorView(message: samples[0]) }
                expect(
                    again?.pixels == captures[0].pixels && captures[0].pixels != captures[1].pixels && captures[0].pixels != captures[5].pixels,
                    "the error pill draws its message: different reasons give different pictures, the same reason the same one, and an icon-only pill differs from both"
                )
            }

            // 12. "Thinking" pill shown while the transcript is cleaned up: logo, the word, animated dots
            let thinking = TZPillRender.capture { FloatingPillThinkingView() }
            let thinkingBare = TZPillRender.capture { FloatingPillThinkingView(label: "") }
            if let thinking, let thinkingBare {
                expect(
                    !thinking.ink.isNull && thinking.ink.minX >= 3 && thinking.ink.maxX <= panel.width - 3 && thinking.ink.minY >= 6 && thinking.ink.maxY <= panel.height - 6
                        && thinking.ink.width >= 100 && thinking.ink.width <= 160 && thinking.ink.height >= 26 && thinking.ink.height <= 36,
                    "the Thinking pill (logo, word, dots) is about 130 x 30 pt and sits inside the 224 x 58 pt panel with margins"
                )
                expect(
                    thinking.ink.width - thinkingBare.ink.width >= 40,
                    "the word 'Thinking' is drawn: the capsule is at least 40 pt wider than the logo-and-dots-only one"
                )
            } else {
                expect(false, "the Thinking pill could be drawn offscreen")
            }
        } else {
            print("  - SKIP: no window-server session, so the floating pill's error and Thinking capsules were not drawn offscreen")
        }

        print("==> UI summary: \(passed) passed, \(failed) failed.")
        return failed == 0 ? 0 : 1
    }
}

/// Draws a floating-pill view offscreen at the pill's real 224 x 58 pt panel size, on a transparent background,
/// so the self-tests can check what would reach the screen. Needs a window-server session; callers skip without one.
enum TZPillRender {
    struct Capture {
        /// Raw pixels, for comparing two renders.
        let pixels: Data
        /// Smallest rectangle (points, origin at the top left) holding every non-transparent pixel; `.null` when blank.
        let ink: CGRect
    }

    /// True when this process can reach the window server (a logged-in Mac session). Set `TZ_SKIP_RENDER_TESTS=1` to skip the
    /// offscreen drawing checks anyway (for example on a machine without a GUI session).
    static var isAvailable: Bool {
        ProcessInfo.processInfo.environment["TZ_SKIP_RENDER_TESTS"] == nil && CGSessionCopyCurrentDictionary() != nil
    }

    static func capture<V: View>(_ make: @MainActor () -> V) -> Capture? {
        MainActor.assumeIsolated { render(make()) }
    }

    @MainActor
    private static func render<V: View>(_ content: V) -> Capture? {
        let size = FloatingPillLayout.panelSize
        NSApplication.shared.setActivationPolicy(.prohibited)

        let host = NSHostingView(rootView: content
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .light))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let base = rep.bitmapData, rep.bitsPerSample == 8, rep.samplesPerPixel == 4 else { return nil }

        let alphaOffset = rep.bitmapFormat.contains(.alphaFirst) ? 0 : 3
        let scale = CGFloat(rep.pixelsWide) / size.width
        var minX = rep.pixelsWide, maxX = -1, minY = rep.pixelsHigh, maxY = -1
        for y in 0..<rep.pixelsHigh {
            let row = base + y * rep.bytesPerRow
            for x in 0..<rep.pixelsWide where row[x * 4 + alphaOffset] != 0 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        let pixels = Data(bytes: base, count: rep.bytesPerRow * rep.pixelsHigh)
        guard maxX >= minX, maxY >= minY else { return Capture(pixels: pixels, ink: .null) }
        let ink = CGRect(
            x: CGFloat(minX) / scale,
            y: CGFloat(minY) / scale,
            width: CGFloat(maxX - minX + 1) / scale,
            height: CGFloat(maxY - minY + 1) / scale
        )
        return Capture(pixels: pixels, ink: ink)
    }
}

private extension LLMConfig {
    /// Test helper: switch the cleanup provider to OpenAI with its default endpoint and model.
    mutating func selectLocalCloudProvider() {
        selectProvider(.openai)
    }
}
