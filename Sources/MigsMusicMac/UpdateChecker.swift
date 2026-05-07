import Foundation

struct AvailableUpdate: Equatable {
    let version: String
    let releaseURL: URL
}

/// Three-state outcome so the caller can distinguish a successful "no update" check
/// (which counts toward the API rate-limit throttle) from a network failure
/// (which should not — otherwise a one-off connectivity hiccup silences the check
/// for hours).
enum UpdateCheckResult {
    case update(AvailableUpdate)
    case upToDate
    case failed
}

/// Polls GitHub Releases for newer published versions of this app. Defensive by design:
/// any parse error or unexpected response is treated as `.failed` rather than surfaced
/// — a broken update check should never alarm the user, who can always update manually.
enum UpdateChecker {
    static func check() async -> UpdateCheckResult {
        guard
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            let url = URL(string: latestReleaseAPI)
        else { return .failed }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse, http.statusCode == 200,
            let payload = try? JSONDecoder().decode(LatestRelease.self, from: data)
        else { return .failed }

        let raw = payload.tag_name
        let latest = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        guard isNewer(latest: latest, current: current) else { return .upToDate }
        guard let releaseURL = URL(string: payload.html_url) else { return .upToDate }
        return .update(AvailableUpdate(version: latest, releaseURL: releaseURL))
    }

    /// Numeric per-component semver compare. Missing components count as 0 so "1.2" == "1.2.0".
    static func isNewer(latest: String, current: String) -> Bool {
        let a = latest.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av != bv { return av > bv }
        }
        return false
    }

    private static let latestReleaseAPI =
        "https://api.github.com/repos/michaelhball/migs-music-mac/releases/latest"

    private struct LatestRelease: Decodable {
        let tag_name: String
        let html_url: String
    }
}
