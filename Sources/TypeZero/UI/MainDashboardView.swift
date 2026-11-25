import SwiftUI
import AppKit

/// Debug-only knobs used by `--render-ui` to put the pages into states that normally need a click or a hover.
struct TZSnapshotOptions {
    /// Vertical scroll position (points) of the page content.
    var scrollOffset: CGFloat = 0
    var expandedASR: ASRProviderOption? = nil
    var expandedLLM: LLMProviderOption? = nil
    var hoverFirstHistoryRow: Bool = false
    var expandFirstHistoryRow: Bool = false
    var historyFilter: TZHistoryFilter = .all
    var dictionaryFilter: TZDictionaryFilter = .all
    var dictionarySearch: String? = nil
    var dictionaryBatchMode: Bool = false
    var heatmapMonthOffset: Int = 0
    var statusBanner: String? = nil
    /// Caps how many history records are laid out (keeps snapshot rendering fast).
    var historyRecordLimit: Int? = nil
}

// MARK: - Window shell

public struct MainDashboardView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var lexiconStore: PersonalLexiconStore
    private let snapshot: TZSnapshotOptions?

    public init(appState: AppState) {
        self.appState = appState
        self.lexiconStore = appState.lexiconStore
        self.snapshot = nil
    }

    init(appState: AppState, snapshot: TZSnapshotOptions?) {
        self.appState = appState
        self.lexiconStore = appState.lexiconStore
        self.snapshot = snapshot
    }

    public var body: some View {
        HStack(spacing: 0) {
            TZSidebar(appState: appState)
            contentArea
        }
        .frame(minWidth: 960, minHeight: 640)
        .background(TZTheme.canvas)
        .preferredColorScheme(.light)
        .sheet(isPresented: $appState.showOnboardingSheet) {
            OnboardingWizardSheet(appState: appState)
        }
    }

    private var contentArea: some View {
        pageScroller
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(TZTheme.canvas)
            .overlay(alignment: .top) { toast }
    }

    @ViewBuilder
    private var pageScroller: some View {
        let page = TZPageContent(appState: appState, lexiconStore: lexiconStore, tab: appState.selectedTab, snapshot: snapshot)
        if let snapshot {
            // Snapshot mode: emulate a scroll position without a ScrollView so every page can be captured deterministically.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    page
                        .fixedSize(horizontal: false, vertical: true)
                        .offset(y: -snapshot.scrollOffset)
                }
                .clipped()
        } else {
            ScrollView(.vertical) {
                page
            }
            .id(appState.selectedTab)
        }
    }

    @ViewBuilder
    private var toast: some View {
        let text = snapshot?.statusBanner ?? appState.statusBanner
        if !text.isEmpty {
            TZToast(message: text) {
                appState.statusBanner = ""
            }
            .padding(.top, 12)
            .padding(.horizontal, 24)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: text) {
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                if appState.statusBanner == text { appState.statusBanner = "" }
            }
        }
    }
}

/// Padded page body shared by the live window and the snapshot renderer.
struct TZPageContent: View {
    @ObservedObject var appState: AppState
    @ObservedObject var lexiconStore: PersonalLexiconStore
    let tab: SidebarTab
    let snapshot: TZSnapshotOptions?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch tab {
            case .home:
                TZHomePage(appState: appState, snapshot: snapshot)
            case .history:
                TZHistoryPage(appState: appState, snapshot: snapshot)
            case .dictionary:
                TZDictionaryPage(appState: appState, lexiconStore: lexiconStore, snapshot: snapshot)
            case .settings:
                TZSettingsPage(appState: appState, snapshot: snapshot)
            }
        }
        .padding(EdgeInsets(top: 28, leading: 24, bottom: 32, trailing: 28))
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Toast

struct TZToast: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        let parsed = TZStatusMessage.parse(message)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: parsed.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(parsed.color)
                .padding(.top, 1)
            Text(parsed.text)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(TZTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(TZTheme.inkMuted)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: 560)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(TZTheme.border, lineWidth: 1))
        .shadow(color: Color.black.opacity(0.10), radius: 14, x: 0, y: 4)
    }
}
