import SwiftUI
import AppKit

struct TZSidebar: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
                .padding(.top, 46)
                .padding(.leading, 16)
                .padding(.trailing, 10)

            VStack(spacing: 2) {
                ForEach(SidebarTab.tzNavTabs) { tab in
                    TZNavRow(tab: tab, isSelected: appState.selectedTab == tab) {
                        appState.selectedTab = tab
                    }
                }
            }
            .padding(.top, 22)
            .padding(.horizontal, 8)

            Spacer(minLength: 12)

            TZEnginesCard(summary: TZEnginesSummary.make(TZEngineInputs(appState: appState))) {
                appState.selectedTab = .settings
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)

            Rectangle()
                .fill(TZTheme.hairline)
                .frame(height: 1)

            footerIcons
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
        }
        .frame(width: 186)
        .frame(maxHeight: .infinity)
        .background(TZTheme.sidebar)
    }

    private var brand: some View {
        HStack(spacing: 7) {
            NevertypeMarkView(size: 18)
            Text(AppBrand.name)
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(TZTheme.ink)
                .lineLimit(1)
                .fixedSize()
            Text("Local")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TZTheme.blue)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(TZTheme.blueTint))
                .fixedSize()
        }
    }

    private var footerIcons: some View {
        HStack(spacing: 2) {
            let settingsSelected = appState.selectedTab == .settings
            Button {
                appState.selectedTab = .settings
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(TZTheme.inkNav)
                    .frame(width: 34, height: 32)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(settingsSelected ? TZTheme.navSelected : Color.clear))
                    .overlay(alignment: .topTrailing) {
                        if !appState.micAuthorized || !appState.accessibilityGranted {
                            Circle()
                                .fill(Color(hex: 0xE59A1F))
                                .frame(width: 8, height: 8)
                                .overlay(Circle().strokeBorder(TZTheme.sidebar, lineWidth: 1.5))
                                .offset(x: -3, y: 3)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help((!appState.micAuthorized || !appState.accessibilityGranted) ? "Settings (permissions needed)" : "Settings")
            .accessibilityLabel("Settings")

            Button {
                NSWorkspace.shared.open(AppBrand.upstreamRepositoryURL)
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(TZTheme.inkNav)
                    .frame(width: 34, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(AppBrand.upstreamAttribution)
            .accessibilityLabel(AppBrand.upstreamAttribution)

            Spacer()
        }
    }
}

private struct TZNavRow: View {
    let tab: SidebarTab
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tab.tzIcon)
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 22)
                Text(tab.tzTitle)
                    .font(.system(size: 15))
                Spacer(minLength: 0)
            }
            .foregroundStyle(TZTheme.inkNav)
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? TZTheme.navSelected : (hovering ? TZTheme.navSelected.opacity(0.5) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct TZEnginesCard: View {
    let summary: TZEnginesSummary
    var onTap: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Engines")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TZTheme.inkMuted)
            engineLine(summary.speech)
            engineLine(summary.cleanup)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tzCard(radius: 16)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
    }

    private func engineLine(_ line: TZEngineLine) -> some View {
        HStack(alignment: .top, spacing: 8) {
            TZStatusDot(tone: line.tone)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(line.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(TZTheme.inkNav)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(line.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(TZTheme.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}
