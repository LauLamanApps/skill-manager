import Foundation

enum CatalogStoreError: LocalizedError {
    /// `catalogs.json` exists but could not be read or decoded.
    case unreadable(String)
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let detail):
            return "Could not read catalogs.json (\(detail)). "
                + "The catalog list is empty until the file is fixed or removed."
        case .saveFailed(let detail):
            return "Could not save catalogs.json: \(detail)"
        }
    }
}

/// On-disk home of the catalog list.
///
/// ```
/// Application Support/SkillManager/
///   catalogs.json          ordered list of catalogs
///   catalogs/<slug>/       one git clone per catalog
///   catalog/               legacy single clone, migrated away on first launch
/// ```
enum CatalogStore {
    static let supportDir = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    )[0].appendingPathComponent("SkillManager")

    static var rootDir: URL { supportDir.appendingPathComponent("catalogs") }
    static var fileURL: URL { supportDir.appendingPathComponent("catalogs.json") }
    /// Pre-multi-catalog location of the single clone.
    static var legacyCloneDir: URL { supportDir.appendingPathComponent("catalog") }

    static func directory(for catalog: Catalog) -> URL {
        rootDir.appendingPathComponent(catalog.slug)
    }

    // MARK: - Persistence

    /// The stored list, or `[]` when the file does not exist yet. Throws only
    /// when a file *is* there but unusable — the caller must not overwrite it in
    /// that case, or a typo in the JSON would silently drop every catalog.
    static func load() throws -> [Catalog] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            return try JSONDecoder().decode([Catalog].self, from: Data(contentsOf: fileURL))
        } catch {
            throw CatalogStoreError.unreadable(error.localizedDescription)
        }
    }

    static func save(_ catalogs: [Catalog]) throws {
        do {
            try FileManager.default.createDirectory(
                at: supportDir, withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(catalogs).write(to: fileURL, options: .atomic)
        } catch {
            throw CatalogStoreError.saveFailed(error.localizedDescription)
        }
    }

    // MARK: - Migration

    /// The `origin` remote recorded in a clone's `.git/config`.
    ///
    /// Read straight from the file rather than shelling out to git: the
    /// migration runs synchronously at startup, and the clone is the one source
    /// that cannot disagree with what is actually on disk. The `catalogRepoURL`
    /// preference can — it lives under a different domain for the dev binary
    /// than for the .app bundle, so it may read back empty.
    static func originURL(ofCloneAt dir: URL) -> String? {
        guard let config = try? String(
            contentsOf: dir.appendingPathComponent(".git/config"), encoding: .utf8
        ) else { return nil }
        var inOrigin = false
        for rawLine in config.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inOrigin = line.replacingOccurrences(of: " ", with: "") == "[remote\"origin\"]"
                continue
            }
            guard inOrigin, let eq = line.firstIndex(of: "="),
                  line[..<eq].trimmingCharacters(in: .whitespaces) == "url" else { continue }
            let url = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            return url.isEmpty ? nil : url
        }
        return nil
    }

    /// Loads the list, migrating the legacy single clone into it on first run.
    ///
    /// Idempotent: an existing `catalogs.json` means the migration already ran,
    /// so this degrades to a plain `load()`. With neither a legacy clone nor a
    /// configured URL there is nothing to migrate and no file is written — a
    /// fresh install starts with an empty list.
    static func loadOrMigrate(legacyRepoURL: String) throws -> [Catalog] {
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) { return try load() }

        let hasLegacyClone = fm.fileExists(atPath: legacyCloneDir.path)
        // The clone's own remote wins over the preference, which is unreliable.
        let repoURL = (hasLegacyClone ? originURL(ofCloneAt: legacyCloneDir) : nil)
            ?? legacyRepoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasLegacyClone || !repoURL.isEmpty else { return [] }

        let catalog = Catalog.fromRepoURL(repoURL)
        if hasLegacyClone {
            let dest = directory(for: catalog)
            // A leftover destination means a previous run moved the clone but
            // died before writing the list — keep the newer copy, drop nothing.
            if !fm.fileExists(atPath: dest.path) {
                try fm.createDirectory(at: rootDir, withIntermediateDirectories: true)
                try fm.moveItem(at: legacyCloneDir, to: dest)
            }
        }
        try save([catalog])
        return [catalog]
    }
}
