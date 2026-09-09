import Foundation

struct SkillMeta {
    var name: String?
    var description: String?
    var version: String?
    var tags: [String] = []
    /// The catalog an installed copy was installed from, read from the
    /// `catalog:` frontmatter key written by `SkillStore.performInstall`.
    var originCatalogID: UUID?
}

enum Frontmatter {
    private static let quotes = CharacterSet(charactersIn: "\"'")

    /// Minimal YAML frontmatter reader: top-level `key: value` lines between `---` fences.
    /// `tags` accepts an inline list (`[a, b]`), a comma list, or a multiline `- item` list.
    static func parse(_ content: String) -> SkillMeta {
        var meta = SkillMeta()
        let lines = content.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return meta }
        var collectingTags = false
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            if collectingTags {
                if trimmed.hasPrefix("- ") {
                    let item = String(trimmed.dropFirst(2))
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: quotes)
                    if !item.isEmpty { meta.tags.append(item) }
                    continue
                }
                collectingTags = false
            }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            value = value.trimmingCharacters(in: quotes)
            switch key {
            case "name": meta.name = value
            case "description": meta.description = value
            case "version": meta.version = value
            case "catalog": meta.originCatalogID = UUID(uuidString: value)
            case "tags":
                if value.isEmpty {
                    collectingTags = true
                } else {
                    meta.tags = parseTagList(value)
                }
            default: break
            }
        }
        return meta
    }

    /// Splits content into the raw frontmatter block (including both `---` fences
    /// and the trailing newline) and the body. No frontmatter → ("", content).
    static func split(_ content: String) -> (frontmatter: String, body: String) {
        let lines = content.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let close = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "---"
              }) else { return ("", content) }
        let block = lines[...close].joined(separator: "\n") + "\n"
        let body = lines[(close + 1)...].joined(separator: "\n")
        return (block, body)
    }

    /// Returns the content with a `version:` line guaranteed in the frontmatter.
    /// Content without any frontmatter gets a minimal block prepended.
    static func ensuringVersion(in content: String, name: String, initial: String = "1.0.0") -> String {
        let meta = parse(content)
        if meta.version != nil { return content }

        var lines = content.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let close = lines.dropFirst().firstIndex(where: {
               $0.trimmingCharacters(in: .whitespaces) == "---"
           }) {
            lines.insert("version: \(initial)", at: close)
            return lines.joined(separator: "\n")
        }
        return "---\nname: \(name)\nversion: \(initial)\n---\n\n" + content
    }

    /// Returns the content with its frontmatter `version` set to the given value,
    /// replacing an existing line or inserting one. Content without frontmatter
    /// gets a minimal block.
    static func settingVersion(in content: String, version: String) -> String {
        var lines = content.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let close = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "---"
              }) else {
            return "---\nversion: \(version)\n---\n\n" + content
        }
        if let line = lines[1..<close].firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("version:")
        }) {
            lines[line] = "version: \(version)"
        } else {
            lines.insert("version: \(version)", at: close)
        }
        return lines.joined(separator: "\n")
    }

    /// Returns the content with its frontmatter `catalog` key set to the given
    /// catalog id, replacing an existing line or inserting one. Content without
    /// frontmatter gets a minimal block.
    static func settingOrigin(in content: String, catalogID: UUID) -> String {
        var lines = content.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let close = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "---"
              }) else {
            return "---\ncatalog: \(catalogID.uuidString)\n---\n\n" + content
        }
        if let line = lines[1..<close].firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("catalog:")
        }) {
            lines[line] = "catalog: \(catalogID.uuidString)"
        } else {
            lines.insert("catalog: \(catalogID.uuidString)", at: close)
        }
        return lines.joined(separator: "\n")
    }

    /// Returns the content with its frontmatter `tags` replaced by the given list
    /// (written inline, e.g. `tags: [a, b]`). An empty list removes the line.
    /// Existing multiline `- item` lists under `tags:` are removed as well.
    /// Content without frontmatter gets a minimal block when tags are non-empty.
    static func settingTags(in content: String, tags: [String]) -> String {
        var lines = content.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              var close = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "---"
              }) else {
            guard !tags.isEmpty else { return content }
            return "---\ntags: [\(tags.joined(separator: ", "))]\n---\n\n" + content
        }

        if let tagsLine = lines[1..<close].firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("tags:")
        }) {
            var end = tagsLine + 1
            while end < close, lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("- ") {
                end += 1
            }
            lines.removeSubrange(tagsLine..<end)
            close -= end - tagsLine
        }
        if !tags.isEmpty {
            lines.insert("tags: [\(tags.joined(separator: ", "))]", at: close)
        }
        return lines.joined(separator: "\n")
    }

    private static func parseTagList(_ raw: String) -> [String] {
        var value = raw
        if value.hasPrefix("["), value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
        }
        return value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: quotes) }
            .filter { !$0.isEmpty }
    }
}
