import Foundation
import SwiftUI

/// Runs Claude Code headless (`claude -p`) to generate or edit skills in the catalog.
@MainActor
final class ClaudeRunner: ObservableObject {
    @Published var output: String = ""
    @Published var isRunning = false
    @Published var finishedSuccessfully: Bool?

    static func skillAuthoringPrompt(instruction: String) -> String {
        """
        You are editing a catalog of Claude Code skills. Each skill is a directory \
        containing a SKILL.md file with YAML frontmatter: name (kebab-case, matching \
        the directory name), description (one line, states when to use the skill), \
        version (semver, e.g. 1.0.0), and optional tags (inline YAML list of short \
        lowercase keywords, e.g. tags: [php, testing]). Skills may live in \
        subdirectories of the catalog, which act as folders for organization.

        Rules:
        - When creating a skill, create <skill-name>/SKILL.md with version 1.0.0 \
        and 2-4 tags matching the skill's topic; reuse tags already present in the \
        catalog when they fit.
        - When editing an existing skill, apply the change and bump the version: \
        patch for wording fixes, minor for new content, major for breaking rewrites.
        - Keep SKILL.md focused and actionable; move long reference material to \
        separate files in the skill directory and link them from SKILL.md.
        - Do not touch unrelated skills.

        Task:
        \(instruction)
        """
    }

    func run(instruction: String, cwd: URL) {
        guard !isRunning else { return }
        output = ""
        finishedSuccessfully = nil
        isRunning = true

        let prompt = Self.skillAuthoringPrompt(instruction: instruction)
        Task {
            do {
                let result = try await Shell.runInLoginShell(
                    "claude -p --permission-mode acceptEdits",
                    cwd: cwd,
                    stdin: prompt
                )
                output = result.combinedOutput
                finishedSuccessfully = result.succeeded
            } catch {
                output = error.localizedDescription
                finishedSuccessfully = false
            }
            isRunning = false
        }
    }

    /// True if a `claude` binary is reachable from a login shell.
    static func checkAvailability() async -> String? {
        let result = try? await Shell.runInLoginShell("command -v claude && claude --version")
        guard let result, result.succeeded else { return nil }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
