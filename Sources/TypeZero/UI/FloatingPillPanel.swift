import SwiftUI
import AppKit

/// Zero-overhead real-time audio envelope bus:
/// Decouples 90Hz microphone buffer callbacks from SwiftUI's root `AppState.objectWillChange`,
/// eliminating 90x/sec full-app view hierarchy diffs while giving `TimelineView` silky 60/120fps smoothed amplitude!
public final class AudioLevelBus: @unchecked Sendable {
    public static let shared = AudioLevelBus()

    private let lock = NSLock()
    private var rawTarget: Float = 0.06
    private var displayEnvelope: Float = 0.06
    private var targetSymbolCount: Int = 0
    private var displaySymbolProgress: Double = 0.0

    private init() {}

    public func push(_ level: Float) {
        lock.lock()
        rawTarget = max(0.05, min(1.0, level))
        lock.unlock()
    }

    public func pushRecognizedCount(_ count: Int) {
        lock.lock()
        targetSymbolCount = max(0, count)
        lock.unlock()
    }

    public func reset() {
        lock.lock()
        rawTarget = 0.05
        displayEnvelope = 0.05
        targetSymbolCount = 0
        displaySymbolProgress = 0.0
        lock.unlock()
    }

    /// Fast-attack, smooth-release ballistic envelope read on each animation frame (~0.0005ms, zero SwiftUI diff!).
    public func sampleBallisticEnvelope() -> Float {
        lock.lock()
        defer { lock.unlock() }
        let coeff: Float = rawTarget > displayEnvelope ? 0.38 : 0.14
        displayEnvelope += (rawTarget - displayEnvelope) * coeff
        return displayEnvelope
    }

    /// Smoothly steps the recognized character counter 1-by-1 at 60/120fps so micro-symbols glide out fluidly!
    public func sampleRecognizedSymbolProgress() -> (smoothProgress: Double, exactTarget: Int) {
        lock.lock()
        defer { lock.unlock() }
        let targetD = Double(targetSymbolCount)
        if targetD > displaySymbolProgress {
            let delta = targetD - displaySymbolProgress
            let step = max(0.32, delta * 0.24)
            displaySymbolProgress = min(targetD, displaySymbolProgress + step)
        } else if targetD < displaySymbolProgress {
            displaySymbolProgress += (targetD - displaySymbolProgress) * 0.30
        }
        return (displaySymbolProgress, targetSymbolCount)
    }
}

/// Geometry of the floating pill window. The panel has a fixed size and the SwiftUI pill is centred inside it, so
/// everything drawn in an error state has to fit these numbers.
enum FloatingPillLayout {
    /// Fixed size of the pill's `NSPanel`, in points.
    static let panelSize = CGSize(width: 224, height: 58)

    // Error pill: orange triangle plus the reason, wrapped to at most `errorMaxLines` lines.
    /// Widest the error capsule may get; the panel width minus a 4 pt margin on each side.
    static let errorMaxWidth: CGFloat = 216
    static let errorFontSize: CGFloat = 10.5
    static let errorMaxLines = 2
    static let errorIconSize: CGFloat = 12
    static let errorIconSpacing: CGFloat = 6
    static let errorHorizontalPadding: CGFloat = 13
    static let errorVerticalPadding: CGFloat = 7
    /// Shortest the error capsule gets (a single line of text or the icon alone), as in the old icon-only pill.
    static let errorMinHeight: CGFloat = 28

    /// Height of a full error pill (`errorMaxLines` lines of text), with the font's line height taken as 1.25 x its size.
    static var errorMaxHeightEstimate: CGFloat {
        CGFloat(errorMaxLines) * (errorFontSize * 1.25) + 2 * errorVerticalPadding
    }
}

/// Ultra-minimalist, zero-text floating acoustic micro-pill:
/// - Strictly NEVER displays live transcribed text (text streams exclusively inside the user's selected input box!).
/// - Decouples Accessibility IPC caret queries onto a background serial queue (zero main-thread stalls!).
/// - Glides at 60fps in pure memory and renders a 60/120fps continuous fluid sine-wave visualization.
public final class FloatingPillController: @unchecked Sendable {
    private var panel: NSPanel?
    private weak var boundAppState: AppState?
    private var lerpTimer: DispatchSourceTimer?
    private var axPollTimer: DispatchSourceTimer?
    private let axPollQueue = DispatchQueue(label: "io.github.typezero.pill.axcaret", qos: .utility)

    private let coordLock = NSLock()
    private var cachedTargetOrigin: CGPoint? = nil
    private var currentOrigin: CGPoint = .zero
    private var isRequestedVisible: Bool = false
    private let pillSize = FloatingPillLayout.panelSize

    public init() {}

    @MainActor
    public func attach(appState: AppState) {
        self.boundAppState = appState
        // Pre-warm panel offscreen so first Fn press shows in 0ms without NSHostingView creation hitch!
        ensurePanelCreated()
    }

    @MainActor
    private func ensurePanelCreated() {
        guard panel == nil, let appState = boundAppState else { return }

        let contentView = FloatingPillView(appState: appState)
        let hosting = NSHostingView(rootView: contentView)

        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: pillSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.contentView = hosting

        self.panel = p
    }

    @MainActor
    public func setVisible(_ visible: Bool) {
        isRequestedVisible = visible
        if visible {
            ensurePanelCreated()
            guard let panel else { return }

            if !panel.isVisible {
                let sizeSnapshot = pillSize
                // Resolve initial anchor off-main-thread so the pill spawns right beneath the input box
                // without flashing at the bottom Dock first (bounded by a 60ms fast-path fallback).
                var hasShown = false
                let presentAt: @MainActor (CGPoint) -> Void = { [weak self] pos in
                    guard let self, self.isRequestedVisible, !hasShown, let panel = self.panel else { return }
                    hasShown = true
                    self.currentOrigin = pos
                    panel.alphaValue = 0.0
                    panel.setFrame(NSRect(origin: pos, size: sizeSnapshot), display: true)
                    panel.orderFrontRegardless()
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.10
                        panel.animator().alphaValue = 1.0
                    }
                    self.startDualLayerCaretTracking()
                }

                axPollQueue.async { [weak self] in
                    let resolved = ContextInjector.getFocusedCaretCocoaOrigin(pillSize: sizeSnapshot)
                    if let resolved, let self {
                        self.coordLock.lock()
                        self.cachedTargetOrigin = resolved
                        self.coordLock.unlock()
                    }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            let target = resolved ?? self?.defaultBottomOrigin() ?? .zero
                            presentAt(target)
                        }
                    }
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(65)) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        presentAt(self.defaultBottomOrigin())
                    }
                }
            }
        } else {
            stopDualLayerCaretTracking()
            AudioLevelBus.shared.reset()
            coordLock.lock()
            cachedTargetOrigin = nil
            coordLock.unlock()
            panel?.orderOut(nil)
        }
    }

    @MainActor
    private func startDualLayerCaretTracking() {
        stopDualLayerCaretTracking()
        let sizeSnapshot = pillSize

        // Layer 1 (Background Queue, 7Hz): Off-main-thread AX caret query with 35ms IPC timeout — NEVER blocks UI or typewriter!
        let poll = DispatchSource.makeTimerSource(queue: axPollQueue)
        poll.schedule(deadline: .now(), repeating: .milliseconds(140), leeway: .milliseconds(15))
        poll.setEventHandler { [weak self] in
            guard let self else { return }
            if let caret = ContextInjector.getFocusedCaretCocoaOrigin(pillSize: sizeSnapshot) {
                self.coordLock.lock()
                self.cachedTargetOrigin = caret
                self.coordLock.unlock()
            }
        }
        self.axPollTimer = poll
        poll.resume()

        // Layer 2 (Main Queue, 60fps): Pure in-memory float Lerp (~0.001ms per tick) — magnetic glide!
        let lerp = DispatchSource.makeTimerSource(queue: .main)
        lerp.schedule(deadline: .now() + .milliseconds(16), repeating: .milliseconds(16), leeway: .milliseconds(2))
        lerp.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.stepPureMemoryLerp()
            }
        }
        self.lerpTimer = lerp
        lerp.resume()
    }

    @MainActor
    private func stopDualLayerCaretTracking() {
        axPollTimer?.cancel()
        axPollTimer = nil
        lerpTimer?.cancel()
        lerpTimer = nil
    }

    @MainActor
    private func stepPureMemoryLerp() {
        guard let panel, panel.isVisible else { return }
        coordLock.lock()
        let targetOpt = cachedTargetOrigin
        coordLock.unlock()

        let target = targetOpt ?? defaultBottomOrigin()
        let dx = target.x - currentOrigin.x
        let dy = target.y - currentOrigin.y
        let dist = hypot(dx, dy)
        guard dist > 0.5 else { return }

        // Snap immediately if jumping across screen on initial caret discovery; glide smoothly while typing
        if dist > 260 {
            currentOrigin = target
        } else {
            let factor: CGFloat = 0.20
            currentOrigin.x += dx * factor
            currentOrigin.y += dy * factor
        }
        panel.setFrameOrigin(currentOrigin)
    }

    @MainActor
    private func defaultBottomOrigin() -> CGPoint {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return .zero }
        let vf = screen.visibleFrame
        return CGPoint(x: vf.midX - pillSize.width * 0.5, y: vf.minY + 22)
    }
}

/// Pure acoustic wave micro-capsule — ZERO live text duplication, ZERO per-frame SwiftUI state invalidations!
struct FloatingPillView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Group {
            switch appState.phase {
            case .idle:
                EmptyView()

            case .listening(_, let mode):
                let accentColor = mode == .rewriteSelection
                    ? Color(red: 0.56, green: 0.24, blue: 0.88)
                    : TZTheme.blue

                if appState.llmConfig.enableLiveInlineTyping || mode == .rewriteSelection {
                    HStack(spacing: 9) {
                        NevertypeMarkView(size: 16)
                        FluidSineWaveView(accent: accentColor)
                            .frame(width: 62, height: 16)
                    }
                    .padding(.horizontal, 13)
                    .frame(height: 31)
                    .background(.ultraThinMaterial)
                    .background(Color(red: 0.980, green: 0.980, blue: 0.984).opacity(0.94))
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(Color(red: 0.09, green: 0.086, blue: 0.106).opacity(0.10), lineWidth: 0.8))
                } else {
                    // Default Fast-Paste Mode: rhythmic micro-symbols reading live character count ABOVE the sound wave!
                    VStack(spacing: 4) {
                        MicroSymbolStreamView(accent: accentColor)
                        HStack(spacing: 8) {
                            NevertypeMarkView(size: 14)
                            FluidSineWaveView(accent: accentColor)
                                .frame(width: 86, height: 14)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6.5)
                    .background(.ultraThinMaterial)
                    .background(Color(red: 0.980, green: 0.980, blue: 0.984).opacity(0.95))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color(red: 0.09, green: 0.086, blue: 0.106).opacity(0.10), lineWidth: 0.8)
                    )
                }

            case .polishing:
                FloatingPillThinkingView()

            case .completed:
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(red: 0.12, green: 0.72, blue: 0.42))
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Color.white.opacity(0.95))
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Color.black.opacity(0.06), lineWidth: 0.8))

            case .savedToClipboard(let msg):
                HStack(spacing: 5) {
                    Image(systemName: "doc.on.clipboard.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(red: 0.10, green: 0.42, blue: 1.0))
                    Text(msg)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(red: 0.10, green: 0.10, blue: 0.14))
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Color.white.opacity(0.96))
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Color(red: 0.10, green: 0.42, blue: 1.0).opacity(0.3), lineWidth: 0.8))

            case .error(let message):
                FloatingPillErrorView(message: message)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Capsule shown while the transcript is cleaned up (and while a cloud engine transcribes): logo, "Thinking", animated dots.
/// About 125 pt wide and 30 pt tall, centred in the 224 x 58 pt panel.
struct FloatingPillThinkingView: View {
    /// Pass an empty label for the logo-and-dots-only capsule (the self-tests use it to measure what the word adds).
    var label: String = "Thinking"

    var body: some View {
        HStack(spacing: 8) {
            NevertypeMarkView(size: 15)
            if !label.isEmpty {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TZTheme.inkBody)
                    .lineLimit(1)
                    .fixedSize()
            }
            ShimmerDotsView()
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(.ultraThinMaterial)
        .background(Color(red: 0.980, green: 0.980, blue: 0.984).opacity(0.95))
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(TZTheme.blue.opacity(0.22), lineWidth: 0.8))
    }
}

/// Error capsule: orange triangle plus the reason (for example "Allow microphone access in System Settings").
///
/// The text wraps to at most `FloatingPillLayout.errorMaxLines` lines and ends with an ellipsis beyond that. The panel
/// ignores mouse events (clicks must reach the app underneath), so this view is read-only.
struct FloatingPillErrorView: View {
    let message: String

    private var reason: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        HStack(spacing: FloatingPillLayout.errorIconSpacing) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: FloatingPillLayout.errorIconSize))
                .foregroundStyle(Color.orange)
            if !reason.isEmpty {
                Text(reason)
                    .font(.system(size: FloatingPillLayout.errorFontSize, weight: .semibold))
                    .foregroundStyle(Color(red: 0.10, green: 0.10, blue: 0.14))
                    .multilineTextAlignment(.leading)
                    .lineLimit(FloatingPillLayout.errorMaxLines)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, reason.isEmpty ? 10 : FloatingPillLayout.errorHorizontalPadding)
        .padding(.vertical, FloatingPillLayout.errorVerticalPadding)
        .frame(minHeight: FloatingPillLayout.errorMinHeight)
        .background(Color.white.opacity(0.96))
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Color.orange.opacity(0.4), lineWidth: 0.8))
        // Caps the width the capsule may use. The capsule itself still hugs its content inside this frame.
        .frame(maxWidth: FloatingPillLayout.errorMaxWidth)
    }
}

/// Smooth 3-dot wave indicator during sub-300ms polish transition (replaces clunky macOS NSProgressIndicator spinner).
struct ShimmerDotsView: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate * 7.5
            HStack(spacing: 3.5) {
                ForEach(0..<3, id: \.self) { idx in
                    let wave = (sin(t - Double(idx) * 0.85) + 1.0) * 0.5
                    Circle()
                        .fill(TZTheme.blue.opacity(0.35 + wave * 0.65))
                        .frame(width: 4.5, height: 4.5)
                        .offset(y: CGFloat((wave - 0.5) * -3.0))
                }
            }
        }
    }
}

/// Rhythmic micro-symbol cipher ribbon displayed ABOVE the acoustic sine wave when live inline typing is off:
/// Turns each recognized syllable into a delicate dancing symbol (`• · ✦ ▪`) + live character count without distracting draft text!
struct MicroSymbolStreamView: View {
    let accent: Color
    private static let glyphCycle: [String] = ["•", "·", "✦", "•", "▪", "·"]

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let (smoothProg, _) = AudioLevelBus.shared.sampleRecognizedSymbolProgress()
            let visibleTotal = Int(smoothProg.rounded(.down))
            let fractionalBirth = smoothProg - Double(visibleTotal)
            let maxWindow = 12
            let windowCount = min(maxWindow, visibleTotal)
            let startSerial = max(0, visibleTotal - maxWindow)

            HStack(spacing: 5) {
                if windowCount == 0 {
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { i in
                            let pulse = 0.22 + 0.20 * (sin(t * 4.2 - Double(i) * 0.9) + 1.0) * 0.5
                            Circle()
                                .fill(Color(red: 0.09, green: 0.086, blue: 0.106).opacity(pulse))
                                .frame(width: 3.2, height: 3.2)
                        }
                    }
                    .frame(height: 13)
                } else {
                    HStack(spacing: 3.2) {
                        ForEach(0..<windowCount, id: \.self) { slot in
                            let serial = startSerial + slot
                            let glyph = Self.glyphCycle[serial % Self.glyphCycle.count]
                            let isNewest = (slot == windowCount - 1)
                            let popScale: CGFloat = isNewest ? CGFloat(0.75 + 0.30 * sin(fractionalBirth * Double.pi)) : 1.0
                            let waveY = CGFloat(sin(t * 6.5 - Double(serial) * 0.65) * 1.1)
                            Text(glyph)
                                .font(.system(size: glyph == "✦" ? 8.5 : 10.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(isNewest ? accent : Color(red: 0.09, green: 0.086, blue: 0.106).opacity(0.68))
                                .scaleEffect(popScale)
                                .offset(y: waveY)
                        }
                    }
                    .frame(height: 13)

                    Text("\(visibleTotal)")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(accent.opacity(0.11))
                        .clipShape(Capsule())
                }
            }
        }
    }
}

/// 120Hz ProMotion fluid multi-ribbon sine wave reading directly from `AudioLevelBus` without SwiftUI state diffs!
struct FluidSineWaveView: View {
    let accent: Color

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let smoothLevel = AudioLevelBus.shared.sampleBallisticEnvelope()
            Canvas { ctx, size in
                let midY = size.height * 0.5
                let amp = max(1.5, CGFloat(smoothLevel) * size.height * 0.47)

                for layer in 0..<3 {
                    var path = Path()
                    let phaseShift = Double(layer) * 1.15
                    let speed = layer == 0 ? 10.5 : (layer == 1 ? 7.4 : 5.2)
                    let freq = layer == 0 ? 2.7 : (layer == 1 ? 2.0 : 1.5)
                    let scale: CGFloat = layer == 0 ? 1.0 : (layer == 1 ? 0.78 : 0.55)

                    for xInt in stride(from: 0, through: Int(size.width), by: 2) {
                        let x = CGFloat(xInt)
                        let norm = Double(x / size.width)
                        let envelope = pow(sin(norm * Double.pi), 1.25)
                        let yOffset = sin(norm * Double.pi * freq - t * speed + phaseShift) * Double(amp * scale) * envelope
                        let pt = CGPoint(x: x, y: midY + CGFloat(yOffset))
                        if xInt == 0 {
                            path.move(to: pt)
                        } else {
                            path.addLine(to: pt)
                        }
                    }

                    let opacity = layer == 0 ? 0.94 : (layer == 1 ? 0.42 : 0.20)
                    let width: CGFloat = layer == 0 ? 1.9 : (layer == 1 ? 1.35 : 1.0)
                    ctx.stroke(
                        path,
                        with: .color(accent.opacity(opacity)),
                        style: StrokeStyle(lineWidth: width, lineCap: .round)
                    )
                }
            }
        }
    }
}
