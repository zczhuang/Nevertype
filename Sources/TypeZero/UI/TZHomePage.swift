import SwiftUI
import AppKit

// MARK: - Home

struct TZHomePage: View {
    @ObservedObject var appState: AppState
    let snapshot: TZSnapshotOptions?
    @State private var monthOffset: Int

    init(appState: AppState, snapshot: TZSnapshotOptions?) {
        self.appState = appState
        self.snapshot = snapshot
        _monthOffset = State(initialValue: snapshot?.heatmapMonthOffset ?? 0)
    }

    var body: some View {
        let totals = TZStats.totals(appState.history)
        let activity = TZStats.activity(appState.history)

        VStack(alignment: .leading, spacing: 0) {
            Text("Welcome back")
                .font(.system(size: 52, weight: .bold))
                .tracking(-1)
                .foregroundStyle(TZTheme.ink)

            if !appState.micAuthorized || !appState.accessibilityGranted {
                TZPermissionBanner(appState: appState)
                    .padding(.top, 14)
            }

            Text("Insights")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(TZTheme.inkSecondary)
                .padding(.top, 16)

            insightsBlock(totals: totals, activity: activity)
                .padding(.top, 12)

            TZPracticePad(appState: appState)
                .padding(.top, 34)
        }
    }

    private func insightsBlock(totals: TZStats.Totals, activity: TZStats.Activity) -> some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(spacing: 15) {
                statGrid(totals: totals)
                TZActivityCard(activity: activity, monthOffset: $monthOffset)
            }
            .frame(maxWidth: .infinity)

            // Same height as the left column; the version footer sits at the bottom.
            VStack(alignment: .leading, spacing: 15) {
                TZShortcutsCard(appState: appState)
                TZTopAppsCard(apps: TZStats.topApps(appState.history, limit: 3))
                Spacer(minLength: 8)
                TZVersionFooter(version: appState.currentAppVersion)
            }
            .frame(width: 175)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(
            TZDotGrid()
                .padding(-14)
                .mask(RoundedRectangle(cornerRadius: 24, style: .continuous).padding(-14))
        )
    }

    private func statGrid(totals: TZStats.Totals) -> some View {
        let columns = [GridItem(.flexible(), spacing: 15), GridItem(.flexible(), spacing: 15)]
        return LazyVGrid(columns: columns, spacing: 15) {
            TZStatCard(parts: [(TZStats.formatCount(totals.words), "words")], caption: "Words dictated")
            TZStatCard(parts: TZStats.durationParts(minutes: totals.savedMinutes), caption: "Time saved")
            TZStatCard(parts: [("\(totals.wpm)", "WPM")], caption: "Average dictation speed")
            TZStatCard(parts: TZStats.durationParts(minutes: totals.dictationMinutes), caption: "Total dictation time")
        }
    }
}

// MARK: - Permission banner

/// Shown on Home while the microphone or accessibility permission is missing (dictation cannot work without them).
struct TZPermissionBanner: View {
    @ObservedObject var appState: AppState

    private var message: String {
        switch (appState.micAuthorized, appState.accessibilityGranted) {
        case (false, false): return "\(AppBrand.name) needs microphone and accessibility access to hear you and type for you."
        case (false, true): return "\(AppBrand.name) needs microphone access to hear you."
        default: return "\(AppBrand.name) needs accessibility access to type into other apps."
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(TZTheme.amber)
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(TZTheme.inkBody)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 8)
            Button("Grant access") { appState.requestAllPermissions() }
                .buttonStyle(.tzPrimaryCompact)
            Button("Details") { appState.selectedTab = .settings }
                .buttonStyle(.tzSecondaryCompact)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(TZTheme.amberTint))
    }
}

// MARK: - Stat card

/// Big number followed inline by its unit, with a caption underneath.
struct TZStatValue: View {
    let parts: [(value: String, unit: String)]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(part.value)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(TZTheme.ink)
                    Text(part.unit)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(TZTheme.ink)
                }
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

struct TZStatCard: View {
    let parts: [(value: String, unit: String)]
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            TZStatValue(parts: parts)
            Text(caption)
                .font(.system(size: 15))
                .foregroundStyle(TZTheme.inkSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, minHeight: 80, maxHeight: 80, alignment: .leading)
        .tzCard(radius: 16)
    }
}

// MARK: - Activity

struct TZActivityCard: View {
    let activity: TZStats.Activity
    @Binding var monthOffset: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 0) {
                statBlock(activity.activeDays, caption: "Active days")
                statBlock(activity.currentStreak, caption: "Current streak")
                statBlock(activity.longestStreak, caption: "Longest streak")
            }
            TZHeatmapView(activity: activity, monthOffset: $monthOffset)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tzCard(radius: 16)
    }

    private func statBlock(_ n: Int, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            TZStatValue(parts: [("\(n)", n == 1 ? "day" : "days")])
            Text(caption)
                .font(.system(size: 15))
                .foregroundStyle(TZTheme.inkSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TZHeatmapView: View {
    let activity: TZStats.Activity
    @Binding var monthOffset: Int

    private let cell: CGFloat = 18
    private let gap: CGFloat = 3
    private let labelWidth: CGFloat = 14
    private let labelGap: CGFloat = 8
    private let weekdayLetters = ["S", "M", "T", "W", "T", "F", "S"]

    private var gridHeight: CGFloat { 7 * cell + 6 * gap }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let available = geo.size.width - labelWidth - labelGap
                let columns = max(8, min(22, Int((available + gap) / (cell + gap))))
                let model = TZHeatmapModel.make(activity: activity, today: Date(), columns: columns, monthOffset: monthOffset)
                VStack(alignment: .leading, spacing: 7) {
                    gridRow(model: model)
                    monthRow(model: model, columns: columns)
                }
            }
            .frame(height: gridHeight + 7 + 20)

            legend
        }
    }

    private func gridRow(model: TZHeatmapModel) -> some View {
        HStack(alignment: .top, spacing: labelGap) {
            VStack(spacing: gap) {
                ForEach(0..<7, id: \.self) { row in
                    Text(weekdayLetters[row])
                        .font(.system(size: 11))
                        .foregroundStyle(TZTheme.inkMuted)
                        .frame(width: labelWidth, height: cell)
                }
            }
            HStack(spacing: gap) {
                ForEach(Array(model.columns.enumerated()), id: \.offset) { _, column in
                    VStack(spacing: gap) {
                        ForEach(column) { c in
                            TZHeatCellView(cell: c, size: cell)
                        }
                    }
                }
            }
        }
    }

    private func monthRow(model: TZHeatmapModel, columns: Int) -> some View {
        let gridOriginX = labelWidth + labelGap
        let gridWidth = CGFloat(columns) * cell + CGFloat(columns - 1) * gap
        return ZStack(alignment: .topLeading) {
            ForEach(Array(model.monthLabels.enumerated()), id: \.offset) { _, label in
                Text(label.text)
                    .font(.system(size: 12))
                    .foregroundStyle(TZTheme.inkSecondary)
                    .fixedSize()
                    .offset(x: gridOriginX + CGFloat(label.column) * (cell + gap), y: 0)
            }
            pagerButton(systemName: "chevron.left", enabled: model.canPageBack, label: "Earlier months") {
                monthOffset += 1
            }
            .offset(x: -2, y: -2)
            pagerButton(systemName: "chevron.right", enabled: model.canPageForward, label: "Later months") {
                monthOffset = max(0, monthOffset - 1)
            }
            .offset(x: gridOriginX + gridWidth - 12, y: -2)
        }
        .frame(width: gridOriginX + gridWidth + 4, height: 20, alignment: .topLeading)
    }

    private func pagerButton(systemName: String, enabled: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(enabled ? TZTheme.inkSecondary : TZTheme.inkMuted.opacity(0.4))
                .frame(width: 18, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private var legend: some View {
        HStack(spacing: 6) {
            Spacer()
            Text("Less")
                .font(.system(size: 13))
                .foregroundStyle(TZTheme.inkMuted)
            ForEach(1...4, id: \.self) { level in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(TZTheme.heat[level])
                    .frame(width: 14, height: 14)
            }
            Text("More")
                .font(.system(size: 13))
                .foregroundStyle(TZTheme.inkMuted)
        }
    }
}

struct TZHeatCellView: View {
    let cell: TZHeatmapModel.Cell
    let size: CGFloat

    var body: some View {
        Group {
            switch cell.kind {
            case .future:
                Color.clear
            case .beforeFirst:
                TZHatchCell()
            case .level(let level):
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(TZTheme.heat[level])
            }
        }
        .frame(width: size, height: size)
        .help(tooltip)
    }

    private var tooltip: String {
        switch cell.kind {
        case .future: return ""
        case .beforeFirst: return TZDateText.shortDate(cell.date)
        case .level:
            let noun = cell.count == 1 ? "dictation" : "dictations"
            return cell.count == 0 ? "No dictations · \(TZDateText.shortDate(cell.date))" : "\(cell.count) \(noun) · \(TZDateText.shortDate(cell.date))"
        }
    }
}

/// Diagonal light-grey stripes for days before the first dictation.
struct TZHatchCell: View {
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let shape = Path(roundedRect: rect, cornerRadius: 3, style: .continuous)
            context.fill(shape, with: .color(TZTheme.hatchBase))
            context.clip(to: shape)
            var stripes = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                stripes.move(to: CGPoint(x: x, y: size.height))
                stripes.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 4
            }
            context.stroke(stripes, with: .color(TZTheme.hatchStripe), lineWidth: 1.3)
        }
    }
}

// MARK: - Right column

struct TZShortcutsCard: View {
    @ObservedObject var appState: AppState

    var body: some View {
        let keys = appState.tzShortcutKeycaps
        VStack(alignment: .leading, spacing: 13) {
            Text("Shortcuts")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(TZTheme.ink)

            group(
                label: "Dictate",
                keys: keys,
                note: appState.triggerBehavior == .holdToTalk ? "Hold to talk" : "Tap to start and stop"
            )
            group(label: "Rewrite selection", keys: keys, note: "With text selected")
            group(label: "Cancel", keys: ["Esc"], note: nil)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tzPanel(radius: 16)
    }

    private func group(label: String, keys: [String], note: String?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(TZTheme.inkSecondary)
            TZFlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                    TZKeycap(text: key)
                }
            }
            if let note {
                Text(note)
                    .font(.system(size: 12.5))
                    .foregroundStyle(TZTheme.inkMuted)
                    .lineLimit(1)
            }
        }
    }
}

struct TZTopAppsCard: View {
    let apps: [(name: String, count: Int)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Top apps")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(TZTheme.ink)

            if apps.isEmpty {
                Text("Apps you dictate into will show up here.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(TZTheme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(apps.enumerated()), id: \.offset) { _, app in
                        HStack(spacing: 8) {
                            Text(String(app.name.prefix(1)).uppercased())
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(TZTheme.inkSecondary)
                                .frame(width: 22, height: 22)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white))
                                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(TZTheme.keycapBorder, lineWidth: 1))
                            Text(app.name)
                                .font(.system(size: 14))
                                .foregroundStyle(TZTheme.ink)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 4)
                            Text(TZStats.formatGrouped(app.count))
                                .font(.system(size: 14).monospacedDigit())
                                .foregroundStyle(TZTheme.inkSecondary)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tzPanel(radius: 16)
    }
}

struct TZVersionFooter: View {
    let version: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Version \(version)")
                .font(.system(size: 14))
                .foregroundStyle(TZTheme.inkMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Text("Automatic updates are off")
                .font(.system(size: 14))
                .foregroundStyle(TZTheme.inkMuted)
        }
    }
}

// MARK: - Practice pad

/// The in-app text box that receives dictation when this app itself is the frontmost app.
struct TZPracticePad: View {
    @ObservedObject var appState: AppState

    private var isRecordingNow: Bool {
        if case .listening = appState.phase { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Try it here")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(TZTheme.ink)
                    Text("Click the box, then use \(appState.tzShortcutName) or the button. In any other app, dictation types straight into the focused field.")
                        .font(.system(size: 14))
                        .foregroundStyle(TZTheme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if !appState.sandboxText.isEmpty {
                    Button("Clear") { appState.sandboxText = "" }
                        .buttonStyle(.tzSecondaryCompact)
                }
                Button {
                    if isRecordingNow {
                        Task { await appState.finishDictationSession() }
                    } else {
                        appState.beginDictationSession()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isRecordingNow ? "stop.fill" : "mic.fill")
                            .font(.system(size: 11))
                        Text(isRecordingNow ? "Stop" : "Start dictation")
                    }
                }
                .buttonStyle(.tzPrimaryCompact)
            }

            ZStack(alignment: .topLeading) {
                if appState.sandboxText.isEmpty {
                    Text("Try saying: “Let's do three things today. First, review the pull request. Second, update the docs. Third, ship the release.”")
                        .font(.system(size: 14))
                        .foregroundStyle(TZTheme.inkMuted)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $appState.sandboxText)
                    .font(.system(size: 14.5))
                    .foregroundStyle(TZTheme.ink)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .frame(minHeight: 96, maxHeight: 140)
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(TZTheme.panel))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isRecordingNow ? TZTheme.blue.opacity(0.6) : Color.clear, lineWidth: 1.5)
            )
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tzCard(radius: 16)
    }
}
