# Skill Manager

Native macOS (SwiftUI) app for managing Claude Code skills.

## Features

- **Catalog** — a GitHub repo of skills, cloned to
  `~/Library/Application Support/SkillManager/catalog`. Each skill is a
  directory with a `SKILL.md` (frontmatter: `name`, `description`, `version`,
  optional `tags`). Skills may live in subfolders (e.g. `frontend/react-hooks`);
  folders show up as sections in the catalog list.
- **Search & tags** — search field matches name, description, tags, and folder;
  the tag bar above the list filters by a single tag.
- **Installed view** — scans `~/.claude/skills`, shows installed versions and
  flags skills with a newer catalog version.
- **Install / Update / Uninstall** — copies skill directories between catalog
  and `~/.claude/skills`.
- **Add to Catalog** — an installed skill that isn't in the catalog yet can be
  copied into it (optionally into a folder); a missing `version` is set to
  1.0.0 so it participates in update tracking.
- **AI generate & edit** — shells out to Claude Code headless
  (`claude -p --permission-mode acceptEdits`) with a skill-authoring prompt;
  version bumps are handled by the prompt (patch/minor/major).
- **GitHub sync** — the Sync toolbar button pulls (`--rebase`), commits local
  changes, and pushes. Uses your system `git` and its credentials.

## Requirements

- macOS 14+, Swift toolchain (CommandLineTools are enough — no Xcode needed)
- `git` with push access to your catalog repo
- Claude Code CLI (`claude`) on your login-shell PATH

## Build & run

```sh
# Dev run
swift run

# Build .app bundle (ad-hoc signed) into ./build
./scripts/build-app.sh
open build/SkillManager.app
```

## First-time setup

1. Open Settings (⌘,), set the catalog repo URL
   (e.g. `git@github.com:you/skills-catalog.git`), hit **Clone**.
2. Toolbar **+** generates a new skill with AI; **Sync** pushes it to GitHub.

## Skill format

```markdown
---
name: my-skill
description: One line saying when Claude should use this skill.
version: 1.0.0
tags: [php, testing]
---

Instructions for Claude…
```
