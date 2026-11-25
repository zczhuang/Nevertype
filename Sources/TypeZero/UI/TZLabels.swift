import Foundation
import SwiftUI

// MARK: - English UI labels
//
// Several model enums carry persisted raw values (and some display strings) that are not English. The main window
// never displays those; it uses the labels below instead. Raw values are untouched.

extension SidebarTab {
    var tzTitle: String {
        switch self {
        case .home: return "Home"
        case .history: return "History"
        case .dictionary: return "Dictionary"
        case .settings: return "Settings"
        }
    }

    var tzIcon: String {
        switch self {
        case .home: return "house"
        case .history: return "clock.arrow.circlepath"
        case .dictionary: return "book.closed"
        case .settings: return "gearshape"
        }
    }

    /// Tabs shown as rows in the sidebar (Settings lives behind the gear).
    static var tzNavTabs: [SidebarTab] { [.home, .history, .dictionary] }
}

extension LexiconCategory {
    // Labels come from `displayName` (Models.swift); the raw values are persisted and Chinese, so never show them.

    /// Words with this category were added automatically; everything else was added by hand.
    var tzIsAuto: Bool { self == .autoLearned }

    /// Categories a person can pick for a hand-written entry.
    static var tzManualCases: [LexiconCategory] {
        allCases.filter { $0 != .autoLearned }
    }
}

extension TriggerKeyOption {
    /// Full name, e.g. "Right Option".
    var tzLabel: String {
        switch self {
        case .fnKey: return "Fn"
        case .leftOption: return "Left Option"
        case .rightOption: return "Right Option"
        case .leftCommand: return "Left Command"
        case .rightCommand: return "Right Command"
        case .leftControl: return "Left Control"
        case .rightControl: return "Right Control"
        case .leftShift: return "Left Shift"
        case .rightShift: return "Right Shift"
        case .optionSpace: return "Option + Space"
        case .custom: return "Custom shortcut"
        }
    }

    /// Keycaps for a preset (custom shortcuts are split from their stored label instead).
    var tzKeycaps: [String] {
        switch self {
        case .optionSpace: return ["Option", "Space"]
        case .custom: return ["Custom"]
        default: return [tzLabel]
        }
    }
}

extension LocalASRModel {
    /// "Parakeet" / "SenseVoice" without the version, for use inside sentences.
    var tzFamilyName: String {
        switch self {
        case .parakeetTDTv2: return "Parakeet"
        case .senseVoice: return "SenseVoice"
        }
    }
}

extension TriggerBehavior {
    var tzLabel: String {
        switch self {
        case .tapToggle: return "Tap to start and stop"
        case .holdToTalk: return "Hold to talk"
        }
    }

    var tzDetail: String {
        switch self {
        case .tapToggle: return "Tap once to start, tap again to finish"
        case .holdToTalk: return "Hold while you speak, release to finish"
        }
    }
}

extension FormattingStyle {
    var tzLabel: String {
        switch self {
        case .structured: return "Structured"
        case .lightPolish: return "Light"
        case .verbatimLocal: return "Verbatim"
        }
    }

    var tzDetail: String {
        switch self {
        case .structured: return "Fixes grammar and organizes what you said into paragraphs and numbered lists."
        case .lightPolish: return "Removes filler words and fixes typos, but keeps your sentences as spoken."
        case .verbatimLocal: return "No cleanup model. Your words are inserted as transcribed, with dictionary fixes only."
        }
    }
}

extension AppState {
    /// Keycaps for the dictation shortcut currently in effect.
    var tzShortcutKeycaps: [String] {
        if triggerKey == .custom {
            return TZShortcutText.keycaps(fromCustomLabel: customHotkey.label)
        }
        return triggerKey.tzKeycaps
    }

    /// Readable name of the current dictation shortcut, e.g. "Right Option" or "⌃ + Space".
    var tzShortcutName: String {
        triggerKey == .custom ? customHotkey.label : triggerKey.tzLabel
    }
}

enum TZShortcutText {
    /// "⌃ + Space" -> ["⌃", "Space"]
    static func keycaps(fromCustomLabel label: String) -> [String] {
        let parts = label
            .components(separatedBy: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? [label] : parts
    }
}

enum TZDateText {
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    /// "3:07 PM"
    static func time(_ date: Date) -> String { formatter("h:mm a").string(from: date) }

    /// "November 17, 2026"
    static func longDate(_ date: Date) -> String { formatter("MMMM d, yyyy").string(from: date) }

    /// "Mon, Nov 17"
    static func shortDate(_ date: Date) -> String { formatter("EEE, MMM d").string(from: date) }

    /// "Today", "Yesterday" or the long date.
    static func dayHeading(_ day: Date, now: Date = Date()) -> String {
        let cal = TZStats.calendar
        if cal.isDate(day, inSameDayAs: now) { return "Today" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(day, inSameDayAs: y) { return "Yesterday" }
        return longDate(day)
    }
}
