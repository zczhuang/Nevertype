import Foundation
import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Raw values are the English scene labels interpolated into the cleanup prompt's `<scene>` tag (never persisted or shown in the UI).
public enum AppToneProfile: String {
    case instantMessaging = "chat (instant messaging)"
    case emailAndFormalDoc = "email or formal document"
    case aiPromptAndNotes = "AI prompt or notes"
    case shellTerminal = "command-line terminal"
}

public struct ActiveScreenContext {
    public let appName: String
    public let bundleID: String
    public let windowTitle: String
    public let selectedText: String
    public let precedingText: String
    public let hasFocusedTextInput: Bool

    public var isStrictShellTerminal: Bool {
        let lower = bundleID.lowercased() + " " + appName.lowercased()
        return ["apple.terminal", "iterm", "warp", "ghostty", "alacritty", "kitty"]
            .contains { lower.contains($0) }
    }

    public var isCodeOrTerminal: Bool {
        let lower = bundleID.lowercased() + " " + appName.lowercased()
        return ["terminal", "iterm", "warp", "ghostty", "xcode", "cursor", "vscode", "code", "zed", "antigravity"]
            .contains { lower.contains($0) }
    }

    public var isInstantMessaging: Bool {
        let lower = bundleID.lowercased() + " " + appName.lowercased()
        return ["telegram", "slack", "discord", "lark", "feishu", "messages", "whatsapp", "dingtalk", "wechat", "xinwechat", "微信", "qq"]
            .contains { lower.contains($0) }
    }

    /// Rich-text IM editors (notably WeChat / QQ on macOS) re-layout on every single `Backspace` CGEvent
    /// and often hide full text from `kAXValueAttribute`. Preferring atomic post-polish replacement avoids
    /// visible "mass backspace rewind" anxiety where users think their spoken content was deleted.
    public var prefersAtomicPolishReplacement: Bool {
        let lower = bundleID.lowercased() + " " + appName.lowercased()
        return ["wechat", "xinwechat", "微信", "com.tencent.qq"]
            .contains { lower.contains($0) }
    }

    public var isEmailOrFormalDoc: Bool {
        let lower = bundleID.lowercased() + " " + appName.lowercased() + " " + windowTitle.lowercased()
        return ["apple.mail", "outlook", "spark", "mimestream", "gmail", "word", "pages", "docs.google"]
            .contains { lower.contains($0) }
    }

    /// P1: App-Aware Tone Matrix routing
    public var toneProfile: AppToneProfile {
        if isStrictShellTerminal { return .shellTerminal }
        if isInstantMessaging { return .instantMessaging }
        if isEmailOrFormalDoc { return .emailAndFormalDoc }
        return .aiPromptAndNotes
    }

    public static let empty = ActiveScreenContext(
        appName: "",
        bundleID: "",
        windowTitle: "",
        selectedText: "",
        precedingText: "",
        hasFocusedTextInput: true
    )
}

/// Doubao-grade Adaptive Cruise Typewriter + Prefix-Preserving Zero-Flicker SSE Morph Session:
/// - Runs character emission on a dedicated `.userInteractive` real-time serial queue (100% isolated from `@MainActor` UI!).
/// - Uses Phase-Locked Adaptive Cruise Pacing (`11ms–42ms` dynamic interval based on live queue depth) so characters glide out continuously with ZERO burst-and-freeze stutter!
/// - Preserves matching leading characters during SSE LLM polish so unchanged prefixes NEVER flicker or re-type!
public final class LiveInputSession: @unchecked Sendable {
    private static let pacerQueue = DispatchQueue(label: "io.github.typezero.typewriter.pacer", qos: .userInteractive)

    private var context: ActiveScreenContext
    /// Characters actually emitted to the OS input box so far
    private var emittedText: String = ""
    /// Characters confirmed by Local Agreement, waiting in the smooth adaptive cruise queue
    private var targetConfirmedText: String = ""
    /// Latest raw hypothesis accepted from the cloud ASR stream (tracked separately so DDC filler deletion never stalls forward output!)
    private var lastAcceptedCloudRaw: String = ""
    private var previousHypothesis: String = ""
    private var pacerTimer: DispatchSourceTimer?
    private var isPacerStopped: Bool = false
    private var abortedByUserSubmit: Bool = false
    private var lastEmitUptimeNs: UInt64 = 0
    private let stateLock = NSLock()

    // Prefix-preserving SSE streaming state
    private var draftBeforeSSE: String = ""
    private var sseAccumulated: String = ""
    private var sseHasDiverged: Bool = false
    /// Buffers up to 5 chars immediately following a '\n' so we can detect & skip Markdown editor auto-inserted `2. ` / `- ` markers!
    private var postNewlineGuardBuffer: String? = nil

    private static let unstableTrailingPunctuation = CharacterSet(charactersIn: "。，、！？；：.,!?;:… ")

    public init(context: ActiveScreenContext) {
        self.context = context
        startSmoothTypewriterPacer()
    }

    public func updateContext(_ newContext: ActiveScreenContext) {
        stateLock.lock()
        self.context = newContext
        stateLock.unlock()
    }

    deinit {
        stopPacer()
    }

    public var currentText: String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return emittedText
    }

    /// Drafts longer than this threshold skip live SSE backspace-morphing and instead stay steady on screen
    /// until LLM polishing completes, then swap atomically in one shot (eliminating "mass delete" visual anxiety).
    public static let maxDraftCharsForLiveSSE = 24

    public static func shouldUseLiveSSEStream(draft: String, context: ActiveScreenContext) -> Bool {
        if context.prefersAtomicPolishReplacement {
            return false
        }
        if draft.count > maxDraftCharsForLiveSSE {
            return false
        }
        return true
    }

    public func abortBecauseUserSubmitted() {
        stopPacer(drainQueue: false)
        stateLock.lock()
        abortedByUserSubmit = true
        stateLock.unlock()
    }

    /// Detects when an AX-readable input box (e.g. Antigravity, Cursor, Chrome, Slack) is explicitly empty (`""`)
    /// after we already typed 4+ chars live into it — proving the user already sent/cleared the draft!
    public static func isBoxClearedAfterLiveEmit(
        currentBoxText: String?,
        alreadyEmitted: String,
        isRichSlowEditor: Bool
    ) -> Bool {
        guard !isRichSlowEditor, alreadyEmitted.count >= 4 else { return false }
        guard let box = currentBoxText else { return false }
        return box.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// When `Cmd+A` + `Cmd+C` times out (`copyTimeout`, pasteboard unchanged for >220ms) after we already emitted
    /// 4+ chars live into the box, the box is empty (user already hit Enter/Send or unfocused). NEVER blind-paste again!
    public static func shouldAbortOnAtomicProbeFailure(probeReason: String, alreadyEmitted: String) -> Bool {
        return probeReason == "copyTimeout" && alreadyEmitted.count >= 4
    }

    public static func computeAtomicReplacementDiff(emitted: String, finalText: String) -> (commonPrefixCount: Int, replaceCount: Int, replacementSuffix: String) {
        let eChars = Array(emitted)
        let fChars = Array(finalText)
        var common = 0
        let lim = min(eChars.count, fChars.count)
        while common < lim && eChars[common] == fChars[common] {
            common += 1
        }
        let replaceCount = eChars.count - common
        let replacementSuffix = common < fChars.count ? String(fChars[common...]) : ""
        return (common, replaceCount, replacementSuffix)
    }

    /// Safely computes the full-box replacement string after a `Cmd+A` + `Cmd+C` probe in rich editors (e.g. WeChat Qt)
    /// that hide `kAXValueAttribute`. Preserves any user-typed text before or after the dictated draft.
    public static func buildMergedBoxReplacement(boxText: String, alreadyEmitted: String, finalText: String) -> String? {
        let normalizedBox = boxText.replacingOccurrences(of: "\r\n", with: "\n")
        let normalizedEmitted = alreadyEmitted.replacingOccurrences(of: "\r\n", with: "\n")
        guard !normalizedBox.isEmpty, !normalizedEmitted.isEmpty else { return nil }

        let trimmedBox = normalizedBox.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmitted = normalizedEmitted.trimmingCharacters(in: .whitespacesAndNewlines)

        // Case 1: The compose box contains ONLY this dictation draft (95%+ of daily chat messages).
        if trimmedBox == trimmedEmitted {
            return finalText
        }
        let boxCore = alphanumericOnly(trimmedBox)
        let emittedCore = alphanumericOnly(trimmedEmitted)
        if !boxCore.isEmpty && boxCore == emittedCore {
            return finalText
        }

        // Case 2: User had existing typed text before (or around) this dictation draft — replace only the last match!
        if let range = normalizedBox.range(of: normalizedEmitted, options: .backwards) {
            return normalizedBox.replacingCharacters(in: range, with: finalText)
        }
        let strippedEmitted = stripTrailingPunctuation(trimmedEmitted)
        if strippedEmitted.count >= 4,
           let range = normalizedBox.range(of: strippedEmitted, options: .backwards) {
            var replaceEnd = range.upperBound
            while replaceEnd < normalizedBox.endIndex {
                let ch = normalizedBox[replaceEnd]
                if ch.unicodeScalars.allSatisfy({ unstableTrailingPunctuation.contains($0) }) {
                    replaceEnd = normalizedBox.index(after: replaceEnd)
                } else {
                    break
                }
            }
            return normalizedBox.replacingCharacters(in: range.lowerBound..<replaceEnd, with: finalText)
        }

        return nil
    }

    /// P3 Prefix-Preserving SSE Streaming Polish:
    /// Flushes any pending 1–2 characters in the typewriter queue, snapshots `draftBeforeSSE`,
    /// and decides whether to stream SSE inline (short drafts in fast editors) or keep the draft steady
    /// for a zero-rewind atomic swap in `finalizeAfterKeyRelease` (long drafts & WeChat/QQ rich editors).
    @discardableResult
    public func prepareForSSEPolishStream() -> Bool {
        stopPacer(drainQueue: true)
        stateLock.lock()
        let ctx = self.context
        if targetConfirmedText.count > emittedText.count && targetConfirmedText.hasPrefix(emittedText) {
            let rem = String(targetConfirmedText.dropFirst(emittedText.count))
            emittedText = targetConfirmedText
            stateLock.unlock()
            ContextInjector.typeCleanUnicode(rem)
            stateLock.lock()
        }
        draftBeforeSSE = emittedText
        let currentDraft = draftBeforeSSE
        sseAccumulated = ""
        sseHasDiverged = false
        postNewlineGuardBuffer = nil
        stateLock.unlock()

        guard ContextInjector.isAllowedTarget(bundleID: ctx.bundleID, appName: ctx.appName),
              AXIsProcessTrusted() else {
            return false
        }
        if !ctx.hasFocusedTextInput && !ContextInjector.isLikelyEditableFocusNow() {
            return false
        }
        return Self.shouldUseLiveSSEStream(draft: currentDraft, context: ctx)
    }

    public func consumeSSEChunk(_ delta: String) {
        guard !delta.isEmpty else { return }
        stateLock.lock()
        if abortedByUserSubmit {
            stateLock.unlock()
            return
        }
        sseAccumulated.append(delta)

        if sseHasDiverged {
            emittedText.append(delta)
            targetConfirmedText = emittedText
            stateLock.unlock()
            emitSSEDeltaGuardingAutoList(delta)
            return
        }

        // Still matching `draftBeforeSSE` prefix? Keep screen rock-steady with ZERO backspaces!
        if draftBeforeSSE.hasPrefix(sseAccumulated) {
            stateLock.unlock()
            return
        }

        // First divergence point reached! Keep common prefix intact, only backspace the changed tail!
        sseHasDiverged = true
        let dChars = Array(draftBeforeSSE)
        let sChars = Array(sseAccumulated)
        var common = 0
        let lim = min(dChars.count, sChars.count)
        while common < lim && dChars[common] == sChars[common] {
            common += 1
        }

        let backspacesNeeded = dChars.count - common
        let newSuffix = common < sChars.count ? String(sChars[common...]) : ""
        emittedText = sseAccumulated
        targetConfirmedText = sseAccumulated
        stateLock.unlock()

        if backspacesNeeded > 0 {
            if common == 0,
               backspacesNeeded > 14,
               let box = ContextInjector.readCurrentFocusedValue(),
               box.trimmingCharacters(in: .whitespacesAndNewlines) == draftBeforeSSE.trimmingCharacters(in: .whitespacesAndNewlines) {
                ContextInjector.sendSelectAllEvent()
                usleep(4_000)
                if newSuffix.isEmpty {
                    ContextInjector.sendCleanBackspaces(count: 1)
                }
            } else {
                ContextInjector.sendCleanBackspaces(count: backspacesNeeded)
                if !newSuffix.isEmpty {
                    usleep(4_000)
                }
            }
        }
        if !newSuffix.isEmpty {
            emitSSEDeltaGuardingAutoList(newSuffix)
        }
    }

    /// Streams SSE text while preventing Markdown-aware editors (Antigravity, Notion, Feishu, Obsidian)
    /// from producing `2. 2. ` or `- - ` when `Shift+Return` auto-inserts the next list marker!
    private func emitSSEDeltaGuardingAutoList(_ text: String) {
        for ch in text {
            if ch == "\n" {
                flushPostNewlineGuardBufferIfAny()
                ContextInjector.sendSoftNewlineShiftReturn()
                stateLock.lock()
                postNewlineGuardBuffer = ""
                stateLock.unlock()
                continue
            }

            stateLock.lock()
            let hasGuard = (postNewlineGuardBuffer != nil)
            if hasGuard {
                postNewlineGuardBuffer?.append(ch)
                let buf = postNewlineGuardBuffer ?? ""
                // Wait up to 5 chars (e.g. "12. X" or "2. 准") to see if a list prefix formed
                let mightStillBeBuildingPrefix = buf.count < 5 && buf.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" || $0 == "*" || $0 == "•" || $0 == " " })
                if mightStillBeBuildingPrefix {
                    stateLock.unlock()
                    continue
                }
                postNewlineGuardBuffer = nil
                stateLock.unlock()
                ContextInjector.typePostNewlineSkippingEditorAutoMarker(buf)
            } else {
                stateLock.unlock()
                ContextInjector.typeCleanUnicode(String(ch))
            }
        }
    }

    private func flushPostNewlineGuardBufferIfAny() {
        stateLock.lock()
        let pending = postNewlineGuardBuffer
        postNewlineGuardBuffer = nil
        stateLock.unlock()
        if let pending, !pending.isEmpty {
            ContextInjector.typePostNewlineSkippingEditorAutoMarker(pending)
        }
    }

    /// Reconciles final post-formatted text AND cleans up any residual duplicated list prefixes (`2. 2. ` -> `2. `).
    public func finishSSEPolishStream(with finalFormatted: String) {
        stateLock.lock()
        if abortedByUserSubmit {
            stateLock.unlock()
            ContextInjector.appendInjectionTrace("finishSSE branch=abortedUserSubmit final=\(finalFormatted.count)")
            return
        }
        stateLock.unlock()

        flushPostNewlineGuardBufferIfAny()

        stateLock.lock()
        let currentOnScreen = sseHasDiverged ? emittedText : draftBeforeSSE
        emittedText = finalFormatted
        targetConfirmedText = finalFormatted
        stateLock.unlock()

        if currentOnScreen != finalFormatted {
            ContextInjector.applyCleanUnicodeDelta(from: currentOnScreen, to: finalFormatted)
        }

        // Final DOM truth verification for multi-line lists: if an editor asynchronously inserted `2. 2. `, snap it clean!
        if finalFormatted.contains("\n") {
            usleep(12_000)
            if let actualBox = ContextInjector.readCurrentFocusedValue(),
               ContextInjector.containsDuplicatedListMarker(in: actualBox, expected: finalFormatted) {
                let collapsed = ContextInjector.collapseDuplicatedListMarkers(actualBox)
                if collapsed.trimmingCharacters(in: .whitespacesAndNewlines) == finalFormatted.trimmingCharacters(in: .whitespacesAndNewlines) {
                    ContextInjector.sendSelectAllEvent()
                    usleep(6_000)
                    ContextInjector.pasteViaClipboardPreservingSnapshot(finalFormatted)
                }
            }
        }
    }

    /// Starts a 6ms high-refresh real-time clock on dedicated `pacerQueue` driving the ProMotion Single-Char Pacer.
    private func startSmoothTypewriterPacer() {
        let timer = DispatchSource.makeTimerSource(queue: Self.pacerQueue)
        timer.schedule(deadline: .now() + .milliseconds(4), repeating: .milliseconds(6), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            self?.tickAdaptiveCruiseStep()
        }
        self.pacerTimer = timer
        timer.resume()
    }

    private func stopPacer(drainQueue: Bool = false) {
        stateLock.lock()
        isPacerStopped = true
        let timer = pacerTimer
        pacerTimer = nil
        stateLock.unlock()
        timer?.cancel()
        if drainQueue {
            Self.pacerQueue.sync {}
        }
    }

    private func tickAdaptiveCruiseStep() {
        guard AXIsProcessTrusted() else { return }

        stateLock.lock()
        if isPacerStopped {
            stateLock.unlock()
            return
        }
        // Doubao iOS-style Live Tail Revision: if Seed-ASR 2.0 revised the last 1–8 chars near the cursor
        // (e.g. "星合" -> "星河", "期末" -> "契合"), snap back those <=8 chars in <1ms on this serial queue!
        if !targetConfirmedText.hasPrefix(emittedText) {
            let eChars = Array(emittedText)
            let tChars = Array(targetConfirmedText)
            var common = 0
            let lim = min(eChars.count, tChars.count)
            while common < lim && eChars[common] == tChars[common] {
                common += 1
            }
            let eraseCount = eChars.count - common
            if eraseCount > 0 && eraseCount <= 8 && !emittedText.suffix(eraseCount).contains("\n") {
                emittedText = String(eChars.prefix(common))
                lastEmitUptimeNs = DispatchTime.now().uptimeNanoseconds
                stateLock.unlock()
                ContextInjector.sendCleanBackspaces(count: eraseCount)
                return
            }
            // ZERO-DEADLOCK FAILSAFE: if divergence somehow exceeded 8 chars (e.g. race with in-flight char
            // or newline boundary), NEVER stall forever! Re-anchor `targetConfirmedText` onto `emittedText`
            // plus any un-emitted continuation suffix so forward streaming immediately resumes.
            let cont = Self.extractNewContinuationSuffix(alreadyConfirmed: emittedText, newStable: targetConfirmedText) ?? ""
            targetConfirmedText = emittedText + cont
            if cont.isEmpty {
                stateLock.unlock()
                return
            }
        }

        let emittedCount = emittedText.count
        let targetCount = targetConfirmedText.count
        guard targetCount > emittedCount else {
            stateLock.unlock()
            return
        }

        let backlog = targetCount - emittedCount
        let nowNs = DispatchTime.now().uptimeNanoseconds

        // Doubao iOS ProMotion Single-Glyph Curve (11ms–18ms per character, 0ms instant first char):
        // Eliminates the old 58ms slow-motion brake while preserving crisp 1-by-1 character popping!
        let requiredIntervalMs: UInt64 = {
            if backlog == 1 { return 18 }
            if backlog == 2 { return 14 }
            if backlog <= 5 { return 11 }
            return 8
        }()

        if lastEmitUptimeNs > 0 && (nowNs - lastEmitUptimeNs) < requiredIntervalMs * 1_000_000 {
            stateLock.unlock()
            return
        }

        // Strict single-character emission for CJK so every single character visibly pops out one-by-one!
        let stepCount: Int = {
            if backlog > 18 { return 2 }
            let nextChar = targetConfirmedText[targetConfirmedText.index(targetConfirmedText.startIndex, offsetBy: emittedCount)]
            if nextChar.isASCII && backlog >= 3 { return 2 }
            return 1
        }()

        let startIdx = targetConfirmedText.index(targetConfirmedText.startIndex, offsetBy: emittedCount)
        let endIdx = targetConfirmedText.index(startIdx, offsetBy: min(stepCount, backlog))
        let chunk = String(targetConfirmedText[startIdx..<endIdx])
        emittedText.append(chunk)
        lastEmitUptimeNs = nowNs
        stateLock.unlock()

        ContextInjector.typeCleanUnicode(chunk)
    }

    /// Updates the confirmed target string:
    /// - Cloud `Seed-ASR 2.0` (`isCloudStream == true`): zero `dropLast(1)` lag + live <=6-char tail self-correction + 0ms instant first-char fire!
    /// - Local offline `SenseVoice` (`isCloudStream == false`): uses `computeLocalAgreement` anti-flicker guard.
    @discardableResult
    public func updateLiveText(_ rawHypothesis: String, flushTrailingChar: Bool = false, isCloudStream: Bool = false) -> Bool {
        stateLock.lock()
        let ctx = self.context
        let isStartOfUtterance = targetConfirmedText.isEmpty
        stateLock.unlock()

        guard ContextInjector.isAllowedTarget(bundleID: ctx.bundleID, appName: ctx.appName),
              AXIsProcessTrusted() else {
            return false
        }

        let trimmedHypothesis = Self.stripTrailingPunctuation(rawHypothesis)
        guard !trimmedHypothesis.isEmpty else { return true }

        let stableCandidate: String
        if isCloudStream {
            stableCandidate = trimmedHypothesis
        } else {
            stableCandidate = Self.computeLocalAgreement(
                prev: previousHypothesis,
                curr: trimmedHypothesis,
                fastFirstSyllable: isStartOfUtterance,
                flushTrailingChar: flushTrailingChar
            )
        }
        previousHypothesis = trimmedHypothesis

        var didAdvanceOrRevise = false
        stateLock.lock()
        let reconciled = Self.reconcileLiveTargetAdvance(
            emitted: emittedText,
            targetConfirmed: targetConfirmedText,
            lastCloudRaw: lastAcceptedCloudRaw,
            newStable: stableCandidate,
            isCloudStream: isCloudStream
        )
        targetConfirmedText = reconciled.nextTarget
        lastAcceptedCloudRaw = reconciled.nextCloudRaw
        didAdvanceOrRevise = reconciled.didAdvanceOrRevise
        stateLock.unlock()

        // Fire first character IMMEDIATELY (`0.0ms` wait) on `pacerQueue` instead of waiting for next timer tick!
        if didAdvanceOrRevise {
            Self.pacerQueue.async { [weak self] in
                self?.tickAdaptiveCruiseStep()
            }
        }
        return true
    }

    /// Pure, deadlock-free reconciliation for live inline dictation:
    /// 1. Fast-path exact growth when `newStable` extends `targetConfirmed`.
    /// 2. Live near-cursor self-correction when divergence from `emitted` is `<= 6` chars (with no newline).
    /// 3. Deep revision / DDC filler-deletion recovery: aligns against `lastCloudRaw` so shrinking an earlier
    ///    filler phrase NEVER stalls subsequent spoken words from streaming onto screen immediately!
    public static func reconcileLiveTargetAdvance(
        emitted: String,
        targetConfirmed: String,
        lastCloudRaw: String,
        newStable: String,
        isCloudStream: Bool
    ) -> (nextTarget: String, nextCloudRaw: String, didAdvanceOrRevise: Bool) {
        guard !newStable.isEmpty else {
            return (targetConfirmed, lastCloudRaw, false)
        }
        if !isCloudStream {
            if let continuation = extractNewContinuationSuffix(alreadyConfirmed: targetConfirmed, newStable: newStable),
               !continuation.isEmpty {
                return (targetConfirmed + continuation, lastCloudRaw, true)
            }
            return (targetConfirmed, lastCloudRaw, false)
        }

        // Cloud Stream Fast Path 1: exact prefix growth on screen target
        if newStable.hasPrefix(targetConfirmed) {
            if newStable.count > targetConfirmed.count {
                return (newStable, newStable, true)
            }
            return (targetConfirmed, newStable, false)
        }

        // Cloud Stream Path 2: near-cursor self-correction (<= 6 chars from emitted, no newline in erased tail)
        let eChars = Array(emitted)
        let sChars = Array(newStable)
        var common = 0
        let lim = min(eChars.count, sChars.count)
        while common < lim && eChars[common] == sChars[common] {
            common += 1
        }
        let eraseFromEmitted = eChars.count - common
        if eraseFromEmitted <= 6
            && sChars.count >= common + 1
            && !emitted.suffix(eraseFromEmitted).contains("\n")
            && !newStable.contains("\n") {
            return (newStable, newStable, true)
        }

        // Cloud Stream Path 3: Deep revision (>6 chars back) or DDC filler deletion.
        // Align new spoken words against `lastCloudRaw` (falling back to `targetConfirmed`) so even if DDC
        // deleted 5 filler chars earlier in the sentence, EVERY new word still appends immediately with 0 stall!
        let baseline = lastCloudRaw.isEmpty ? targetConfirmed : lastCloudRaw
        if newStable.hasPrefix(baseline) {
            let delta = String(newStable.dropFirst(baseline.count))
            if !delta.isEmpty {
                return (targetConfirmed + delta, newStable, true)
            }
            return (targetConfirmed, newStable, false)
        }
        if let continuation = extractNewContinuationSuffix(alreadyConfirmed: baseline, newStable: newStable),
           !continuation.isEmpty {
            return (targetConfirmed + continuation, newStable, true)
        }
        // If DDC shrunk `newStable` compared to `baseline` with no new words yet, advance `lastCloudRaw` to the
        // shrunk string immediately so the VERY NEXT syllable spoken extends `newStable` with 0 payback stall!
        if alphanumericOnly(newStable).count < alphanumericOnly(baseline).count {
            return (targetConfirmed, newStable, false)
        }
        return (targetConfirmed, lastCloudRaw.isEmpty ? newStable : lastCloudRaw, false)
    }

    /// Pass 2 (On stop tap): Stops pacer, flushes any remaining confirmed chars, and applies final text cleanly.
    /// P4 Safety Vault: Returns `false` if no editable text field accepted the input, keeping `finalText` safely in NSPasteboard!
    @discardableResult
    public func finalizeAfterKeyRelease(with finalText: String) -> Bool {
        stopPacer(drainQueue: true)
        stateLock.lock()
        let aborted = abortedByUserSubmit
        let ctx = self.context
        let alreadyEmitted = emittedText
        stateLock.unlock()

        if aborted {
            ContextInjector.appendInjectionTrace("finalize app=\(ctx.bundleID) branch=abortedUserSubmit emitted=\(alreadyEmitted.count) final=\(finalText.count)")
            return true
        }

        let isRichSlowEditor = ctx.prefersAtomicPolishReplacement
        let prePasteUs: useconds_t = isRichSlowEditor ? 55_000 : 35_000
        let baseRestoreSec: TimeInterval = isRichSlowEditor ? 1.50 : 1.00

        guard ContextInjector.isAllowedTarget(bundleID: ctx.bundleID, appName: ctx.appName),
              AXIsProcessTrusted() else {
            ContextInjector.saveToSafetyClipboard(finalText)
            ContextInjector.appendInjectionTrace("finalize app=\(ctx.bundleID) branch=untrusted emitted=\(alreadyEmitted.count) final=\(finalText.count)")
            return false
        }

        // If user never clicked into an input field (e.g. Finder or desktop focused), save directly to Safety Vault clipboard!
        if !ContextInjector.isLikelyEditableFocusNow() && !ctx.hasFocusedTextInput {
            ContextInjector.saveToSafetyClipboard(finalText)
            ContextInjector.appendInjectionTrace("finalize app=\(ctx.bundleID) branch=noFocus emitted=\(alreadyEmitted.count) final=\(finalText.count)")
            return false
        }

        if alreadyEmitted.isEmpty {
            ContextInjector.pasteViaClipboardPreservingSnapshot(
                finalText,
                prePasteDelayUs: prePasteUs,
                restoreDelaySeconds: baseRestoreSec
            )
            ContextInjector.appendInjectionTrace("finalize app=\(ctx.bundleID) branch=emptyEmittedPaste final=\(finalText.count)")
            stateLock.lock()
            emittedText = finalText
            targetConfirmedText = finalText
            stateLock.unlock()
            return true
        }

        let currentBoxText = ContextInjector.readCurrentFocusedValue()
        let boxLen = currentBoxText?.count ?? -1

        // Guard A: On standard AX apps (Antigravity, Cursor, Chrome, Slack, etc.), if we already typed 4+ chars
        // live into the box and the box is now explicitly empty `""`, the user already pressed Enter / clicked Send!
        // NEVER re-paste a ghost duplicate back into the freshly emptied box!
        if Self.isBoxClearedAfterLiveEmit(
            currentBoxText: currentBoxText,
            alreadyEmitted: alreadyEmitted,
            isRichSlowEditor: isRichSlowEditor
        ) {
            ContextInjector.appendInjectionTrace("finalize app=\(ctx.bundleID) branch=abortedBoxEmpty emitted=\(alreadyEmitted.count) boxLen=\(boxLen) final=\(finalText.count)")
            return true
        }

        // Only treat AX value as proof that emitted text didn't land when AX actually returned a NON-EMPTY string!
        // Qt/Canvas editors (like WeChat 4.0) may return "" or nil even while the live draft is visibly inside the box.
        if let actualValue = currentBoxText,
           !actualValue.isEmpty,
           !actualValue.contains(alreadyEmitted) {
            ContextInjector.pasteViaClipboardPreservingSnapshot(
                finalText,
                prePasteDelayUs: prePasteUs,
                restoreDelaySeconds: baseRestoreSec
            )
            ContextInjector.appendInjectionTrace("finalize app=\(ctx.bundleID) branch=axMismatchPaste emitted=\(alreadyEmitted.count) boxLen=\(boxLen) final=\(finalText.count)")
            stateLock.lock()
            emittedText = finalText
            targetConfirmedText = finalText
            stateLock.unlock()
            return true
        }

        if finalText == alreadyEmitted {
            ContextInjector.appendInjectionTrace("finalize app=\(ctx.bundleID) branch=exactMatch emitted=\(alreadyEmitted.count) boxLen=\(boxLen)")
            return true
        }

        if finalText.hasPrefix(alreadyEmitted) {
            let tail = String(finalText.dropFirst(alreadyEmitted.count))
            if !tail.contains("\n") {
                ContextInjector.typeCleanUnicode(tail)
                ContextInjector.appendInjectionTrace("finalize app=\(ctx.bundleID) branch=appendTail emitted=\(alreadyEmitted.count) tail=\(tail.count) boxLen=\(boxLen)")
                stateLock.lock()
                emittedText = finalText
                targetConfirmedText = finalText
                stateLock.unlock()
                return true
            }
        }

        if let box = currentBoxText,
           !box.isEmpty,
           box.trimmingCharacters(in: .whitespacesAndNewlines) == alreadyEmitted.trimmingCharacters(in: .whitespacesAndNewlines) {
            ContextInjector.sendSelectAllEvent()
            usleep(isRichSlowEditor ? 55_000 : 20_000)
            ContextInjector.pasteViaClipboardPreservingSnapshot(
                finalText,
                prePasteDelayUs: prePasteUs,
                restoreDelaySeconds: baseRestoreSec
            )
            ContextInjector.appendInjectionTrace("finalize app=\(ctx.bundleID) branch=cmdA emitted=\(alreadyEmitted.count) boxLen=\(boxLen) final=\(finalText.count)")
        } else {
            let diff = Self.computeAtomicReplacementDiff(emitted: alreadyEmitted, finalText: finalText)
            if diff.replaceCount == 0 {
                if !diff.replacementSuffix.isEmpty {
                    ContextInjector.pasteViaClipboardPreservingSnapshot(
                        diff.replacementSuffix,
                        prePasteDelayUs: prePasteUs,
                        restoreDelaySeconds: baseRestoreSec
                    )
                }
                ContextInjector.appendInjectionTrace("finalize app=\(ctx.bundleID) branch=diffAppend emitted=\(alreadyEmitted.count) boxLen=\(boxLen) suffix=\(diff.replacementSuffix.count)")
            } else if diff.replacementSuffix.isEmpty {
                ContextInjector.sendCleanBackspaces(count: diff.replaceCount)
                ContextInjector.appendInjectionTrace("finalize app=\(ctx.bundleID) branch=diffTrimBackspace emitted=\(alreadyEmitted.count) boxLen=\(boxLen) replace=\(diff.replaceCount)")
            } else if ContextInjector.trySelectTrailingCharactersViaAX(count: diff.replaceCount) {
                usleep(20_000)
                ContextInjector.pasteViaClipboardPreservingSnapshot(
                    diff.replacementSuffix,
                    prePasteDelayUs: prePasteUs,
                    restoreDelaySeconds: baseRestoreSec
                )
                ContextInjector.appendInjectionTrace("finalize app=\(ctx.bundleID) branch=axRangeSelect emitted=\(alreadyEmitted.count) boxLen=\(boxLen) common=\(diff.commonPrefixCount) replace=\(diff.replaceCount) suffix=\(diff.replacementSuffix.count)")
            } else if (isRichSlowEditor && diff.replaceCount >= 6) || diff.replaceCount > 12 {
                // Zero-rewind one-frame replacement for editors that hide kAXValueAttribute (notably WeChat 4.0 Qt):
                // Cmd+A -> Cmd+C verify (preserving any earlier typed text & guarding against rich media) -> Cmd+V!
                let probe = ContextInjector.tryAtomicSelectAllCopyReplace(
                    alreadyEmitted: alreadyEmitted,
                    finalText: finalText,
                    prePasteDelayUs: prePasteUs,
                    restoreDelaySeconds: baseRestoreSec
                )
                if probe.succeeded {
                    ContextInjector.appendInjectionTrace("finalize app=\(ctx.bundleID) branch=cmdACopyPaste emitted=\(alreadyEmitted.count) boxLen=\(boxLen) final=\(finalText.count) detail=\(probe.reason)")
                } else if Self.shouldAbortOnAtomicProbeFailure(probeReason: probe.reason, alreadyEmitted: alreadyEmitted) {
                    // `Cmd+A` + `Cmd+C` timed out (>220ms) after we already emitted live text -> box is empty (already sent)!
                    // Abort cleanly instead of blind-pasting a ghost duplicate into an empty compose box!
                    ContextInjector.appendInjectionTrace("finalize app=\(ctx.bundleID) branch=abortedCopyTimeoutEmptyBox emitted=\(alreadyEmitted.count) boxLen=\(boxLen) final=\(finalText.count)")
                    return true
                } else {
                    ContextInjector.selectLeftCharacters(count: diff.replaceCount, slowRichEditor: isRichSlowEditor)
                    let perCharUs = isRichSlowEditor ? 3_500 : 700
                    let maxSettleUs = isRichSlowEditor ? 650_000 : 160_000
                    let settleUs = min(maxSettleUs, max(35_000, diff.replaceCount * perCharUs))
                    usleep(useconds_t(settleUs))
                    let restoreSec = isRichSlowEditor
                        ? min(2.80, max(1.60, Double(diff.replaceCount) * 0.008 + 1.10))
                        : max(1.05, Double(diff.replaceCount) * 0.003 + 0.85)
                    ContextInjector.pasteViaClipboardPreservingSnapshot(
                        diff.replacementSuffix,
                        prePasteDelayUs: prePasteUs,
                        restoreDelaySeconds: restoreSec
                    )
                    ContextInjector.appendInjectionTrace("finalize app=\(ctx.bundleID) branch=shiftLeftFallback(\(probe.reason)) emitted=\(alreadyEmitted.count) boxLen=\(boxLen) common=\(diff.commonPrefixCount) replace=\(diff.replaceCount) suffix=\(diff.replacementSuffix.count) settleMs=\(settleUs / 1000) restoreMs=\(Int(restoreSec * 1000))")
                }
            } else {
                ContextInjector.selectLeftCharacters(count: diff.replaceCount, slowRichEditor: isRichSlowEditor)
                // Give rich-text editors (e.g. WeChat Qt compose box) ample time to drain queued Shift+Left events before Cmd+V,
                // AND keep the clipboard populated long enough so restore NEVER races ahead of delayed Cmd+V execution!
                let perCharUs = isRichSlowEditor ? 3_500 : 700
                let maxSettleUs = isRichSlowEditor ? 650_000 : 160_000
                let settleUs = min(maxSettleUs, max(35_000, diff.replaceCount * perCharUs))
                usleep(useconds_t(settleUs))
                let restoreSec = isRichSlowEditor
                    ? min(2.80, max(1.60, Double(diff.replaceCount) * 0.008 + 1.10))
                    : max(1.05, Double(diff.replaceCount) * 0.003 + 0.85)
                ContextInjector.pasteViaClipboardPreservingSnapshot(
                    diff.replacementSuffix,
                    prePasteDelayUs: prePasteUs,
                    restoreDelaySeconds: restoreSec
                )
                ContextInjector.appendInjectionTrace("finalize app=\(ctx.bundleID) branch=shiftLeft emitted=\(alreadyEmitted.count) boxLen=\(boxLen) common=\(diff.commonPrefixCount) replace=\(diff.replaceCount) suffix=\(diff.replacementSuffix.count) settleMs=\(settleUs / 1000) restoreMs=\(Int(restoreSec * 1000))")
            }
        }
        stateLock.lock()
        emittedText = finalText
        targetConfirmedText = finalText
        stateLock.unlock()
        return true
    }

    private static func stripTrailingPunctuation(_ s: String) -> String {
        var scalars = s.unicodeScalars
        while let last = scalars.last, unstableTrailingPunctuation.contains(last) {
            scalars.removeLast()
        }
        return String(scalars)
    }

    private static func computeLocalAgreement(
        prev: String,
        curr: String,
        fastFirstSyllable: Bool = false,
        flushTrailingChar: Bool = false
    ) -> String {
        let pChars = Array(prev)
        let cChars = Array(curr)
        guard !cChars.isEmpty else { return "" }

        // On breath micro-pause (>=180ms) or VAD segment seal, immediately release even the final trailing character!
        if flushTrailingChar {
            return curr
        }

        // First-Syllable Fast Icebreaker: on the very first words spoken (~140ms in),
        // emit leading characters immediately without waiting an extra ASR cycle!
        if fastFirstSyllable && cChars.count >= 2 {
            return String(cChars.dropLast(1))
        }

        var common = 0
        let limit = min(pChars.count, cChars.count)
        while common < limit && pChars[common] == cChars[common] {
            common += 1
        }

        // Anti-Clumping Syllable Progression:
        // If user is actively speaking (`cChars.count > pChars.count`) and SenseVoice merely flipped a homophone
        // 1–2 chars back (e.g. "的" -> "得"), do NOT stall and clump 4 chars on the next frame — advance smoothly up to `cChars.count - 1`!
        if cChars.count > pChars.count && cChars.count >= 3 {
            return String(cChars.dropLast(1))
        }

        if common < limit && cChars.count >= 4 && pChars.count >= 3 {
            let pTail = Self.alphanumericOnly(String(pChars.suffix(4))).suffix(2)
            let cBody = Self.alphanumericOnly(String(cChars.dropLast(1)))
            if !pTail.isEmpty && cBody.hasSuffix(pTail) {
                return String(cChars.dropLast(1))
            }
        }
        let safeLen = cChars.count > 2 ? min(common, max(0, cChars.count - 1)) : common
        guard safeLen > 0 else { return "" }
        return String(cChars[0..<safeLen])
    }

    /// Prevents mid-sentence punctuation/homophone revisions in earlier clauses from ever freezing the typewriter stream!
    /// Finds where `alreadyConfirmed` ends inside `newStable` using tail-anchor matching (ignoring punctuation shifts) and returns the newly spoken suffix.
    private static func extractNewContinuationSuffix(alreadyConfirmed: String, newStable: String) -> String? {
        guard !newStable.isEmpty else { return nil }
        if alreadyConfirmed.isEmpty { return newStable }

        // Fast path 1: exact prefix match
        if newStable.hasPrefix(alreadyConfirmed) {
            let diff = String(newStable.dropFirst(alreadyConfirmed.count))
            return diff.isEmpty ? nil : diff
        }

        // Fast path 2: Punctuation-insensitive character alignment!
        // SenseVoice frequently changes an earlier "，" to "。" or inserts/removes a comma two sentences ago as context grows.
        let confirmedCore = Self.alphanumericOnly(alreadyConfirmed)
        let newChars = Array(newStable)

        // Map each character index in `newStable` to how many non-punctuation core characters have been seen up to it
        var coreSeen = 0
        var coreMatchIndex: Int? = nil
        let targetCoreCount = confirmedCore.count
        guard targetCoreCount > 0 else { return nil }

        // First try exact 3-char tail anchor search near the end for supreme accuracy on slight word edits
        let anchorLen = min(3, confirmedCore.count)
        let tailAnchor = String(confirmedCore.suffix(anchorLen))

        var runningCore = ""
        var coreEndToRawIdx: [Int: Int] = [:]
        for (idx, ch) in newChars.enumerated() {
            if Self.isCoreChar(ch) {
                runningCore.append(ch)
                coreSeen += 1
                coreEndToRawIdx[coreSeen] = idx
            }
        }

        // Require `newStable` to actually have MORE spoken content than what we already confirmed
        guard coreSeen > targetCoreCount else { return nil }

        // Search for `tailAnchor` near `targetCoreCount` (+/- 4 chars tolerance) in `runningCore`
        let rChars = Array(runningCore)
        let aChars = Array(tailAnchor)
        let minEnd = max(aChars.count, targetCoreCount - 4)
        let maxEnd = min(rChars.count - 1, targetCoreCount + 4)

        if minEnd <= maxEnd {
            for candidateEnd in stride(from: maxEnd, through: minEnd, by: -1) {
                let slice = Array(rChars[(candidateEnd - aChars.count)..<candidateEnd])
                if slice == aChars, let rawIdx = coreEndToRawIdx[candidateEnd] {
                    coreMatchIndex = rawIdx
                    break
                }
            }
        }

        // Fallback: align directly by core spoken syllable count if even the anchor had a 1-char homophone flip
        if coreMatchIndex == nil, let fallbackRawIdx = coreEndToRawIdx[targetCoreCount] {
            coreMatchIndex = fallbackRawIdx
        }

        guard let cutIdx = coreMatchIndex, cutIdx + 1 < newChars.count else { return nil }
        let suffix = String(newChars[(cutIdx + 1)...])
        return suffix.isEmpty ? nil : suffix
    }

    private static func isCoreChar(_ c: Character) -> Bool {
        for scalar in c.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                return true
            }
        }
        return false
    }

    private static func alphanumericOnly(_ s: String) -> String {
        return String(s.filter { isCoreChar($0) })
    }
}

public enum ContextInjector {
    public static func isAccessibilityTrusted(promptIfNeeded: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: promptIfNeeded] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public static func isAllowedTarget(bundleID: String, appName: String) -> Bool {
        // Universal macOS dictation input: allow typing & pasting into all user-focused apps
        return true
    }

    private static func asAXElement(_ ref: CFTypeRef?) -> AXUIElement? {
        guard let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(ref, to: AXUIElement.self)
    }

    private static func asAXValue(_ ref: CFTypeRef?) -> AXValue? {
        guard let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        return unsafeBitCast(ref, to: AXValue.self)
    }

    /// Reads the live string value of the currently focused input box (works across Cocoa & Chromium/Electron)
    public static func readCurrentFocusedValue() -> String? {
        guard AXIsProcessTrusted(),
              let frontApp = NSWorkspace.shared.frontmostApplication,
              isAllowedTarget(bundleID: frontApp.bundleIdentifier ?? "", appName: frontApp.localizedName ?? "") else {
            return nil
        }
        let appElem = AXUIElementCreateApplication(frontApp.processIdentifier)
        AXUIElementSetMessagingTimeout(appElem, 0.035)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElem, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let elem = asAXElement(focusedRef) else {
            return nil
        }
        var valRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(elem, kAXValueAttribute as CFString, &valRef) == .success,
           let str = valRef as? String {
            return str
        }
        return nil
    }

    private static let manualAXLock = NSLock()
    private static var manualAXEnabledPIDs: Set<pid_t> = []

    /// Enables Chromium/Electron manual accessibility tree once per process so apps like Feishu,
    /// Cursor, Notion, and Chrome expose accurate text-input & caret AX geometry.
    private static func enableManualAccessibilityIfNeeded(appElem: AXUIElement, pid: pid_t) {
        manualAXLock.lock()
        let alreadyEnabled = manualAXEnabledPIDs.contains(pid)
        if !alreadyEnabled {
            if manualAXEnabledPIDs.count > 64 { manualAXEnabledPIDs.removeAll() }
            manualAXEnabledPIDs.insert(pid)
        }
        manualAXLock.unlock()
        if !alreadyEnabled {
            _ = AXUIElementSetAttributeValue(appElem, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
    }

    private static func axElementQuartzRect(_ elem: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(elem, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(elem, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let pVal = asAXValue(posRef),
              let sVal = asAXValue(sizeRef) else {
            return nil
        }
        var pt = CGPoint.zero
        var sz = CGSize.zero
        guard AXValueGetValue(pVal, .cgPoint, &pt),
              AXValueGetValue(sVal, .cgSize, &sz),
              sz.width > 1, sz.height > 1 else {
            return nil
        }
        return CGRect(origin: pt, size: sz)
    }

    /// Converts a Quartz screen rect (top-left origin) into a Cocoa origin for the floating pill,
    /// placing it directly beneath the anchor rect (or flipping cleanly above if near the Dock/bottom).
    private static func anchorPillCocoaOrigin(forQuartzRect qRect: CGRect, pillSize: CGSize, gap: CGFloat) -> CGPoint? {
        guard let primaryScreen = NSScreen.screens.first else { return nil }
        let primaryHeight = primaryScreen.frame.height
        let cocoaBottomY = primaryHeight - qRect.maxY
        let cocoaTopY = primaryHeight - qRect.minY
        let anchorCenter = CGPoint(x: qRect.midX, y: (cocoaBottomY + cocoaTopY) * 0.5)

        let activeScreen = NSScreen.screens.first(where: { $0.frame.contains(anchorCenter) }) ?? NSScreen.main ?? primaryScreen
        let vf = activeScreen.visibleFrame

        let rawX = qRect.midX - pillSize.width * 0.5
        let belowY = cocoaBottomY - pillSize.height - gap
        let aboveY = cocoaTopY + gap
        let preferredY = (belowY >= vf.minY + 12) ? belowY : aboveY

        let clampedX = max(vf.minX + 8, min(vf.maxX - pillSize.width - 8, rawX))
        let clampedY = max(vf.minY + 12, min(vf.maxY - pillSize.height - 12, preferredY))
        return CGPoint(x: clampedX, y: clampedY)
    }

    /// Computes a rock-steady bottom anchor for a focused window when Tier 1 (exact caret) & Tier 2 (input element)
    /// are unavailable (e.g. WeChat 4.0 Qt). Never chases the moving mouse cursor, and never flips to the window's top titlebar!
    /// - Places the pill directly beneath the window when room permits; if the window sits near the Dock/screen bottom,
    ///   clamps cleanly inside the bottom edge near the compose area instead of jumping to the top of the screen.
    public static func anchorWindowBottomCocoaOrigin(
        forWindowQuartzRect winQuartz: CGRect,
        pillSize: CGSize,
        primaryScreenHeight: CGFloat,
        visibleFrame vf: CGRect,
        horizontalRatio: CGFloat = 0.5,
        gap: CGFloat = 10
    ) -> CGPoint {
        let cocoaBottomY = primaryScreenHeight - winQuartz.maxY
        let anchorX = winQuartz.origin.x + winQuartz.width * horizontalRatio
        let rawX = anchorX - pillSize.width * 0.5

        let belowY = cocoaBottomY - pillSize.height - gap
        let preferredY: CGFloat
        if belowY >= vf.minY + 12 {
            preferredY = belowY
        } else {
            // Window bottom is flush with Dock/screen bottom: tuck neatly just above the bottom edge instead of flipping to top!
            preferredY = max(vf.minY + 14, cocoaBottomY + 14)
        }

        let clampedX = max(vf.minX + 8, min(vf.maxX - pillSize.width - 8, rawX))
        let clampedY = max(vf.minY + 12, min(vf.maxY - pillSize.height - 12, preferredY))
        return CGPoint(x: clampedX, y: clampedY)
    }

    /// Queries the active text caret or focused input box coordinates using a 3-tier anchor cascade:
    ///   Tier 1: Exact AX text caret bounds (`kAXBoundsForRange`)
    ///   Tier 2: Focused text-input element frame (`kAXPosition` + `kAXSize`) for Electron/Chromium apps (Feishu, Cursor, Chrome)
    ///   Tier 3: Steady focused-window bottom anchor (aligned under the compose box, never chasing the moving mouse cursor)
    public static func getFocusedCaretCocoaOrigin(pillSize: CGSize) -> CGPoint? {
        guard AXIsProcessTrusted(),
              let frontApp = NSWorkspace.shared.frontmostApplication,
              isAllowedTarget(bundleID: frontApp.bundleIdentifier ?? "", appName: frontApp.localizedName ?? "") else {
            return nil
        }

        let pid = frontApp.processIdentifier
        let bundleLower = (frontApp.bundleIdentifier ?? "").lowercased()
        let appNameLower = (frontApp.localizedName ?? "").lowercased()
        let appElem = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElem, 0.080)
        enableManualAccessibilityIfNeeded(appElem: appElem, pid: pid)

        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElem, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
           let elem = asAXElement(focusedRef) {
            AXUIElementSetMessagingTimeout(elem, 0.080)

            // Tier 1: Exact caret bounds
            var rangeRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(elem, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
               let rangeVal = rangeRef {
                var boundsRef: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(
                    elem,
                    kAXBoundsForRangeParameterizedAttribute as CFString,
                    rangeVal,
                    &boundsRef
                ) == .success, let bVal = asAXValue(boundsRef) {
                    var quartzRect = CGRect.zero
                    if AXValueGetValue(bVal, .cgRect, &quartzRect),
                       quartzRect.height >= 4, quartzRect.height <= 220,
                       (quartzRect.origin.x != 0 || quartzRect.origin.y != 0),
                       let origin = anchorPillCocoaOrigin(forQuartzRect: quartzRect, pillSize: pillSize, gap: 10) {
                        return origin
                    }
                }
            }

            // Tier 2: Focused input element box (ideal for Electron/Feishu/Chrome/Cursor compose boxes)
            if let elemRect = axElementQuartzRect(elem),
               elemRect.width >= 40, elemRect.height >= 16, elemRect.height <= 560,
               let origin = anchorPillCocoaOrigin(forQuartzRect: elemRect, pillSize: pillSize, gap: 8) {
                return origin
            }
        }

        // Tier 3: Steady focused-window bottom anchor (never drifts with mouse movement!)
        var winRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElem, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
           let winElem = asAXElement(winRef),
           let winQuartz = axElementQuartzRect(winElem),
           let primaryScreen = NSScreen.screens.first {
            let primaryHeight = primaryScreen.frame.height
            let winCocoaCenter = CGPoint(
                x: winQuartz.midX,
                y: primaryHeight - winQuartz.midY
            )
            let activeScreen = NSScreen.screens.first(where: { $0.frame.contains(winCocoaCenter) }) ?? NSScreen.main ?? primaryScreen
            let isWeChatSplitMain = (bundleLower.contains("wechat") || bundleLower.contains("xinwechat") || appNameLower.contains("微信"))
                && winQuartz.width >= 680
            // WeChat main window has left sidebar (~30-35% width) + right chat compose box (~65% width).
            let horizontalRatio: CGFloat = isWeChatSplitMain ? 0.64 : 0.50
            return anchorWindowBottomCocoaOrigin(
                forWindowQuartzRect: winQuartz,
                pillSize: pillSize,
                primaryScreenHeight: primaryHeight,
                visibleFrame: activeScreen.visibleFrame,
                horizontalRatio: horizontalRatio,
                gap: 10
            )
        }

        return nil
    }

    /// Captures frontmost app name, window title, and any highlighted text (for Selected-Text Rewrite mode).
    public static func captureCurrentContext() -> ActiveScreenContext {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let appName = frontApp?.localizedName ?? "Unknown"
        let bundleID = frontApp?.bundleIdentifier ?? ""

        guard isAllowedTarget(bundleID: bundleID, appName: appName),
              AXIsProcessTrusted(),
              let pid = frontApp?.processIdentifier else {
            return ActiveScreenContext(appName: appName, bundleID: bundleID, windowTitle: "", selectedText: "", precedingText: "", hasFocusedTextInput: false)
        }

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.035)

        var windowTitle = ""
        var focusedWindow: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
           let win = asAXElement(focusedWindow) {
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef) == .success,
               let titleStr = titleRef as? String {
                windowTitle = String(titleStr.prefix(100))
            }
        }

        var selectedText = ""
        var precedingText = ""
        var editableFocus = true
        if bundleID == "com.apple.finder" {
            editableFocus = false
        }

        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
           let elem = asAXElement(focusedRef) {
            var selectedRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(elem, kAXSelectedTextAttribute as CFString, &selectedRef) == .success,
               let selStr = selectedRef as? String {
                selectedText = String(selStr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1200))
            }
            var valRef: CFTypeRef?
            if selectedText.isEmpty,
               AXUIElementCopyAttributeValue(elem, kAXValueAttribute as CFString, &valRef) == .success,
               let fullVal = valRef as? String,
               !fullVal.isEmpty {
                precedingText = String(fullVal.suffix(140))
            }
            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(elem, kAXRoleAttribute as CFString, &roleRef) == .success,
               let role = roleRef as? String {
                // Only treat genuinely non-editable controls/desktop as non-input;
                // Qt / Electron / Canvas apps often report AXWindow/AXApplication even when the compose cursor is active.
                let nonEditableRoles: Set<String> = ["AXDesktop", "AXButton", "AXImage", "AXToolbar"]
                if nonEditableRoles.contains(role) {
                    editableFocus = false
                } else {
                    editableFocus = true
                }
            }
        }

        return ActiveScreenContext(
            appName: appName,
            bundleID: bundleID,
            windowTitle: windowTitle,
            selectedText: selectedText,
            precedingText: precedingText,
            hasFocusedTextInput: editableFocus
        )
    }

    public static func isLikelyEditableFocusNow() -> Bool {
        return captureCurrentContext().hasFocusedTextInput
    }

    public static func saveToSafetyClipboard(_ text: String) {
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: - Zero-Modifier Unicode Streaming Delta (Works in Electron/Antigravity/Chrome/Cocoa)

    public static func applyCleanUnicodeDelta(from oldText: String, to newText: String) {
        guard AXIsProcessTrusted(), oldText != newText else { return }

        let oldChars = Array(oldText)
        let newChars = Array(newText)

        var commonLen = 0
        let minLen = min(oldChars.count, newChars.count)
        while commonLen < minLen && oldChars[commonLen] == newChars[commonLen] {
            commonLen += 1
        }

        let backspaceCount = oldChars.count - commonLen
        if backspaceCount > 0 {
            sendCleanBackspaces(count: backspaceCount)
        }

        if commonLen < newChars.count {
            let suffix = String(newChars[commonLen...])
            typeCleanUnicode(suffix)
        }
    }

    private static func stampAndPost(_ down: CGEvent, _ up: CGEvent, flags: CGEventFlags) {
        down.flags = flags
        up.flags = flags
        down.setIntegerValueField(.eventSourceUserData, value: HotkeyMonitor.syntheticEventMarker)
        up.setIntegerValueField(.eventSourceUserData, value: HotkeyMonitor.syntheticEventMarker)
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    /// Explicitly sets `CGEventFlags(rawValue: 0)` to wipe `.maskSecondaryFn`, `.maskAlternate`, and `.maskCommand`
    /// so held Fn/Option keys NEVER turn Backspace into Forward-Delete or Word-Delete!
    public static func sendCleanBackspaces(count: Int) {
        guard count > 0, AXIsProcessTrusted() else { return }
        let source = CGEventSource(stateID: .privateState)
        let deleteKey = CGKeyCode(kVK_Delete)
        for i in 0..<count {
            if let down = CGEvent(keyboardEventSource: source, virtualKey: deleteKey, keyDown: true),
               let up = CGEvent(keyboardEventSource: source, virtualKey: deleteKey, keyDown: false) {
                stampAndPost(down, up, flags: CGEventFlags(rawValue: 0))
            }
            // Prevent macOS CGEventTap ring-buffer overflow when backspacing long >20 char clauses
            if i > 0 && i % 14 == 0 {
                usleep(1_200)
            }
        }
    }

    /// Instant Cmd+A selection for zero-flicker atomic morph when input box contains only the streamed draft.
    public static func sendSelectAllEvent() {
        guard AXIsProcessTrusted() else { return }
        let source = CGEventSource(stateID: .privateState)
        let aKey = CGKeyCode(kVK_ANSI_A)
        if let down = CGEvent(keyboardEventSource: source, virtualKey: aKey, keyDown: true),
           let up = CGEvent(keyboardEventSource: source, virtualKey: aKey, keyDown: false) {
            stampAndPost(down, up, flags: .maskCommand)
        }
    }

    public static func sendCopyEvent() {
        guard AXIsProcessTrusted() else { return }
        let source = CGEventSource(stateID: .privateState)
        let cKey = CGKeyCode(kVK_ANSI_C)
        if let down = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: true),
           let up = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: false) {
            stampAndPost(down, up, flags: .maskCommand)
        }
    }

    public static func sendRightArrowEvent() {
        guard AXIsProcessTrusted() else { return }
        let source = CGEventSource(stateID: .privateState)
        let rightArrow = CGKeyCode(kVK_RightArrow)
        if let down = CGEvent(keyboardEventSource: source, virtualKey: rightArrow, keyDown: true),
           let up = CGEvent(keyboardEventSource: source, virtualKey: rightArrow, keyDown: false) {
            stampAndPost(down, up, flags: CGEventFlags(rawValue: 0))
        }
    }

    /// Returns `true` if a copied compose box contains embedded images, files, or proprietary non-text attachments
    /// that must NOT be flattened by a plain-text `Cmd+A -> Cmd+V` swap.
    public static func pasteboardContainsNonTextRichObject(typeNames: [String]) -> Bool {
        for raw in typeNames {
            let lower = raw.lowercased()
            if lower.contains("tiff")
                || lower.contains("png")
                || lower.contains("jpeg")
                || lower.contains("jpg")
                || lower.contains("gif")
                || lower.contains("webp")
                || lower.contains("heic")
                || lower.contains("image")
                || lower.contains("file-url")
                || lower.contains("filenames")
                || lower.contains("rtfd")
                || lower.contains("pdf")
                || lower.contains("attachment") {
                return true
            }
        }
        return false
    }

    /// Attempts zero-keystroke, sub-millisecond selection of the trailing `count` characters via macOS Accessibility API.
    /// Reads back `kAXSelectedTextRangeAttribute` to confirm the target editor actually honored the range update.
    public static func trySelectTrailingCharactersViaAX(count: Int) -> Bool {
        guard count > 0,
              AXIsProcessTrusted(),
              let frontApp = NSWorkspace.shared.frontmostApplication,
              isAllowedTarget(bundleID: frontApp.bundleIdentifier ?? "", appName: frontApp.localizedName ?? "") else {
            return false
        }
        let appElem = AXUIElementCreateApplication(frontApp.processIdentifier)
        AXUIElementSetMessagingTimeout(appElem, 0.040)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElem, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let elem = asAXElement(focusedRef) else {
            return false
        }
        AXUIElementSetMessagingTimeout(elem, 0.040)

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(elem, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rVal = asAXValue(rangeRef) else {
            return false
        }
        var currentRange = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rVal, .cfRange, &currentRange),
              currentRange.length == 0,
              currentRange.location >= count else {
            return false
        }

        var valRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(elem, kAXValueAttribute as CFString, &valRef) == .success,
              let fullText = valRef as? String,
              !fullText.isEmpty else {
            return false
        }
        let nsFull = fullText as NSString
        guard currentRange.location <= nsFull.length else { return false }
        let prefixBeforeCaret = nsFull.substring(to: currentRange.location)
        guard prefixBeforeCaret.count >= count else { return false }
        let tailSlice = String(prefixBeforeCaret.suffix(count))
        let utf16Len = (tailSlice as NSString).length
        guard currentRange.location >= utf16Len else { return false }

        var targetRange = CFRange(location: currentRange.location - utf16Len, length: utf16Len)
        guard let newRangeVal = AXValueCreate(.cfRange, &targetRange) else { return false }
        guard AXUIElementSetAttributeValue(elem, kAXSelectedTextRangeAttribute as CFString, newRangeVal) == .success else {
            return false
        }

        var verifyRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(elem, kAXSelectedTextRangeAttribute as CFString, &verifyRef) == .success,
           let vVal = asAXValue(verifyRef) {
            var verifiedRange = CFRange(location: 0, length: 0)
            if AXValueGetValue(vVal, .cfRange, &verifiedRange),
               verifiedRange.location == targetRange.location,
               verifiedRange.length == targetRange.length {
                return true
            }
        }
        return false
    }

    /// Highlights the streamed draft via Shift+Left Arrow so Cmd+V replaces it in one atomic frame without backspace flicker.
    public static func selectLeftCharacters(count: Int, slowRichEditor: Bool = false) {
        guard count > 0, AXIsProcessTrusted() else { return }
        let source = CGEventSource(stateID: .privateState)
        let leftArrow = CGKeyCode(kVK_LeftArrow)
        let batchSize = slowRichEditor ? 10 : 14
        let batchPauseUs: useconds_t = slowRichEditor ? 2_200 : 1_200
        for i in 0..<count {
            if let down = CGEvent(keyboardEventSource: source, virtualKey: leftArrow, keyDown: true),
               let up = CGEvent(keyboardEventSource: source, virtualKey: leftArrow, keyDown: false) {
                stampAndPost(down, up, flags: .maskShift)
            }
            // Prevent macOS CGEventTap ring-buffer overflow & dropped selections on long drafts in WeChat/Electron.
            if i > 0 && i % batchSize == 0 {
                usleep(batchPauseUs)
            }
        }
    }

    /// Detects whether `Shift+Return` caused a Markdown-aware editor (Antigravity, Notion, Feishu, Obsidian)
    /// to auto-insert the next list prefix (`2. `, `3. `, `- `), and skips typing the duplicate prefix if already present!
    public static func typePostNewlineSkippingEditorAutoMarker(_ bufferedLineStart: String) {
        guard !bufferedLineStart.isEmpty, AXIsProcessTrusted() else { return }

        if let marker = extractLeadingListMarker(bufferedLineStart) {
            usleep(10_000)
            if let liveBox = readCurrentFocusedValue() {
                let trimmedMarker = marker.trimmingCharacters(in: .whitespaces)
                if liveBox.hasSuffix("\n" + marker) || liveBox.hasSuffix("\n" + trimmedMarker + " ") {
                    let remainder = String(bufferedLineStart.dropFirst(marker.count))
                    if !remainder.isEmpty {
                        typeCleanUnicode(remainder)
                    }
                    return
                }
            }
        }
        typeCleanUnicode(bufferedLineStart)
    }

    public static func extractLeadingListMarker(_ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"^(\d+\.\s+|[-*•]\s+)"#) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: nsRange),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    public static func containsDuplicatedListMarker(in actualBox: String, expected: String) -> Bool {
        guard actualBox != expected else { return false }
        guard let regex = try? NSRegularExpression(pattern: #"(?m)^[ \t]*(\d+\.|[-*•])\s+\1\s+"#) else { return false }
        let range = NSRange(actualBox.startIndex..<actualBox.endIndex, in: actualBox)
        let expectedRange = NSRange(expected.startIndex..<expected.endIndex, in: expected)
        return regex.firstMatch(in: actualBox, range: range) != nil && regex.firstMatch(in: expected, range: expectedRange) == nil
    }

    public static func collapseDuplicatedListMarkers(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(?m)^([ \t]*)(\d+\.|[-*•])\s+\2\s+"#) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "$1$2 ")
    }

    public static func typeCleanUnicode(_ text: String) {
        guard !text.isEmpty, AXIsProcessTrusted() else { return }
        let lines = text.components(separatedBy: "\n")
        for (lineIdx, line) in lines.enumerated() {
            if !line.isEmpty {
                if lineIdx > 0 {
                    typePostNewlineSkippingEditorAutoMarker(line)
                } else {
                    typeRawUnicodeLine(line)
                }
            }
            if lineIdx < lines.count - 1 {
                sendSoftNewlineShiftReturn()
            }
        }
    }

    fileprivate static func sendSoftNewlineShiftReturn() {
        guard AXIsProcessTrusted() else { return }
        let source = CGEventSource(stateID: .privateState)
        let returnKey = CGKeyCode(kVK_Return)
        if let down = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: true),
           let up = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: false) {
            stampAndPost(down, up, flags: .maskShift)
        }
    }

    private static func typeRawUnicodeLine(_ text: String) {
        guard !text.isEmpty, AXIsProcessTrusted() else { return }
        let source = CGEventSource(stateID: .privateState)
        let utf16Units = Array(text.utf16)
        let chunkSize = 12

        var idx = 0
        while idx < utf16Units.count {
            let end = min(idx + chunkSize, utf16Units.count)
            var slice = Array(utf16Units[idx..<end])
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
               let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                down.keyboardSetUnicodeString(stringLength: slice.count, unicodeString: &slice)
                up.keyboardSetUnicodeString(stringLength: slice.count, unicodeString: &slice)
                stampAndPost(down, up, flags: CGEventFlags(rawValue: 0))
            }
            idx = end
        }
    }

    private static func snapshotPasteboard(_ pasteboard: NSPasteboard, maxBytes: Int = 8 * 1024 * 1024) -> [[NSPasteboard.PasteboardType: Data]] {
        var totalSavedBytes = 0
        var savedItems: [[NSPasteboard.PasteboardType: Data]] = []
        for item in (pasteboard.pasteboardItems ?? []) {
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    if totalSavedBytes + data.count <= maxBytes {
                        dict[type] = data
                        totalSavedBytes += data.count
                    }
                }
            }
            if !dict.isEmpty {
                savedItems.append(dict)
            }
        }
        return savedItems
    }

    private static func restorePasteboard(_ pasteboard: NSPasteboard, items: [[NSPasteboard.PasteboardType: Data]]) {
        guard !items.isEmpty else { return }
        pasteboard.clearContents()
        let restored: [NSPasteboardItem] = items.map { dict in
            let pbItem = NSPasteboardItem()
            for (type, data) in dict {
                pbItem.setData(data, forType: type)
            }
            return pbItem
        }
        pasteboard.writeObjects(restored)
    }

    /// Zero-rewind atomic replacement for rich editors (like WeChat 4.0 Qt) that hide `kAXValueAttribute`:
    /// 1. Snapshots user's original clipboard.
    /// 2. Sends `Cmd+A` (1 instant key, zero backwards selection animation) + `Cmd+C` and polls `changeCount` up to 220ms.
    /// 3. Verifies no images/files/attachments exist and merges `finalText` safely (preserving any earlier user-typed prefix).
    /// 4. Writes merged text, waits `prePasteDelayUs`, sends `Cmd+V` while the full box is already selected (1-frame swap!).
    /// 5. Restores the original clipboard after `restoreDelaySeconds` only if `changeCount` hasn't moved.
    public static func tryAtomicSelectAllCopyReplace(
        alreadyEmitted: String,
        finalText: String,
        prePasteDelayUs: useconds_t = 55_000,
        restoreDelaySeconds: TimeInterval = 1.50
    ) -> (succeeded: Bool, reason: String) {
        guard !finalText.isEmpty, AXIsProcessTrusted() else {
            return (false, "untrusted")
        }
        if let front = NSWorkspace.shared.frontmostApplication,
           !isAllowedTarget(bundleID: front.bundleIdentifier ?? "", appName: front.localizedName ?? "") {
            return (false, "blockedApp")
        }

        let pasteboard = NSPasteboard.general
        let savedItems = snapshotPasteboard(pasteboard)
        let preCopyCC = pasteboard.changeCount

        sendSelectAllEvent()
        usleep(35_000)
        sendCopyEvent()

        // Poll pasteboard changeCount (typically completes in 15–45ms in WeChat Qt, max 220ms).
        var copyCompleted = false
        for _ in 0..<28 {
            usleep(8_000)
            if pasteboard.changeCount != preCopyCC {
                copyCompleted = true
                break
            }
        }

        guard copyCompleted else {
            sendRightArrowEvent()
            usleep(18_000)
            return (false, "copyTimeout")
        }

        let copiedTypes: [String] = (pasteboard.pasteboardItems ?? []).flatMap { $0.types.map(\.rawValue) }
        if pasteboardContainsNonTextRichObject(typeNames: copiedTypes) {
            sendRightArrowEvent()
            restorePasteboard(pasteboard, items: savedItems)
            usleep(18_000)
            return (false, "richMediaGuard")
        }

        guard let copiedText = pasteboard.string(forType: .string),
              let merged = LiveInputSession.buildMergedBoxReplacement(
                boxText: copiedText,
                alreadyEmitted: alreadyEmitted,
                finalText: finalText
              ) else {
            sendRightArrowEvent()
            restorePasteboard(pasteboard, items: savedItems)
            usleep(18_000)
            return (false, "noMatch")
        }

        pasteboard.clearContents()
        if !pasteboard.setString(merged, forType: .string) {
            _ = pasteboard.writeObjects([merged as NSString])
        }
        let writtenChangeCount = pasteboard.changeCount

        if prePasteDelayUs > 0 {
            usleep(prePasteDelayUs)
        }

        let source = CGEventSource(stateID: .privateState)
        let vKeyCode = CGKeyCode(kVK_ANSI_V)
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
           let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) {
            stampAndPost(keyDown, keyUp, flags: .maskCommand)
        }

        let safeRestoreDelay = max(1.35, restoreDelaySeconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + safeRestoreDelay) {
            guard !savedItems.isEmpty else { return }
            guard pasteboard.changeCount == writtenChangeCount else {
                appendInjectionTrace("cmdACopyRestore skipped=changeCountMoved expected=\(writtenChangeCount) actual=\(pasteboard.changeCount)")
                return
            }
            restorePasteboard(pasteboard, items: savedItems)
        }

        return (true, merged == finalText ? "exactFull" : "mergedPrefix")
    }

    /// Universal 100% reliable clipboard paste with snapshot restoration (works in WeChat Qt, Electron, Web, and native editors).
    /// - Waits `prePasteDelayUs` after setting `NSPasteboard` so macOS `pboard` and Qt `QCocoaClipboard` see the new `changeCount` before `Cmd+V`.
    /// - Waits `restoreDelaySeconds` (default >= 1.0s) and verifies `changeCount` hasn't moved before restoring the user's previous clipboard,
    ///   eliminating the race where slow rich-text editors (WeChat) paste the restored old clipboard instead of the dictated text!
    public static func pasteViaClipboardPreservingSnapshot(
        _ text: String,
        prePasteDelayUs: useconds_t = 35_000,
        restoreDelaySeconds: TimeInterval = 1.00
    ) {
        guard !text.isEmpty, AXIsProcessTrusted() else { return }
        if let front = NSWorkspace.shared.frontmostApplication,
           !isAllowedTarget(bundleID: front.bundleIdentifier ?? "", appName: front.localizedName ?? "") {
            return
        }

        let pasteboard = NSPasteboard.general
        let savedItems = snapshotPasteboard(pasteboard)

        pasteboard.clearContents()
        if !pasteboard.setString(text, forType: .string) {
            _ = pasteboard.writeObjects([text as NSString])
        }
        let writtenChangeCount = pasteboard.changeCount

        if prePasteDelayUs > 0 {
            usleep(prePasteDelayUs)
        }

        let source = CGEventSource(stateID: .privateState)
        let vKeyCode = CGKeyCode(kVK_ANSI_V)
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
           let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) {
            stampAndPost(keyDown, keyUp, flags: .maskCommand)
        }

        let safeRestoreDelay = max(0.85, restoreDelaySeconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + safeRestoreDelay) {
            guard !savedItems.isEmpty else { return }
            guard pasteboard.changeCount == writtenChangeCount else {
                appendInjectionTrace("pasteRestore skipped=changeCountMoved expected=\(writtenChangeCount) actual=\(pasteboard.changeCount)")
                return
            }
            restorePasteboard(pasteboard, items: savedItems)
        }
    }

    public static func injectTextAtCursor(_ text: String, in context: ActiveScreenContext? = nil) {
        let isRichSlow = context?.prefersAtomicPolishReplacement ?? false
        pasteViaClipboardPreservingSnapshot(
            text,
            prePasteDelayUs: isRichSlow ? 55_000 : 35_000,
            restoreDelaySeconds: isRichSlow ? 1.50 : 1.00
        )
    }

    private static let traceLock = NSLock()

    /// Non-sensitive structural trace (lengths, branch names, and pasteboard changeCount only — NEVER logs user text).
    public static func appendInjectionTrace(_ line: String) {
        traceLock.lock()
        defer { traceLock.unlock() }
        let dir = AppBrand.applicationSupportDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let logURL = dir.appendingPathComponent("injection-trace.log")
        let entry = "\(Int(Date().timeIntervalSince1970)) \(line)\n"
        guard let data = entry.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logURL.path),
           let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
           let size = attrs[.size] as? UInt64,
           size > 65_536 {
            try? data.write(to: logURL, options: .atomic)
            return
        }
        if let fh = try? FileHandle(forWritingTo: logURL) {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
    }
}
