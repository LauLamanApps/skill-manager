import AppKit

enum CodeLanguage: String {
    case bash, python, javascript, swift, yaml, json, markdown, plain

    /// Detects the language from the file extension, falling back to the shebang.
    static func detect(fileName: String, content: String) -> CodeLanguage {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "sh", "bash", "zsh": return .bash
        case "py": return .python
        case "js", "mjs", "cjs", "ts", "jsx", "tsx": return .javascript
        case "swift": return .swift
        case "yml", "yaml": return .yaml
        case "json": return .json
        case "md", "markdown": return .markdown
        default: break
        }
        if content.hasPrefix("#!") {
            let shebang = content.components(separatedBy: "\n").first ?? ""
            if shebang.contains("python") { return .python }
            if shebang.contains("node") { return .javascript }
            if shebang.contains("swift") { return .swift }
            if shebang.contains("sh") { return .bash }
        }
        return .plain
    }
}

/// Minimal regex-based highlighter — no external dependencies. Good enough for
/// the short scripts and docs that live inside a skill directory.
enum SyntaxHighlighter {
    private struct Rule {
        let regex: NSRegularExpression
        let color: NSColor
    }

    static let font = NSFont.monospacedSystemFont(
        ofSize: NSFont.systemFontSize, weight: .regular
    )

    private static var cache: [CodeLanguage: [Rule]] = [:]

    static func highlight(_ storage: NSTextStorage, language: CodeLanguage) {
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes(
            [.font: font, .foregroundColor: NSColor.labelColor], range: full
        )
        for rule in rules(for: language) {
            rule.regex.enumerateMatches(in: storage.string, range: full) { match, _, _ in
                if let match {
                    storage.addAttribute(
                        .foregroundColor, value: rule.color, range: match.range
                    )
                }
            }
        }
        storage.endEditing()
    }

    private static func rules(for language: CodeLanguage) -> [Rule] {
        if let cached = cache[language] { return cached }
        let built = buildRules(for: language)
        cache[language] = built
        return built
    }

    private static func rule(_ pattern: String, _ color: NSColor) -> Rule? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.anchorsMatchLines]
        ) else { return nil }
        return Rule(regex: regex, color: color)
    }

    // Rule order matters: later rules override earlier ones, so strings beat
    // keywords and comments beat everything.
    private static func buildRules(for language: CodeLanguage) -> [Rule] {
        let keywords = NSColor.systemPink
        let strings = NSColor.systemOrange
        let comments = NSColor.systemGreen
        let numbers = NSColor.systemBlue
        let special = NSColor.systemTeal

        let patterns: [(String, NSColor)]
        switch language {
        case .bash:
            patterns = [
                (#"\b\d+\b"#, numbers),
                (#"\b(if|then|else|elif|fi|for|while|until|do|done|case|esac|function|in|local|return|export|set|read|echo|exit|shift|trap|source)\b"#, keywords),
                (#"\$\{?\w+\}?"#, special),
                (#""[^"\n]*"|'[^'\n]*'"#, strings),
                (#"#[^\n]*"#, comments),
            ]
        case .python:
            patterns = [
                (#"\b\d[\d_.]*\b"#, numbers),
                (#"\b(def|class|if|elif|else|for|while|return|import|from|as|with|try|except|finally|raise|pass|break|continue|lambda|None|True|False|and|or|not|in|is|yield|global|nonlocal|assert|del|async|await|self)\b"#, keywords),
                (#"@\w[\w.]*"#, special),
                (#""""[\s\S]*?"""|'''[\s\S]*?'''|"[^"\n]*"|'[^'\n]*'"#, strings),
                (#"#[^\n]*"#, comments),
            ]
        case .javascript:
            patterns = [
                (#"\b\d[\d_.]*\b"#, numbers),
                (#"\b(function|const|let|var|if|else|for|while|do|return|class|extends|import|export|from|new|this|typeof|instanceof|async|await|try|catch|finally|throw|switch|case|break|continue|default|delete|void|in|of|yield|null|undefined|true|false)\b"#, keywords),
                (#""[^"\n]*"|'[^'\n]*'|`[^`]*`"#, strings),
                (#"//[^\n]*|/\*[\s\S]*?\*/"#, comments),
            ]
        case .swift:
            patterns = [
                (#"\b\d[\d_.]*\b"#, numbers),
                (#"\b(func|let|var|if|else|guard|for|while|repeat|return|struct|class|enum|protocol|extension|import|switch|case|default|break|continue|fallthrough|throws|rethrows|throw|try|catch|defer|async|await|actor|nil|true|false|self|Self|super|init|deinit|private|fileprivate|internal|public|open|static|final|lazy|weak|unowned|mutating|override|where|some|any|in|is|as)\b"#, keywords),
                (#"@\w+"#, special),
                (#""[^"\n]*""#, strings),
                (#"//[^\n]*|/\*[\s\S]*?\*/"#, comments),
            ]
        case .yaml:
            patterns = [
                (#"\b\d[\d_.]*\b"#, numbers),
                (#"\b(true|false|null|yes|no|on|off)\b"#, keywords),
                (#"^\s*-?\s*[\w.-]+(?=\s*:)"#, special),
                (#""[^"\n]*"|'[^'\n]*'"#, strings),
                (#"#[^\n]*"#, comments),
            ]
        case .json:
            patterns = [
                (#"\b\d[\d.eE+-]*\b"#, numbers),
                (#"\b(true|false|null)\b"#, keywords),
                (#""[^"\n]*""#, strings),
                (#""[^"\n]*"(?=\s*:)"#, special),
            ]
        case .markdown:
            patterns = [
                (#"^#{1,6}[^\n]*"#, keywords),
                (#"\*\*[^*\n]+\*\*|__[^_\n]+__"#, special),
                (#"`[^`\n]+`"#, strings),
                (#"^```[\s\S]*?^```"#, strings),
                (#"^>[^\n]*"#, comments),
            ]
        case .plain:
            patterns = []
        }
        return patterns.compactMap { rule($0.0, $0.1) }
    }
}
