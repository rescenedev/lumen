import Foundation

/// A newer release than the running build, discovered via the GitHub Releases
/// API. `isBrewInstall` decides whether we point the user at `brew upgrade` or a
/// direct download — Lumen is distributed both ways.
struct UpdateInfo: Equatable, Sendable {
    let version: String          // e.g. "0.3.0"
    let releaseURL: URL
    let isBrewInstall: Bool

    /// The one-liner a Homebrew user runs to upgrade.
    static let brewUpgradeCommand = "brew upgrade --cask lumen-photos"
}

/// Checks GitHub Releases for a newer version. Notify-only: it never downloads
/// or installs (that would fight Homebrew's own version tracking) — it just
/// tells the user an update exists and how to get it.
enum UpdateChecker {
    private static let repo = "rescenedev/lumen"
    private static let latestAPI = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!

    /// The running app's marketing version (CFBundleShortVersionString).
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// True when this copy is managed by a Homebrew cask (Apple Silicon or Intel
    /// Caskroom). Determines which upgrade path we suggest.
    static var isBrewInstall: Bool {
        ["/opt/homebrew/Caskroom/lumen-photos", "/usr/local/Caskroom/lumen-photos"]
            .contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// Query the latest release; returns info only when it's newer than the
    /// running build. Network/parse failures resolve to nil (silent — an update
    /// check should never interrupt the user).
    static func check() async -> UpdateInfo? {
        var request = URLRequest(url: latestAPI, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return nil }

        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard isNewer(latest, than: currentVersion) else { return nil }

        let releaseURL = (json["html_url"] as? String).flatMap(URL.init)
            ?? URL(string: "https://github.com/\(repo)/releases/latest")!
        return UpdateInfo(version: latest, releaseURL: releaseURL, isBrewInstall: isBrewInstall)
    }

    /// Numeric, component-wise version comparison ("0.10.0" > "0.9.0").
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
