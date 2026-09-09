# Release Notes

## Unreleased

### Added

- **Multiple skill catalogs** — a catalog is no longer a single fixed
  repository. Add, rename, reorder, sync or remove any number of git-backed
  catalogs in Settings › Catalogs. Skills carry a badge for the catalog they
  came from and the list can be filtered by it, and both "Add to Catalog" and
  AI skill creation ask which catalog to write into when there is more than one.
  Sync runs over every catalog, reporting conflicts and errors per repository
  instead of stopping at the first failure.
- **Choose which AI runs your skills** — Settings › Agent picks between Claude
  Code and Codex, points at a specific binary, and sets the model. Codex streams
  its output, resumes its thread across turns and stays read-only in Ask mode,
  same as Claude Code. Controls an agent cannot support — trials, session
  resume — are now visibly disabled rather than failing mid-run.
- **Install into several agents at once** — enable Claude Code, Codex or Cursor,
  point each at its skills folder, and choose which of them an install goes to.
  Installed skills record where they came from, so update checks compare against
  the right catalog.
- **A window per skill** — double-click a skill card to open it in its own
  editing window, with the info panel on the left and the AI chat on the right.
  Opening a skill that is already open brings its window forward instead of
  opening a second one.
- **Release notes in the app** — Settings › Release Notes shows what changed in
  this version and every earlier one, as collapsible per-version cards. The
  update-available screen shows the new version's notes before you install it.
- **Update prompts** — checking for updates now asks before installing, and
  tells you when you are already on the latest version.

### Changed

- **The catalog page is a grid of cards** rather than a narrow list, using the
  full window width. Skills are edited in their own window (above) instead of a
  third column.
- **The chat is agent-neutral** — it says "the AI" rather than naming Claude
  Code, since the CLI behind it is a setting. The configured agent and model are
  named once, beside the send button.
- **Edit and Ask are tabs** at the top of the chat panel instead of a picker
  wedged in beside the send button.
- **Settings redesign** — a macOS-style sidebar with one tab per area, About
  pinned to the bottom, and the build number shown next to the version.

### Internal

- The runner behind every AI call is now an `AgentRunner` protocol with explicit
  capability flags, with `ClaudeCodeRunner` and `CodexRunner` as adapters, so
  the UI can ask what an agent supports instead of assuming Claude Code.
- Catalog configuration migrates to a managed `catalogs.json`; installed skills
  gained a `catalog:` frontmatter marker recording their origin.
- `RELEASENOTES.md` is copied into the app at build time with the "Unreleased"
  heading stamped as the version being built, and the release workflow rolls the
  section over automatically afterwards.
- The build number is the short git commit hash.

## 0.2.0 — 2026-09-08

### Added
- **Try a skill before installing** — test-drive any catalog skill in a throwaway Claude Code session (`/trial:<skill-name>`), no changes to `~/.claude/skills`.
- **Read-only Ask mode** — an Edit/Ask toggle on both AI surfaces. Ask runs the CLI in plan mode, so a question about a skill cannot change it.
- **Model picker** — choose Haiku, Sonnet or Opus in Settings instead of always taking the CLI default.
- **Skill health lint** — skills flag a missing description, version or tags, and a SKILL.md that has grown past 500 lines, as a warning icon in the list and a Health section in the info panel.
- **Full-text search** — search now matches the body of SKILL.md, not just name, description, tags and folder.
- **Bulk operations** — ⌘/⇧-click multiple skills to install, tag, or uninstall them all at once.
- **Diff review for AI edits** — every AI run now snapshots the working directory first and shows a unified diff of everything Claude touched, with per-file or bulk Keep/Revert.
- **Sync conflict resolution** — a conflicting GitHub pull now opens a sheet to resolve each conflicting file (local vs. remote) instead of just failing the sync.
- **In-app update checking** — the app can check GitHub releases for newer versions and install them directly.
- **Styled release DMG** — the installer now has a custom background (drag-to-Applications layout) and a dedicated drive-shaped disk icon instead of the plain default.
- Release builds now ship as a DMG instead of a zip.

### Changed
- **AI runs stream live** — each message and tool call appears as it happens, instead of a spinner that only filled in once the run finished.
- **AI runs can be stopped** — a Stop button cancels a call in flight on both AI surfaces.
- **The chat remembers the conversation** — follow-ups resume the same session, so "no, use snake_case instead" builds on the previous turns, and every turn stays in the transcript.
- Update checks run automatically on launch and every 24 hours, throttled so a relaunch does not re-check.
- Uninstalling a skill now moves it to the system Trash instead of deleting it permanently — recoverable via Finder.
- The inspector panel's toggle moved to the toolbar's far right; a close button was added inside the panel itself.

### Internal
- Chat sessions and their streamed Claude output now persist per surface instead of resetting.

## 0.1.0 — 2026-09-07

First release. Skill Manager is a native macOS app for managing your Claude Code
skills: browse a shared catalog, install skills into `~/.claude/skills`, and
create or edit them with AI — with versioning and git built in.

### Catalog & discovery

- **Skill catalog backed by a GitHub repo**, cloned locally. Skills can be
  organized in subfolders, which show up as sections in the list.
- **Tags** on every skill (frontmatter `tags:`), editable directly in the skill
  header. Search matches name, description, tags, and folder; a tag bar filters
  the list with one click.
- **Installed view** shows what's in `~/.claude/skills`, flags skills with a
  newer catalog version, and marks local-only skills as "Not in catalog".

### Install & publish

- **Install / Update / Uninstall** with one click.
- **Add to Catalog** moves a local skill into the catalog (optionally into a
  folder) and gives it a version if it has none, so update tracking works from
  then on.
- **Sync** commits your local catalog changes, pulls remote updates, and
  pushes — it also works on a brand-new, still-empty repository.

### Editing

- **Multi-file skills**: the info panel's Files tab shows the full file tree;
  every text file opens in the editor. Binary files are detected and skipped.
- **Syntax highlighting** for shell, Python, JavaScript/TypeScript, Swift,
  YAML, JSON, and Markdown — no external dependencies.
- **Metadata stays out of your way**: the editor shows only the instructions;
  name, description, version, and tags are managed in the header and info
  panel.
- **Info panel** with version, source, install state, description,
  created/modified/installed dates, and the file tree.

### Versioning & git

- **Save dialog with AI-suggested versioning**: on save, Claude classifies your
  change as patch/minor/major and drafts a one-line summary. You pick the
  version; saving writes the file and commits it with that summary.
- **Pull-request flow**: optionally save to a pushed feature branch and open
  the PR page instead of committing directly (`gh` CLI used when available).
- **Junk stays out**: a managed `.gitignore` (e.g. `__pycache__`, `*.pyc`,
  `node_modules`) is seeded into the catalog and doubles as the filter for the
  UI and for install copies.

### AI

- **New Skill with AI**: describe what the skill should teach Claude — name,
  content, tags, and placement are generated (name optional, AI picks one).
- **Edit with AI**: describe a change; version bumps are handled automatically.
- **Chat panel**: ask Claude Code to manipulate the current skill's files
  directly from the app.

### Requirements

- macOS 14+
- `git` with access to your catalog repository
- Claude Code CLI (`claude`) on your login-shell PATH for the AI features

> The app is ad-hoc signed: on first launch, right-click the app and choose
> "Open" to pass Gatekeeper.
