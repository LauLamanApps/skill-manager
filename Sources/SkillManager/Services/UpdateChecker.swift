import Foundation

struct ReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: URL
    let size: Int

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case size
    }
}

struct Release: Decodable {
    let tagName: String
    let name: String
    let htmlURL: URL
    let publishedAt: Date
    let assets: [ReleaseAsset]
    /// Release notes body, as Markdown, straight from the GitHub release.
    let body: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case assets
        case body
    }

    var dmgAsset: ReleaseAsset? {
        assets.first { $0.name.hasSuffix(".dmg") }
    }
}

enum UpdateCheckResult {
    case upToDate
    case available(Release, dmgURL: URL)
    case failed(Error)
}

enum UpdateCheckError: LocalizedError {
    case noDMGAsset
    case badResponse

    var errorDescription: String? {
        switch self {
        case .noDMGAsset: return "Latest release has no .dmg asset."
        case .badResponse: return "GitHub releases API returned an unexpected response."
        }
    }
}

struct UpdateChecker {
    static let releasesURL = URL(
        string: "https://api.github.com/repos/LauLamanApps/skill-manager/releases/latest"
    )!

    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchLatest() async throws -> Release {
        var request = URLRequest(url: Self.releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SkillManager", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw UpdateCheckError.badResponse
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Release.self, from: data)
    }

    /// Component-wise numeric compare so `0.10.0 > 0.9.0` (a string compare gets this wrong).
    func compare(current: String, latest: String) -> ComparisonResult {
        let currentParts = current.hasPrefix("v") ? String(current.dropFirst()) : current
        let latestParts = latest.hasPrefix("v") ? String(latest.dropFirst()) : latest

        let currentComponents = currentParts.split(separator: ".").map { Int($0) ?? 0 }
        let latestComponents = latestParts.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(currentComponents.count, latestComponents.count)

        for i in 0..<count {
            let c = i < currentComponents.count ? currentComponents[i] : 0
            let l = i < latestComponents.count ? latestComponents[i] : 0
            if c != l {
                return c < l ? .orderedAscending : .orderedDescending
            }
        }
        return .orderedSame
    }

    func check() async -> UpdateCheckResult {
        // A bare `swift run` binary has no version — treat that as a dev build, no update.
        guard let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              !currentVersion.isEmpty else {
            return .upToDate
        }

        do {
            let release = try await fetchLatest()
            guard case .orderedAscending = compare(current: currentVersion, latest: release.tagName) else {
                return .upToDate
            }
            guard let dmgURL = release.dmgAsset?.browserDownloadURL else {
                return .failed(UpdateCheckError.noDMGAsset)
            }
            return .available(release, dmgURL: dmgURL)
        } catch {
            return .failed(error)
        }
    }
}
