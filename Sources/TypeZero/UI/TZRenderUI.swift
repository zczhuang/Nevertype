import SwiftUI
import AppKit

/// `Nevertype --render-ui <output-dir>`
///
/// Renders every page of the main window to PNGs (1000x680 @2x) for visual QA. It uses sample data only:
///  - HOME is redirected to a throw-away folder first, so history, lexicon and config files are created there and the
///    real `~/Library/Application Support/Nevertype` is never touched;
///  - the main run loop is never run, so the work AppState defers to it (hotkey monitor, floating pill, model warm-up,
///    permission prompts, engine pre-warming) never starts and no audio or network is used;
///  - the process's user-defaults domain is snapshotted and restored on exit.
///
/// Pages are drawn with an `NSHostingView` (`cacheDisplay`) rather than `ImageRenderer`: ImageRenderer paints every
/// AppKit-backed control (text fields, menus, scroll views, pickers) as a "prohibited" placeholder.
enum TZRenderUI {
    static let usage = "usage: \(AppBrand.name) --render-ui <output-dir>"

    static func run(arguments: [String]) -> Int32 {
        guard let idx = arguments.firstIndex(of: "--render-ui"),
              idx + 1 < arguments.count,
              !arguments[idx + 1].hasPrefix("--") else {
            FileHandle.standardError.write(Data((usage + "\n").utf8))
            return 2
        }
        let outDir = URL(fileURLWithPath: arguments[idx + 1], isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("cannot create \(outDir.path): \(error.localizedDescription)\n".utf8))
            return 1
        }
        return MainActor.assumeIsolated { renderAll(into: outDir) }
    }

    // MARK: Driver

    @MainActor
    private static func renderAll(into outDir: URL) -> Int32 {
        let fm = FileManager.default
        // Resolved before HOME is redirected: where this process's real preferences file lives.
        let realHome = NSHomeDirectory()

        // 1. Isolate everything AppState reads or writes under HOME.
        let sandbox = fm.temporaryDirectory.appendingPathComponent("nevertype-render-ui-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? fm.removeItem(at: sandbox)
        let support = sandbox.appendingPathComponent("Library/Application Support/\(AppBrand.name)", isDirectory: true)
        let parakeetDir = support
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(LocalASRModel.parakeetTDTv2.extractedFolderName, isDirectory: true)
        do {
            try fm.createDirectory(at: parakeetDir, withIntermediateDirectories: true)
            // Empty placeholder files make the on-device model look installed. Nothing ever loads them in this mode.
            for name in LocalASRModel.parakeetTDTv2.requiredFileNames {
                fm.createFile(atPath: parakeetDir.appendingPathComponent(name).path, contents: Data())
            }
            // An empty placeholder where Typeless keeps its database, so Settings offers the "Import history from Typeless"
            // switch. Nothing opens it: the import is off, and the main run loop (where the syncs run) never runs here.
            let typelessDir = sandbox.appendingPathComponent("Library/Application Support/Typeless", isDirectory: true)
            try fm.createDirectory(at: typelessDir, withIntermediateDirectories: true)
            fm.createFile(atPath: typelessDir.appendingPathComponent("typeless.db").path, contents: Data())
        } catch {
            FileHandle.standardError.write(Data("cannot prepare sandbox: \(error.localizedDescription)\n".utf8))
            return 1
        }
        setenv("HOME", sandbox.path, 1)
        setenv("CFFIXED_USER_HOME", sandbox.path, 1)
        // A non-empty value makes KeychainHelper skip the keychain for provider keys.
        setenv("NEVERTYPE_API_KEY", "render-ui-placeholder", 1)

        // 2. UserDefaults cannot be redirected; snapshot this process's domain and restore it afterwards.
        let defaultsDomain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        let savedDefaults = UserDefaults.standard.persistentDomain(forName: defaultsDomain)
        defer {
            if let savedDefaults {
                UserDefaults.standard.setPersistentDomain(savedDefaults, forName: defaultsDomain)
            } else {
                UserDefaults.standard.removePersistentDomain(forName: defaultsDomain)
            }
            UserDefaults.standard.synchronize()
            if savedDefaults == nil {
                // The domain did not exist before this run; do not leave an empty plist behind.
                let plist = URL(fileURLWithPath: realHome).appendingPathComponent("Library/Preferences/\(defaultsDomain).plist")
                try? fm.removeItem(at: plist)
            }
            try? fm.removeItem(at: sandbox)
        }

        // 3. Offscreen AppKit only (no Dock icon, nothing shown).
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let appState = AppState()
        let now = Date()
        prepareSampleState(appState, now: now)
        let renderer = Renderer(outDir: outDir, appState: appState)

        // Home, History, Dictionary with data.
        appState.accessibilityGranted = true
        renderer.pages(.home, base: "home")
        appState.accessibilityGranted = false
        renderer.pages(.home, base: "home-permissions", onlyFirst: true)
        appState.accessibilityGranted = true
        renderer.pages(.home, base: "home-banner", options: bannerOptions(), onlyFirst: true)
        renderer.pages(.history, base: "history", options: historyOptions())
        renderer.pages(.history, base: "history-hover", options: historyOptions(hover: true), onlyFirst: true)
        renderer.pages(.history, base: "history-rewrites", options: historyOptions(filter: .rewrites), onlyFirst: true)
        renderer.pages(.dictionary, base: "dictionary", options: TZSnapshotOptions())
        renderer.pages(.dictionary, base: "dictionary-auto", options: dictionaryOptions(filter: .auto), onlyFirst: true)
        renderer.pages(.dictionary, base: "dictionary-search", options: dictionaryOptions(search: "ol"), onlyFirst: true)
        renderer.pages(.dictionary, base: "dictionary-select", options: dictionaryOptions(batch: true), onlyFirst: true)
        renderer.sheet(TZLexiconEditSheet(appState: appState, entry: appState.lexiconStore.entries.first { $0.term == "Ollama" }), base: "dictionary-edit-sheet", tab: .dictionary)
        renderer.sheet(TZLexiconEditSheet(appState: appState, entry: nil), base: "dictionary-new-sheet", tab: .dictionary)
        renderer.sheet(TZLexiconImportSheet(appState: appState), base: "dictionary-import-sheet", tab: .dictionary)

        // Settings: permissions missing on purpose, so the amber states are visible.
        appState.accessibilityGranted = false
        renderer.pages(.settings, base: "settings", options: TZSnapshotOptions(), maxPages: 8)
        var expanded = TZSnapshotOptions()
        expanded.expandedASR = .openAIWhisper
        expanded.expandedLLM = .custom
        renderer.pages(.settings, base: "settings-expanded", options: expanded, maxPages: 10)
        var doubao = TZSnapshotOptions()
        doubao.expandedASR = .volcSeedASR
        doubao.expandedLLM = .openai
        renderer.pages(.settings, base: "settings-cloud-cards", options: doubao, maxPages: 3, onlyFirst: false)

        // On-device engine card: expanded, mid-download, and with no model installed.
        var localExpanded = TZSnapshotOptions()
        localExpanded.expandedASR = .localSenseVoice
        renderer.pages(.settings, base: "settings-local-engine", options: localExpanded, onlyFirst: true)
        appState.isDownloadingOfflineModel = true
        appState.downloadingLocalModel = .senseVoice
        appState.offlineDownloadProgress = 0.42
        appState.offlineDownloadStatusText = "Downloading SenseVoice-Small… 42% (372 of 886 MB)"
        renderer.pages(.settings, base: "settings-local-download", options: localExpanded, onlyFirst: true)
        appState.isDownloadingOfflineModel = false
        appState.downloadingLocalModel = nil
        appState.installedLocalModels = []
        appState.senseVoiceLoaded = false
        appState.activeLocalModel = nil
        renderer.pages(.settings, base: "settings-no-model", options: localExpanded, onlyFirst: true)
        renderer.pages(.history, base: "history-no-model", options: historyOptions(), onlyFirst: true)
        appState.refreshInstalledLocalModels()
        appState.senseVoiceLoaded = true
        appState.activeLocalModel = .parakeetTDTv2

        // Shortcut recorder armed.
        appState.isRecordingShortcut = true
        var recording = TZSnapshotOptions()
        recording.scrollOffset = 1100
        renderer.write(MainDashboardView(appState: appState, snapshot: recording), size: renderer.size, name: "settings-recording-shortcut", tab: .settings)
        appState.isRecordingShortcut = false

        // Output section (the "Sound effects" switch, with no sound-style picker under it).
        var output = TZSnapshotOptions()
        output.scrollOffset = 1250
        renderer.write(MainDashboardView(appState: appState, snapshot: output), size: renderer.size, name: "settings-output", tab: .settings)

        // The Import section (shown because the placeholder Typeless database exists): switch off, which is the default, and on.
        var typelessImport = TZSnapshotOptions()
        typelessImport.scrollOffset = 2100
        renderer.write(MainDashboardView(appState: appState, snapshot: typelessImport), size: renderer.size, name: "settings-typeless-import", tab: .settings)
        appState.llmConfig.enableTypelessImport = true
        renderer.write(MainDashboardView(appState: appState, snapshot: typelessImport), size: renderer.size, name: "settings-typeless-import-on", tab: .settings)
        appState.llmConfig.enableTypelessImport = false

        // Onboarding sheet over the dimmed Home page.
        appState.accessibilityGranted = true
        renderer.sheet(OnboardingWizardSheet(appState: appState), base: "onboarding", tab: .home)

        // Sidebar engine card for other configurations.
        renderer.enginesVariants(base: "engines-variants")

        // Floating pill capsules (Thinking and the error states) at the pill window's real size.
        renderer.pillVariants(base: "pill-states")

        // The brand mark at the sizes it is drawn at, and the menu bar icon on a light and a dark menu bar.
        renderer.brandMarks(base: "brand-marks")

        // Empty states.
        appState.history = []
        TZSampleData.clearLexicon(appState.lexiconStore)
        renderer.pages(.home, base: "empty-home", onlyFirst: true)
        renderer.pages(.history, base: "empty-history", onlyFirst: true)
        renderer.pages(.dictionary, base: "empty-dictionary", onlyFirst: true)

        print("Rendered \(renderer.written.count) images into \(outDir.path)")
        for name in renderer.written { print("  \(name)") }
        return 0
    }

    // MARK: Sample state

    @MainActor
    private static func prepareSampleState(_ appState: AppState, now: Date) {
        // Secrets that init may have read from the keychain never appear in snapshots.
        appState.apiKeyInput = ""
        appState.volcSpeechKeyInput = ""
        appState.openAIASRKeyInput = ""
        // Pretend only a DeepSeek key is saved, so both "key saved" and "key needed" states appear.
        TZPreviewKeys.override = [.deepseek: "sk-preview"]
        appState.savedProviderKeyFlags = [.deepseek: true]
        appState.statusBanner = ""
        appState.sandboxText = ""
        appState.showOnboardingSheet = false

        appState.history = TZSampleData.history(now: now)
        TZSampleData.seedLexicon(appState.lexiconStore)

        appState.refreshInstalledLocalModels()
        appState.senseVoiceLoaded = true
        appState.activeLocalModel = .parakeetTDTv2
        appState.micAuthorized = true
        appState.speechAuthorized = true
        appState.accessibilityGranted = true
        appState.triggerKey = .rightOption
        appState.triggerBehavior = .tapToggle
    }

    private static func bannerOptions() -> TZSnapshotOptions {
        var o = TZSnapshotOptions()
        o.statusBanner = "✅ Added “Kubernetes” to your dictionary."
        return o
    }

    private static func historyOptions(hover: Bool = false, filter: TZHistoryFilter = .all) -> TZSnapshotOptions {
        var o = TZSnapshotOptions()
        o.historyFilter = filter
        o.hoverFirstHistoryRow = hover
        o.expandFirstHistoryRow = hover
        o.historyRecordLimit = 90
        return o
    }

    private static func dictionaryOptions(filter: TZDictionaryFilter = .all, search: String? = nil, batch: Bool = false) -> TZSnapshotOptions {
        var o = TZSnapshotOptions()
        o.dictionaryFilter = filter
        o.dictionarySearch = search
        o.dictionaryBatchMode = batch
        return o
    }

    // MARK: Renderer

    @MainActor
    private final class Renderer {
        let outDir: URL
        let appState: AppState
        let size = CGSize(width: 1000, height: 680)
        var written: [String] = []

        init(outDir: URL, appState: AppState) {
            self.outDir = outDir
            self.appState = appState
        }

        /// Renders a page at one or more scroll positions of the 1000x680 window.
        func pages(_ tab: SidebarTab, base: String, options: TZSnapshotOptions = TZSnapshotOptions(), maxPages: Int = 5, onlyFirst: Bool = false) {
            appState.selectedTab = tab
            let contentHeight = measure(tab: tab, options: options)
            let step: CGFloat = 600
            var offset: CGFloat = 0
            var page = 1
            while true {
                var o = options
                o.scrollOffset = offset
                write(MainDashboardView(appState: appState, snapshot: o), size: size, name: page == 1 ? base : "\(base)-\(page)")
                if onlyFirst || offset + size.height >= contentHeight - 2 || page >= maxPages { break }
                offset += step
                page += 1
            }
        }

        /// Renders `sheet` centred over the dimmed window.
        func sheet<S: View>(_ sheet: S, base: String, tab: SidebarTab, height: CGFloat? = nil) {
            appState.selectedTab = tab
            let canvas = CGSize(width: size.width, height: height ?? size.height)
            let composite = ZStack {
                MainDashboardView(appState: appState, snapshot: TZSnapshotOptions())
                    .frame(width: canvas.width, height: canvas.height)
                Color.black.opacity(0.30)
                sheet
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: Color.black.opacity(0.28), radius: 24, x: 0, y: 8)
            }
            write(composite, size: canvas, name: base)
        }

        /// The sidebar Engines card for a few configurations (cloud providers, verbatim mode, missing key).
        func enginesVariants(base: String) {
            var local = TZEngineInputs(config: LLMConfig.default)
            local.localLoaded = true
            local.installedLocal = [.parakeetTDTv2]
            local.activeLocal = .parakeetTDTv2

            var cloud = local
            cloud.config.asrProvider = .openAIWhisper
            cloud.config.openAIASRBaseURL = "https://api.groq.com/openai/v1"
            cloud.config.openAIASRModel = "whisper-large-v3-turbo"
            cloud.isGroqASR = true
            cloud.hasOpenAIASRKey = true
            cloud.config.selectProvider(.openai)
            cloud.hasCleanupKey = true

            var doubao = local
            doubao.config.asrProvider = .volcSeedASR
            doubao.hasVolcCredential = false
            doubao.config.selectProvider(.deepseek)
            doubao.hasCleanupKey = false

            var verbatim = local
            verbatim.config.formattingStyle = .verbatimLocal
            verbatim.localLoaded = false

            let cards: [(String, TZEngineInputs)] = [
                ("Local + Ollama", local), ("Groq + OpenAI", cloud), ("Doubao, no keys", doubao), ("Verbatim, loading", verbatim)
            ]
            let view = HStack(alignment: .top, spacing: 18) {
                ForEach(Array(cards.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(entry.0)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(TZTheme.inkSecondary)
                        TZEnginesCard(summary: TZEnginesSummary.make(entry.1))
                            .frame(width: 170)
                    }
                    .padding(8)
                    .background(TZTheme.sidebar)
                }
            }
            .padding(24)
            .frame(width: 1000, height: 220, alignment: .topLeading)
            .background(Color.white)
            write(view, size: CGSize(width: 1000, height: 220), name: base)
        }

        /// The floating pill's Thinking and error capsules, each inside the pill window's real 224 x 58 pt frame (dashed outline)
        /// over a grey backdrop, so clipping against the panel edges is visible.
        func pillVariants(base: String) {
            let panel = FloatingPillLayout.panelSize
            let overlong = Array(repeating: "This reason is much too long to fit in the pill.", count: 4).joined(separator: " ")
            let cloudFailure = DictationFailure.engineError("Cloud speech recognition failed: HTTP 401: Incorrect API key provided: gsk_abc123. Check the key.")
            let cells: [(String, AnyView)] = [
                ("Thinking", AnyView(FloatingPillThinkingView())),
                ("Accessibility", AnyView(FloatingPillErrorView(message: DictationFailure.accessibilityOff.pillText))),
                ("Microphone", AnyView(FloatingPillErrorView(message: DictationFailure.microphoneOff.pillText))),
                ("Speech Recognition", AnyView(FloatingPillErrorView(message: DictationFailure.speechRecognitionOff.pillText))),
                ("Cloud error (shortened)", AnyView(FloatingPillErrorView(message: cloudFailure.pillText))),
                ("No speech", AnyView(FloatingPillErrorView(message: DictationFailure.noSpeechPillText))),
                ("Over-long text (cut at 2 lines)", AnyView(FloatingPillErrorView(message: overlong))),
                ("Icon only (empty message)", AnyView(FloatingPillErrorView(message: "")))
            ]
            let columns = 4
            let rows = (cells.count + columns - 1) / columns
            let gap: CGFloat = 16
            let labelHeight: CGFloat = 18
            let canvas = CGSize(
                width: CGFloat(columns) * panel.width + CGFloat(columns + 1) * gap,
                height: CGFloat(rows) * (panel.height + labelHeight) + CGFloat(rows + 1) * gap
            )
            let view = VStack(alignment: .leading, spacing: gap) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(alignment: .top, spacing: gap) {
                        ForEach(0..<columns, id: \.self) { column in
                            let index = row * columns + column
                            if index < cells.count {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(cells[index].0)
                                        .font(.system(size: 10.5, weight: .medium))
                                        .foregroundStyle(Color.black.opacity(0.62))
                                        .frame(height: labelHeight - 4, alignment: .leading)
                                    cells[index].1
                                        .frame(width: panel.width, height: panel.height)
                                        .overlay(
                                            Rectangle()
                                                .strokeBorder(Color.black.opacity(0.35), style: StrokeStyle(lineWidth: 0.5, dash: [3, 2]))
                                        )
                                }
                            } else {
                                Color.clear.frame(width: panel.width, height: panel.height + labelHeight)
                            }
                        }
                    }
                }
            }
            .padding(gap)
            .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
            .background(Color(white: 0.80))
            write(view, size: canvas, name: base)
        }

        /// The Nevertype mark at the sizes the app draws it (pill, sidebar, setup guide), and the menu bar icon (a template image,
        /// tinted by macOS) on a light and a dark menu bar.
        func brandMarks(base: String) {
            let sizes: [CGFloat] = [14, 16, 18, 26, 44, 96]
            let canvas = CGSize(width: 520, height: 230)
            let view = VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .bottom, spacing: 22) {
                    ForEach(sizes, id: \.self) { size in
                        VStack(spacing: 6) {
                            NevertypeMarkView(size: size)
                            Text("\(Int(size)) pt")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.black.opacity(0.55))
                        }
                    }
                }
                HStack(spacing: 18) {
                    ForEach([false, true], id: \.self) { dark in
                        HStack(spacing: 14) {
                            Image(nsImage: NevertypeMenuBarIcon.image())
                                .renderingMode(.template)
                                .foregroundStyle(dark ? Color.white : Color.black)
                            Text(dark ? "Menu bar, dark" : "Menu bar, light")
                                .font(.system(size: 12))
                                .foregroundStyle(dark ? Color.white.opacity(0.85) : Color.black.opacity(0.7))
                        }
                        .padding(.horizontal, 14)
                        .frame(width: 220, height: 28, alignment: .leading)
                        .background(dark ? Color(white: 0.16) : Color(white: 0.93))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
                HStack(spacing: 10) {
                    NevertypeMarkView(size: 20)
                    Text(AppBrand.name)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(TZTheme.ink)
                }
            }
            .padding(20)
            .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
            .background(Color.white)
            write(view, size: canvas, name: base)
        }

        // MARK: Low level

        private func measure<V: View>(_ view: V, width: CGFloat) -> CGFloat {
            let host = NSHostingView(rootView: view.frame(width: width).fixedSize(horizontal: false, vertical: true))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 4_000), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let height = host.fittingSize.height
            window.contentView = nil
            return height
        }

        private func measure(tab: SidebarTab, options: TZSnapshotOptions) -> CGFloat {
            let page = TZPageContent(appState: appState, lexiconStore: appState.lexiconStore, tab: tab, snapshot: options)
            return measure(page, width: size.width - 186)
        }

        func write<V: View>(_ root: V, size: CGSize, name: String, tab: SidebarTab) {
            appState.selectedTab = tab
            write(root, size: size, name: name)
        }

        func write<V: View>(_ root: V, size: CGSize, name: String) {
            let host = NSHostingView(rootView: root.frame(width: size.width, height: size.height).environment(\.colorScheme, .light))
            host.sizingOptions = []
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()

            let scale = 2
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width) * scale,
                pixelsHigh: Int(size.height) * scale,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else { return }
            rep.size = NSSize(width: size.width, height: size.height)
            host.cacheDisplay(in: host.bounds, to: rep)
            window.contentView = nil

            if let data = rep.representation(using: .png, properties: [:]) {
                let url = outDir.appendingPathComponent("\(name).png")
                do {
                    try data.write(to: url, options: .atomic)
                    written.append("\(name).png")
                } catch {
                    FileHandle.standardError.write(Data("failed to write \(url.path): \(error.localizedDescription)\n".utf8))
                }
            }
        }
    }
}
