import Foundation

/// The app's public identity, in one place: the name users see, the bundle identifier, the version and the folder their data lives in.
///
/// The code is MIT-licensed upstream TypeZero code, but the TypeZero name is not part of that licence, so everything a user
/// sees says `name`. The Swift module, target and product are still called `TypeZero` (see `Package.swift`); only the
/// `.app` built by `scripts/build-app.sh` is called `Nevertype`. That script reads `name`, `bundleID` and `version` from this
/// file, so keep each of them a plain string literal on its own line.
public enum AppBrand {
    public static let name = "Nevertype"
    public static let bundleID = "io.github.zczhuang.nevertype"
    public static let version = "0.1.0"

    /// Where the project lives and where new versions are published (the updater is off, see `AppUpdater`).
    public static let repositoryURL = URL(string: "https://github.com/zczhuang/Nevertype")!
    public static let releasesURL = URL(string: "https://github.com/zczhuang/Nevertype/releases")!

    /// `github.com/zczhuang/Nevertype` and `github.com/zczhuang/Nevertype/releases`, for display.
    public static var repositoryDisplayString: String { displayString(repositoryURL) }
    public static var releasesDisplayString: String { displayString(releasesURL) }

    private static func displayString(_ url: URL) -> String {
        (url.host ?? "") + url.path
    }

    /// Attribution for the upstream project this app is based on.
    public static let upstreamName = "TypeZero"
    public static let upstreamRepositoryURL = URL(string: "https://github.com/nasadunadu/TypeZero")!
    public static let upstreamAttribution = "Based on TypeZero (MIT)"

    /// `~/Library/Application Support/Nevertype`: history, config, dictionary, speech models and logs live here.
    /// Pure: it does not create the folder, callers do that when they write.
    public static func applicationSupportDirectory(fileManager: FileManager = .default) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent(name, isDirectory: true)
    }
}
