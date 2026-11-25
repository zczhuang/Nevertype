import Foundation

/// There is no updater. Nothing is downloaded or installed, and no request is ever made to look for a newer version: new
/// versions are published on the project's GitHub page (`AppBrand.releasesURL`) and are installed by hand.
///
/// The upstream project this app is based on shipped an updater that read a version manifest from its own server and swapped
/// the running app for a downloaded DMG. It was removed on purpose, so no code path in this app can fetch or install an
/// upstream TypeZero release (or any other).
public enum AppUpdater {
    /// Always false: there is no automatic updating.
    public static let isUpdaterEnabled = false

    /// The version shown in Settings, the setup guide and the menu.
    public static var currentAppVersion: String {
        AppBrand.version
    }

    /// What a manual "Check for Updates" tells the user instead of checking anything.
    public static var manualCheckMessage: String {
        "Automatic updates are off. New versions of \(AppBrand.name) are published on the project's GitHub page "
            + "(\(AppBrand.releasesDisplayString)). You are on v\(currentAppVersion)."
    }

    /// Semantic version comparator: returns `true` iff `remote` is strictly newer than `current` (e.g. "0.5.6" > "0.5.5").
    public static func isNewerVersion(_ remote: String, than current: String) -> Bool {
        func parseParts(_ v: String) -> [Int] {
            let cleaned = v.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let core = cleaned.split(separator: "-", maxSplits: 1).first.map(String.init) ?? cleaned
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let r = parseParts(remote)
        let c = parseParts(current)
        let count = max(r.count, c.count)
        guard count > 0 else { return false }
        for i in 0..<count {
            let rv = i < r.count ? r[i] : 0
            let cv = i < c.count ? c[i] : 0
            if rv != cv {
                return rv > cv
            }
        }
        return false
    }
}
