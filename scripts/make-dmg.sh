#!/bin/zsh
# Packages build/SkillManager.app into a styled drag-to-Applications DMG, with a
# generated background image and a custom volume icon based on the app logo.
# Usage: scripts/make-dmg.sh [output.dmg]   (default: build/SkillManager.dmg)
set -euo pipefail

cd "$(dirname "$0")/.."

APP=build/SkillManager.app
OUT="${1:-build/SkillManager.dmg}"
VOLNAME="Skill Manager"
ICON=Resources/AppIcon.icns
VOLUME_ICON=Resources/VolumeIcon.icns

if [ ! -d "$APP" ]; then
  echo "error: $APP not found — run scripts/build-app.sh first" >&2
  exit 1
fi

STAGING=$(mktemp -d)
BACKGROUND="$STAGING/.background.png"
trap 'rm -rf "$STAGING"' EXIT

swift scripts/generate-dmg-background.swift "$BACKGROUND" "$ICON"

cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
mkdir "$STAGING/.background"
mv "$BACKGROUND" "$STAGING/.background/background.png"

rm -f "$OUT"
DMG_RW=$(mktemp -u "${TMPDIR:-/tmp}/skillmanager-XXXXXX.dmg")
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGING" \
  -ov -format UDRW -fs HFS+ -quiet "$DMG_RW"

MOUNT_DIR=$(hdiutil attach -readwrite -noverify -noautoopen "$DMG_RW" \
  | grep -E '^/dev/' | grep 'Apple_HFS' | awk -F '\t' '{print $NF}')

osascript <<OSA
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set sidebar width of container window to 0
    set bounds of container window to {100, 100, 760, 500}
    set viewOptions to icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set background picture of viewOptions to file ".background:background.png"
    set position of item "SkillManager.app" of container window to {180, 170}
    set position of item "Applications" of container window to {480, 170}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
OSA

# Applied last: Finder's styling pass above (close/open/update) strips a
# .VolumeIcon.icns placed beforehand, so the custom volume icon is set only
# once Finder is done touching the window.
cp "$VOLUME_ICON" "$MOUNT_DIR/.VolumeIcon.icns"
SetFile -a C "$MOUNT_DIR"

sync
hdiutil detach "$MOUNT_DIR" -quiet
rm -f "$OUT"
hdiutil convert "$DMG_RW" -format UDZO -imagekey zlib-level=9 -o "$OUT" -quiet
rm -f "$DMG_RW"

echo "Built $OUT"
