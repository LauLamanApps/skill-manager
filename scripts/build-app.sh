#!/bin/zsh
# Builds SkillManager.app into ./build (no Xcode required, CommandLineTools suffice).
set -euo pipefail

cd "$(dirname "$0")/.."

# Overridable by CI: release workflow passes the git tag as APP_VERSION.
APP_VERSION="${APP_VERSION:-0.1.0}"
APP_BUILD="${APP_BUILD:-$(git rev-parse --short HEAD)}"

swift build -c release

APP=build/SkillManager.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/SkillManager "$APP/Contents/MacOS/SkillManager"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# The app shows its own release notes (Settings › Release Notes). The bundled
# copy is stamped with the version being built, because at build time the
# shipping notes still sit under "Unreleased" — the repo-side rewrite only runs
# after the release workflow has uploaded the DMG.
python3 scripts/update-release-notes.py "$APP_VERSION" \
    --input RELEASENOTES.md \
    --output "$APP/Contents/Resources/RELEASENOTES.md" \
    --for-bundle

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>SkillManager</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>nl.llaman.skillmanager</string>
    <key>CFBundleName</key>
    <string>Skill Manager</string>
    <key>CFBundleDisplayName</key>
    <string>Skill Manager</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${APP_BUILD}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"

echo "Built $APP"
echo "Run: open $APP"
