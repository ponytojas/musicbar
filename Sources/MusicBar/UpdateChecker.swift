import Foundation

/// Looks for a newer release on GitHub. It only reads the latest release's
/// tag; installing is left to the user, who is sent to the release page.
enum UpdateChecker {
    static let releasePage = URL(string: "https://github.com/ponytojas/musicbar/releases/latest")!
    private static let latestRelease = URL(string: "https://api.github.com/repos/ponytojas/musicbar/releases/latest")!
    private static let lastCheckKey = "lastUpdateCheck"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// The latest released version when it's newer than this build, nil
    /// when up to date. Throws when the answer couldn't be fetched.
    static func availableUpdate() async throws -> String? {
        var request = URLRequest(url: latestRelease, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String
        else { throw URLError(.badServerResponse) }
        UserDefaults.standard.set(Date(), forKey: lastCheckKey)
        return isNewer(tag, than: currentVersion) ? normalized(tag) : nil
    }

    /// Automatic checks run at most once a day.
    static func isAutomaticCheckDue(now: Date = Date()) -> Bool {
        guard let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date else { return true }
        return now.timeIntervalSince(last) >= 24 * 60 * 60
    }

    /// "v1.10" is newer than "1.9": components compare as numbers, and a
    /// missing component counts as zero.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let lhs = components(candidate)
        let rhs = components(current)
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    static func normalized(_ version: String) -> String {
        version.hasPrefix("v") ? String(version.dropFirst()) : version
    }

    private static func components(_ version: String) -> [Int] {
        normalized(version).split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }
}
