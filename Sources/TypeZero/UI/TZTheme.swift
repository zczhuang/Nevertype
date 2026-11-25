import SwiftUI
import AppKit

// MARK: - Design tokens
//
// Neutral, light-only palette for the main window. Sizes elsewhere in the UI are in points.

extension Color {
    /// sRGB colour from a 24-bit hex literal, e.g. `Color(hex: 0x2B63F0)`.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: opacity
        )
    }
}

enum TZTheme {
    // Surfaces
    static let canvas = Color.white
    static let sidebar = Color(hex: 0xF5F5F6)
    static let panel = Color(hex: 0xF4F4F6)
    static let wash = Color(hex: 0xF7F7F8)
    static let navSelected = Color(hex: 0xE7E7EA)
    static let segmentTrack = Color(hex: 0xF0F0F2)
    static let border = Color(hex: 0xEDEDEF)
    static let keycapBorder = Color(hex: 0xE3E3E6)
    static let hairline = Color(hex: 0xE4E4E8)
    static let dot = Color(hex: 0xE6E6E9)
    static let switchOff = Color(hex: 0xD6D6DB)

    // Ink
    static let ink = Color(hex: 0x111111)
    static let inkNav = Color(hex: 0x2B2B2B)
    static let inkBody = Color(hex: 0x222222)
    static let inkDay = Color(hex: 0x555555)
    static let inkSecondary = Color(hex: 0x6B6B70)
    static let inkMuted = Color(hex: 0x9A9AA0)

    // Accent
    static let blue = Color(hex: 0x2B63F0)
    static let blueTint = Color(hex: 0xE6EDFE)
    static let teal = Color(hex: 0x12B5A0)

    // Status
    static let green = Color(hex: 0x1E9E5A)
    static let greenTint = Color(hex: 0xE3F4EA)
    static let amber = Color(hex: 0xB86E00)
    static let amberTint = Color(hex: 0xFDF1DC)
    static let red = Color(hex: 0xD93F3F)
    static let redTint = Color(hex: 0xFCE8E8)

    // Activity heatmap: [no activity, level 1...4]
    static let heat: [Color] = [
        Color(hex: 0xF1F2F5), Color(hex: 0xE3EBFD), Color(hex: 0xC3D4FB), Color(hex: 0x93B0F7), Color(hex: 0x2B63F0)
    ]
    static let hatchBase = Color(hex: 0xF7F7F8)
    static let hatchStripe = Color(hex: 0xECECEF)
}

// MARK: - Surfaces

extension View {
    /// White card: 1 pt border, soft shadow.
    func tzCard(radius: CGFloat = 16, fill: Color = .white) -> some View {
        self
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(TZTheme.border, lineWidth: 1))
            .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 1)
    }

    /// Flat grey panel (no border, no shadow).
    func tzPanel(radius: CGFloat = 14) -> some View {
        self.background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(TZTheme.panel))
    }

    /// Single-line text input that sits on white or grey surfaces.
    func tzField(height: CGFloat = 34, fill: Color = .white) -> some View {
        self
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .foregroundStyle(TZTheme.ink)
            .padding(.horizontal, 11)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(TZTheme.keycapBorder, lineWidth: 1))
    }
}

// MARK: - Capsule surface

/// Capsule fill with an optional 1 pt border built from two fills (stroking a capsule leaves stub artifacts in
/// offscreen snapshots).
struct TZCapsuleSurface: View {
    let fill: Color
    var border: Color? = nil

    var body: some View {
        ZStack {
            if let border {
                Capsule().fill(border)
                Capsule().fill(fill).padding(1)
            } else {
                Capsule().fill(fill)
            }
        }
    }
}

// MARK: - Buttons

struct TZButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive, ghost }

    var kind: Kind = .secondary
    var compact: Bool = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(.system(size: compact ? 13 : 14, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, compact ? 12 : 15)
            .padding(.vertical, compact ? 5.5 : 8)
            .background(TZCapsuleSurface(
                fill: background(pressed: pressed),
                border: (kind == .secondary || kind == .destructive) ? borderColor : nil
            ))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
    }

    private var foreground: Color {
        switch kind {
        case .primary: return .white
        case .secondary: return TZTheme.ink
        case .destructive: return TZTheme.red
        case .ghost: return TZTheme.inkSecondary
        }
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .primary: return pressed ? Color(hex: 0x333333) : TZTheme.ink
        case .secondary, .destructive: return pressed ? TZTheme.segmentTrack : .white
        case .ghost: return pressed ? TZTheme.segmentTrack : .clear
        }
    }

    private var borderColor: Color {
        kind == .destructive ? TZTheme.red.opacity(0.3) : TZTheme.keycapBorder
    }
}

extension ButtonStyle where Self == TZButtonStyle {
    static var tzPrimary: TZButtonStyle { TZButtonStyle(kind: .primary) }
    static var tzSecondary: TZButtonStyle { TZButtonStyle(kind: .secondary) }
    static var tzDestructive: TZButtonStyle { TZButtonStyle(kind: .destructive) }
    static var tzGhost: TZButtonStyle { TZButtonStyle(kind: .ghost) }
    static var tzPrimaryCompact: TZButtonStyle { TZButtonStyle(kind: .primary, compact: true) }
    static var tzSecondaryCompact: TZButtonStyle { TZButtonStyle(kind: .secondary, compact: true) }
    static var tzDestructiveCompact: TZButtonStyle { TZButtonStyle(kind: .destructive, compact: true) }
    static var tzGhostCompact: TZButtonStyle { TZButtonStyle(kind: .ghost, compact: true) }
}

/// 30 pt circular icon button (used for the "…" menus and search).
struct TZCircleButtonLabel: View {
    let systemName: String
    var size: CGFloat = 32
    var active: Bool = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(active ? TZTheme.blue : TZTheme.inkNav)
            .frame(width: size, height: size)
            .background(Circle().fill(active ? TZTheme.blueTint : TZTheme.segmentTrack))
            .contentShape(Circle())
    }
}

// MARK: - Switch

struct TZSwitchStyle: ToggleStyle {
    /// When true the label sits on the left and the switch is pushed to the trailing edge.
    var expands: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.label
            if expands { Spacer(minLength: 12) }
            Button {
                withAnimation(.easeOut(duration: 0.12)) { configuration.isOn.toggle() }
            } label: {
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? TZTheme.blue : TZTheme.switchOff)
                    Circle()
                        .fill(Color.white)
                        .shadow(color: Color.black.opacity(0.18), radius: 1.5, x: 0, y: 1)
                        .padding(2)
                }
                .frame(width: 38, height: 22)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Segmented control (capsule)

struct TZSegmentedControl<Value: Hashable>: View {
    struct Item {
        let value: Value
        let title: String
        var icon: String? = nil
        var iconColor: Color? = nil
    }

    let items: [Item]
    @Binding var selection: Value
    var fontSize: CGFloat = 15
    var fill: Bool = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let selected = item.value == selection
                Button {
                    withAnimation(.easeOut(duration: 0.14)) { selection = item.value }
                } label: {
                    HStack(spacing: 6) {
                        if let icon = item.icon {
                            Image(systemName: icon)
                                .font(.system(size: fontSize - 2.5, weight: .semibold))
                                .foregroundStyle(item.iconColor ?? TZTheme.inkSecondary)
                        }
                        Text(item.title)
                            .font(.system(size: fontSize, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? TZTheme.ink : TZTheme.inkSecondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, fontSize >= 15 ? 6.5 : 5)
                    .frame(maxWidth: fill ? .infinity : nil)
                    .background(
                        Capsule()
                            .fill(selected ? Color.white : Color.clear)
                            .shadow(color: selected ? Color.black.opacity(0.10) : .clear, radius: 2, x: 0, y: 1)
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(TZTheme.segmentTrack))
    }
}

// MARK: - Keycaps

struct TZKeycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(TZTheme.ink)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(TZTheme.keycapBorder, lineWidth: 1))
            .shadow(color: Color.black.opacity(0.07), radius: 0, x: 0, y: 1.5)
    }
}

/// Wraps its children onto new lines when they do not fit the proposed width.
struct TZFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, usedWidth: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += rowHeight + lineSpacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            usedWidth = max(usedWidth, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width != nil ? min(usedWidth, maxWidth) : usedWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + lineSpacing
                x = bounds.minX
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Badges, dots, progress

struct TZBadge: View {
    enum Tone { case neutral, blue, green, amber, red }

    let text: String
    var tone: Tone = .neutral
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon).font(.system(size: 10.5, weight: .bold))
            }
            Text(text).font(.system(size: 12, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(background))
    }

    private var foreground: Color {
        switch tone {
        case .neutral: return TZTheme.inkSecondary
        case .blue: return TZTheme.blue
        case .green: return TZTheme.green
        case .amber: return TZTheme.amber
        case .red: return TZTheme.red
        }
    }

    private var background: Color {
        switch tone {
        case .neutral: return TZTheme.segmentTrack
        case .blue: return TZTheme.blueTint
        case .green: return TZTheme.greenTint
        case .amber: return TZTheme.amberTint
        case .red: return TZTheme.redTint
        }
    }
}

struct TZStatusDot: View {
    enum Tone { case green, amber, red, gray }
    let tone: Tone
    var size: CGFloat = 7

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }

    private var color: Color {
        switch tone {
        case .green: return TZTheme.green
        case .amber: return Color(hex: 0xE59A1F)
        case .red: return TZTheme.red
        case .gray: return TZTheme.inkMuted.opacity(0.6)
        }
    }
}

struct TZProgressBar: View {
    let value: Double
    var tint: Color = TZTheme.blue

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(TZTheme.segmentTrack)
                Capsule().fill(tint).frame(width: max(4, geo.size.width * CGFloat(min(1, max(0, value)))))
            }
        }
        .frame(height: 6)
    }
}

// MARK: - Settings building blocks

/// Grey panel that holds settings rows separated by hairlines (same look as the History info panel).
struct TZPanelStack<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tzPanel(radius: 14)
    }
}

struct TZRowDivider: View {
    var body: some View {
        Rectangle().fill(TZTheme.hairline).frame(height: 1).padding(.vertical, 12)
    }
}

/// Title + optional description on the left, control on the right.
struct TZSettingRow<Trailing: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(TZTheme.ink)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 14))
                        .foregroundStyle(TZTheme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
    }
}

struct TZSectionHeader: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(TZTheme.ink)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 14))
                    .foregroundStyle(TZTheme.inkSecondary)
            }
        }
    }
}

/// Large page title (History / Dictionary / Settings).
struct TZPageTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 44, weight: .bold))
            .tracking(-0.8)
            .foregroundStyle(TZTheme.ink)
    }
}

/// Dotted canvas drawn behind the Home insights block (1 pt dots every 10 pt).
struct TZDotGrid: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            var y: CGFloat = 5
            while y < size.height {
                var x: CGFloat = 5
                while x < size.width {
                    path.addRect(CGRect(x: x, y: y, width: 1, height: 1))
                    x += 10
                }
                y += 10
            }
            context.fill(path, with: .color(TZTheme.dot))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Status message parsing

/// Status strings coming from AppState carry a leading emoji (✅ / ⚠️ / ❌). The UI shows a matching SF Symbol instead.
struct TZStatusMessage {
    enum Tone { case info, success, warning, error }

    let tone: Tone
    let text: String

    static func parse(_ raw: String) -> TZStatusMessage {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var tone: Tone = .info
        let markers: [(String, Tone)] = [("✅", .success), ("⚠️", .warning), ("❌", .error), ("⚠", .warning)]
        var matched = false
        for (marker, t) in markers where s.hasPrefix(marker) {
            tone = t
            s = String(s.dropFirst(marker.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            matched = true
            break
        }
        if !matched {
            // Any other leading emoji (✈️ ⚡ 🎁 …) is replaced by the neutral info icon.
            while let first = s.unicodeScalars.first, first.value > 0x238C, first.properties.isEmoji || first.value == 0xFE0F {
                s = String(s.unicodeScalars.dropFirst())
            }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return TZStatusMessage(tone: tone, text: s)
    }

    var icon: String {
        switch tone {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch tone {
        case .info: return TZTheme.blue
        case .success: return TZTheme.green
        case .warning: return TZTheme.amber
        case .error: return TZTheme.red
        }
    }

    var tint: Color {
        switch tone {
        case .info: return TZTheme.blueTint
        case .success: return TZTheme.greenTint
        case .warning: return TZTheme.amberTint
        case .error: return TZTheme.redTint
        }
    }
}

/// Inline banner for probe results, warnings and status text.
struct TZInlineMessage: View {
    let message: String
    var forceTone: TZStatusMessage.Tone? = nil

    var body: some View {
        let parsed = TZStatusMessage.parse(message)
        let tone = forceTone ?? parsed.tone
        let shown = TZStatusMessage(tone: tone, text: parsed.text)
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: shown.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(shown.color)
                .padding(.top, 1)
            Text(shown.text)
                .font(.system(size: 13))
                .foregroundStyle(TZTheme.inkBody)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(shown.tint))
    }
}

// MARK: - Menu field

/// White field that opens a menu of choices (replaces the system pop-up button).
struct TZMenuField<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    var height: CGFloat = 34

    private var currentTitle: String {
        options.first(where: { $0.value == selection })?.title ?? ""
    }

    var body: some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button {
                    selection = option.value
                } label: {
                    if option.value == selection {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(currentTitle)
                    .font(.system(size: 14))
                    .foregroundStyle(TZTheme.ink)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(TZTheme.inkMuted)
            }
            .padding(.horizontal, 11)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(TZTheme.keycapBorder, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }
}
