import Foundation

enum SkillSource: String, Hashable {
    case catalog
    case installed
}

struct Skill: Identifiable, Hashable {
    let name: String
    let description: String
    let version: String?
    let tags: [String]
    /// Subfolder of the skill inside its source root ("" for top-level skills).
    let folder: String
    let path: URL
    let source: SkillSource
    /// For a catalog skill, the catalog it was scanned from. For an installed
    /// skill, the catalog it was installed from (read from the `catalog:`
    /// frontmatter marker); nil when the copy predates origin tracking.
    let catalogID: UUID?
    /// Advisory SKILL.md problems found while scanning; see `SkillHealth`.
    let issues: [SkillIssue]
    /// SKILL.md content after the frontmatter block, for full-text search.
    let bodyText: String

    /// Includes the catalog, so the same skill name in two catalogs stays two
    /// distinct rows.
    var id: String {
        let path = folder.isEmpty ? name : "\(folder)/\(name)"
        guard let catalogID else { return "\(source.rawValue):\(path)" }
        return "\(source.rawValue):\(catalogID.uuidString):\(path)"
    }

    var skillFile: URL { path.appendingPathComponent("SKILL.md") }
}

/// Compares dotted version strings numerically (1.2.10 > 1.2.9).
/// Missing components count as 0; non-numeric components compare as strings.
func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
    let aParts = a.split(separator: ".").map(String.init)
    let bParts = b.split(separator: ".").map(String.init)
    for i in 0..<max(aParts.count, bParts.count) {
        let x = i < aParts.count ? aParts[i] : "0"
        let y = i < bParts.count ? bParts[i] : "0"
        if let xi = Int(x), let yi = Int(y) {
            if xi != yi { return xi < yi ? .orderedAscending : .orderedDescending }
        } else if x != y {
            return x < y ? .orderedAscending : .orderedDescending
        }
    }
    return .orderedSame
}
