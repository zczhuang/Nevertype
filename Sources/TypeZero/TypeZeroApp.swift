import SwiftUI
import AppKit

@main
enum TypeZeroMain {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            let core = SelfTestSuite.runAll()
            let ui = TZUISelfTests.runAll()
            let typelessImport = TypelessImportSelfTests.runAll()
            exit(core != 0 ? core : (ui != 0 ? ui : typelessImport))
        }
        // Read-only preview of "sync history from Typeless": prints row counts for the real typeless.db and writes nothing.
        if CommandLine.arguments.contains("--typeless-import-dry-run") {
            exit(TypelessHistoryImporter.runDryRun())
        }
        if CommandLine.arguments.contains("--bench-asr") {
            exit(SelfTestSuite.runDualASRSmokeBenchmark())
        }
        if let idx = CommandLine.arguments.firstIndex(of: "--ab-verify"), idx + 1 < CommandLine.arguments.count {
            exit(SelfTestSuite.runEmpiricalABVerification(wavPath: CommandLine.arguments[idx + 1]))
        }
        // Headless end-to-end test (no microphone, no GUI): Nevertype --dictate-file <path.wav> [--style ...] [--scene ...]
        if CommandLine.arguments.contains("--dictate-file") {
            exit(DictateFileCLI.run(arguments: Array(CommandLine.arguments.dropFirst())))
        }
        // Visual QA: renders every page of the main window to PNGs with sample data (see TZRenderUI): Nevertype --render-ui <output-dir>
        if CommandLine.arguments.contains("--render-ui") {
            exit(TZRenderUI.run(arguments: Array(CommandLine.arguments.dropFirst())))
        }
        TypeZeroApp.main()
    }
}

@MainActor
final class TypeZeroAppDelegate: NSObject, NSApplicationDelegate {
    static var openMainWindowAction: (() -> Void)?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Stay resident silently in the top macOS Menu Bar when main window is closed
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Re-opening the app from Spotlight or Applications brings the main dashboard right back
        Self.openMainWindowAction?()
        return true
    }
}

struct TypeZeroApp: App {
    @NSApplicationDelegateAdaptor(TypeZeroAppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        Window(AppBrand.name, id: "main") {
            MainWindowHost(appState: appState)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1000, height: 680)

        MenuBarExtra {
            TypeZeroMenuBarContent(appState: appState)
        } label: {
            Image(nsImage: NevertypeMenuBarIcon.image())
                .renderingMode(.template)
                .accessibilityLabel(AppBrand.name)
        }
    }
}

private struct MainWindowHost: View {
    @ObservedObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MainDashboardView(appState: appState)
            .task {
                // Once per launch (the coordinator ignores later calls). Lives here rather than in MainDashboardView,
                // which `--render-ui` also hosts with sample data.
                await TypelessSyncCoordinator.shared.syncOnLaunch(into: appState)
            }
            .onAppear {
                TypeZeroAppDelegate.openMainWindowAction = {
                    openWindow(id: "main")
                    DispatchQueue.main.async {
                        NSApp.activate(ignoringOtherApps: true)
                        for window in NSApp.windows where window.identifier?.rawValue == "main" || window.title == AppBrand.name {
                            window.deminiaturize(nil)
                            window.makeKeyAndOrderFront(nil)
                            window.orderFrontRegardless()
                        }
                    }
                }
            }
    }
}

private struct TypeZeroMenuBarContent: View {
    @ObservedObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open \(AppBrand.name)") {
            presentMainWindow(tab: nil)
        }
        .keyboardShortcut(",", modifiers: [.command])

        Button("Settings…") {
            presentMainWindow(tab: .settings)
        }

        Button("Dictionary (\(appState.lexiconStore.entries.count) \(appState.lexiconStore.entries.count == 1 ? "word" : "words"))…") {
            presentMainWindow(tab: .dictionary)
        }

        Divider()

        Text("Shortcut: \(appState.tzShortcutName)")
        Text("Words dictated: \(TZStats.formatCount(TZStats.totals(appState.history).words))")

        Button("Start / Stop Test Dictation") {
            if case .listening = appState.phase {
                Task { await appState.finishDictationSession() }
            } else {
                appState.beginDictationSession()
            }
        }

        if !appState.history.isEmpty {
            Divider()
            Text("Recent dictations (click to copy)")
            ForEach(appState.history.prefix(5)) { rec in
                Button(String(rec.polishedText.replacingOccurrences(of: "\n", with: " ").prefix(26))) {
                    ContextInjector.copyPlainText(rec.polishedText)
                }
            }
        }

        Divider()

        Toggle("Show Icon in Dock", isOn: $appState.llmConfig.showInDock)

        Button("Check for Updates… (v\(appState.currentAppVersion))") {
            presentMainWindow(tab: nil)
            Task { await appState.checkForUpdates(manual: true) }
        }

        Button("Quit \(AppBrand.name)") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
        .onAppear {
            let stateRef = appState
            TypeZeroAppDelegate.openMainWindowAction = { [weak stateRef] in
                guard stateRef != nil else { return }
                presentMainWindow(tab: nil)
            }
        }
    }

    @MainActor
    private func presentMainWindow(tab: SidebarTab?) {
        if let tab {
            appState.selectedTab = tab
        }
        openWindow(id: "main")
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.identifier?.rawValue == "main" || window.title == AppBrand.name {
                window.deminiaturize(nil)
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
        }
    }
}
