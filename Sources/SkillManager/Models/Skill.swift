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

    var id: String { "\(source.rawValue):\(folder.isEmpty ? name : "\(folder)/\(name)")" }

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
