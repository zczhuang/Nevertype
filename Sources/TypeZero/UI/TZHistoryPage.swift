import SwiftUI
import AppKit

enum TZHistoryFilter: Hashable {
    case all, dictations, rewrites
}

// MARK: - History persistence helpers (UI layer)
//
// `AppState.saveHistory()` is private and no delete/clear action exists on AppState, so the UI mutates the public
// `history` array and writes the same `history.json` file (same location, same default JSON encoding) itself.

extension AppState {
    private static var tzHistoryFileURL: URL {
        let dir = AppBrand.applicationSupportDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    func tzPersistHistory() {
        if let data = try? JSONEncoder().encode(history) {
            try? data.write(to: Self.tzHistoryFileURL, options: .atomic)
        }
    }

    func tzDeleteHistoryRecord(_ id: UUID) {
        history.removeAll { $0.id == id }
        tzPersistHistory()
    }

    func tzClearHistory() {
        history = []
        tzPersistHistory()
    }
}

enum TZClipboard {
    static func copy(_ text: String) {
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

// MARK: - Page

struct TZHistoryPage: View {
    @ObservedObject var appState: AppState
    let snapshot: TZSnapshotOptions?

    @State private var filter: TZHistoryFilter
    @State private var confirmClear = false
    @State private var addWordSheet = false
    @State private var syncingTypeless = false

    init(appState: AppState, snapshot: TZSnapshotOptions?) {
        self.appState = appState
        self.snapshot = snapshot
        _filter = State(initialValue: snapshot?.historyFilter ?? .all)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                TZPageTitle(text: "History")
                Spacer()
                moreMenu
            }

            infoPanel
                .padding(.top, 22)

            TZSegmentedControl(
                items: [
                    .init(value: TZHistoryFilter.all, title: "All"),
                    .init(value: TZHistoryFilter.dictations, title: "Dictations"),
                    .init(value: TZHistoryFilter.rewrites, title: "Rewrites")
                ],
                selection: $filter
            )
            .padding(.top, 20)

            content
                .padding(.top, 22)
        }
        .confirmationDialog("Clear all history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear history", role: .destructive) { appState.tzClearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all \(appState.history.count) dictations stored on this Mac. It can't be undone.")
        }
        .sheet(isPresented: $addWordSheet) {
            TZLexiconEditSheet(appState: appState, entry: nil)
        }
        .task {
            // Quiet unless something was imported. Only when the user switched the Typeless import on in Settings (the coordinator
            // checks too), and never in `--render-ui` snapshots, which would write history.json.
            guard snapshot == nil, appState.llmConfig.enableTypelessImport else { return }
            await TypelessSyncCoordinator.shared.sync(into: appState, manual: false)
        }
    }

    // MARK: Top bar

    private func syncFromTypeless() {
        guard !syncingTypeless else { return }
        syncingTypeless = true
        Task { @MainActor in
            await TypelessSyncCoordinator.shared.sync(into: appState, manual: true)
            syncingTypeless = false
        }
    }

    private var moreMenu: some View {
        Menu {
            // Only while the Typeless import is switched on (Settings -> Import).
            if appState.llmConfig.enableTypelessImport {
                Button {
                    syncFromTypeless()
                } label: {
                    Label("Sync from Typeless", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(syncingTypeless)
                Divider()
            }
            Button(role: .destructive) {
                confirmClear = true
            } label: {
                Label("Clear history…", systemImage: "trash")
            }
            .disabled(appState.history.isEmpty)
        } label: {
            TZCircleButtonLabel(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("History options")
    }

    // MARK: Info panel

    /// Records in the history that "Sync from Typeless" brought in (they are the ones whose app name is "Typeless").
    private var typelessImportedCount: Int {
        appState.history.reduce(0) { $0 + ($1.targetAppName == TypelessMapper.appName ? 1 : 0) }
    }

    private var infoPanel: some View {
        let privacy = TZPrivacySummary.make(TZEngineInputs(appState: appState))
        let imported = typelessImportedCount
        return VStack(alignment: .leading, spacing: 0) {
            infoRow(
                icon: "internaldrive",
                title: "Stored on this Mac",
                text: "\(AppBrand.name) keeps your latest 1,000 dictations on this device.",
                note: imported > 0
                    ? "Includes \(TZStats.formatGrouped(imported)) \(imported == 1 ? "dictation" : "dictations") imported from Typeless."
                    : nil
            )
            TZRowDivider()
            infoRow(
                icon: "lock",
                title: "Privacy",
                text: privacy.text,
                iconTint: privacy.isFullyLocal ? TZTheme.green : TZTheme.amber
            )
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tzPanel(radius: 14)
    }

    private func infoRow(icon: String, title: String, text: String, note: String? = nil, iconTint: Color = TZTheme.inkNav) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(iconTint)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(TZTheme.ink)
                Text(text)
                    .font(.system(size: 14))
                    .foregroundStyle(TZTheme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note {
                    Text(note)
                        .font(.system(size: 14))
                        .foregroundStyle(TZTheme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Records

    private var filteredRecords: [DictationRecord] {
        var records: [DictationRecord]
        switch filter {
        case .all: records = appState.history
        case .dictations: records = appState.history.filter { $0.mode == .dictate }
        case .rewrites: records = appState.history.filter { $0.mode == .rewriteSelection }
        }
        if let limit = snapshot?.historyRecordLimit, records.count > limit {
            records = Array(records.prefix(limit))
        }
        return records
    }

    @ViewBuilder
    private var content: some View {
        let records = filteredRecords
        if appState.history.isEmpty {
            emptyState
        } else if records.isEmpty {
            Text(filter == .rewrites ? "No rewrites yet. Select some text, press \(appState.tzShortcutName) and say how to change it." : "Nothing here yet.")
                .font(.system(size: 15))
                .foregroundStyle(TZTheme.inkSecondary)
                .padding(.top, 8)
        } else {
            let groups = Self.groupByDay(records)
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(Array(groups.enumerated()), id: \.element.day) { groupIndex, group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(TZDateText.dayHeading(group.day))
                            .font(.system(size: 14))
                            .foregroundStyle(TZTheme.inkDay)
                        VStack(spacing: 0) {
                            ForEach(Array(group.records.enumerated()), id: \.element.id) { rowIndex, record in
                                TZHistoryRow(
                                    appState: appState,
                                    record: record,
                                    forceHover: (snapshot?.hoverFirstHistoryRow ?? false) && groupIndex == 0 && rowIndex == 0,
                                    startExpanded: (snapshot?.expandFirstHistoryRow ?? false) && groupIndex == 0 && rowIndex == 0,
                                    onAddWord: { addWordSheet = true }
                                )
                                if rowIndex < group.records.count - 1 {
                                    Rectangle().fill(TZTheme.border).frame(height: 1)
                                }
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(TZTheme.border, lineWidth: 1))
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(TZTheme.inkSecondary)
                .frame(width: 56, height: 56)
                .background(Circle().fill(TZTheme.panel))
            Text("No dictations yet")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(TZTheme.ink)
            VStack(spacing: 8) {
                Text("Press your shortcut in any app and start talking. Everything you dictate shows up here.")
                    .font(.system(size: 14))
                    .foregroundStyle(TZTheme.inkSecondary)
                    .multilineTextAlignment(.center)
                TZFlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(Array(appState.tzShortcutKeycaps.enumerated()), id: \.offset) { _, key in
                        TZKeycap(text: key)
                    }
                }
            }
            .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(TZTheme.border, lineWidth: 1))
    }

    static func groupByDay(_ records: [DictationRecord]) -> [(day: Date, records: [DictationRecord])] {
        let cal = TZStats.calendar
        var groups: [(day: Date, records: [DictationRecord])] = []
        for record in records {
            let day = cal.startOfDay(for: record.timestamp)
            if let last = groups.last, last.day == day {
                groups[groups.count - 1].records.append(record)
            } else {
                groups.append((day, [record]))
            }
        }
        return groups
    }
}

// MARK: - Row

struct TZHistoryRow: View {
    @ObservedObject var appState: AppState
    let record: DictationRecord
    var forceHover: Bool
    var onAddWord: () -> Void

    @State private var hovering = false
    @State private var expanded: Bool
    @State private var copied = false

    init(appState: AppState, record: DictationRecord, forceHover: Bool = false, startExpanded: Bool = false, onAddWord: @escaping () -> Void) {
        self.appState = appState
        self.record = record
        self.forceHover = forceHover
        self.onAddWord = onAddWord
        _expanded = State(initialValue: startExpanded)
    }

    private var showActions: Bool { hovering || forceHover }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(TZDateText.time(record.timestamp))
                        .font(.system(size: 14).monospacedDigit())
                        .foregroundStyle(TZTheme.inkMuted)
                    if record.mode == .rewriteSelection {
                        Text("Rewrite")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(TZTheme.blue)
                    }
                }
                .frame(width: 72, alignment: .leading)
                .padding(.top, 1)
                Text(record.polishedText)
                    .font(.system(size: 15))
                    .foregroundStyle(TZTheme.inkBody)
                    .lineSpacing(2)
                    .lineLimit(expanded ? nil : 3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if expanded {
                details
                    .padding(.leading, 72)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .topLeading)
        .background(showActions ? TZTheme.wash : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.14)) { expanded.toggle() }
        }
        .onHover { hovering = $0 }
        .overlay(alignment: .topTrailing) {
            // Always in the hierarchy (only faded), so an open "..." menu survives the pointer leaving the row.
            actions
                .padding(.top, 8)
                .padding(.trailing, 10)
                .opacity(showActions ? 1 : 0)
                .allowsHitTesting(showActions)
                .animation(.easeOut(duration: 0.1), value: showActions)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(metaLine)
                .font(.system(size: 12.5))
                .foregroundStyle(TZTheme.inkMuted)
            if record.rawTranscript != record.polishedText && !record.rawTranscript.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Raw transcript")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(TZTheme.inkSecondary)
                    Text(record.rawTranscript)
                        .font(.system(size: 13.5))
                        .foregroundStyle(TZTheme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(TZTheme.panel))
            }
        }
    }

    private var metaLine: String {
        var parts: [String] = [record.mode.displayName, TZStats.displayAppName(record.targetAppName)]
        parts.append(String(format: "%.1f s of speech", record.durationSeconds))
        if record.polishLatencyMs > 0 { parts.append("cleanup \(record.polishLatencyMs) ms") }
        return parts.joined(separator: " · ")
    }

    private var actions: some View {
        HStack(spacing: 2) {
            Button {
                TZClipboard.copy(record.polishedText)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(copied ? TZTheme.green : TZTheme.inkNav)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copy")
            .accessibilityLabel("Copy text")

            Menu {
                Button("Copy raw transcript") { TZClipboard.copy(record.rawTranscript) }
                    .disabled(record.rawTranscript.isEmpty)
                Button("Add word to Dictionary…") { onAddWord() }
                Divider()
                Button(role: .destructive) {
                    appState.tzDeleteHistoryRecord(record.id)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TZTheme.inkNav)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions")
        }
        .padding(.horizontal, 3)
        .background(
            TZCapsuleSurface(fill: Color.white, border: TZTheme.border)
                .shadow(color: Color.black.opacity(0.10), radius: 3, x: 0, y: 1)
        )
    }
}
