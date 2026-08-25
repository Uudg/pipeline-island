import AppKit

/// Checks GitHub for a newer release.
///
/// Read-only and opt-in: it never downloads or installs anything, it just
/// notices that a newer tag exists and points at the release page. Homebrew
/// does the actual upgrading.
@MainActor
enum UpdateCheck {
    private static let releasesURL = URL(string: "https://api.github.com/repos/Uudg/pipeline-island/releases/latest")
    private static let pageURL = URL(string: "https://github.com/Uudg/pipeline-island/releases/latest")

    private static let lastCheckKey = "update.lastCheck"
    private static let latestSeenKey = "update.latestSeen"

    /// Newest version seen on GitHub, when it is newer than this build.
    private(set) static var availableVersion: String?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// Check at most once a day, in the background, failing silently.
    static func checkIfDue() {
        let defaults = UserDefaults.standard
        let last = defaults.object(forKey: lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 86_400 else {
            // Surface a previously-seen update without hitting the network.
            if let seen = defaults.string(forKey: latestSeenKey), isNewer(seen, than: currentVersion) {
                availableVersion = seen
            }
            return
        }
        defaults.set(Date(), forKey: lastCheckKey)
        check()
    }

    /// Force a check now, ignoring the daily interval.
    static func check(completion: (@MainActor (String?) -> Void)? = nil) {
        guard let releasesURL else { completion?(nil); return }

        var request = URLRequest(url: releasesURL)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                Task { @MainActor in completion?(nil) }
                return
            }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            Task { @MainActor in
                UserDefaults.standard.set(version, forKey: latestSeenKey)
                availableVersion = isNewer(version, than: currentVersion) ? version : nil
                completion?(availableVersion)
            }
        }.resume()
    }

    static func openReleasePage() {
        guard let pageURL else { return }
        NSWorkspace.shared.open(pageURL)
    }

    /// Semantic-ish comparison. Falls back to string inequality for tags that
    /// are not three numbers.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").compactMap { Int($0) }
        let b = current.split(separator: ".").compactMap { Int($0) }
        guard a.count == 3, b.count == 3 else { return candidate != current }
        for (lhs, rhs) in zip(a, b) where lhs != rhs { return lhs > rhs }
        return false
    }
}
