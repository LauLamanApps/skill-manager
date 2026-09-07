#!/bin/zsh
# Packages build/SkillManager.app into a drag-to-Applications DMG.
# Usage: scripts/make-dmg.sh [output.dmg]   (default: build/SkillManager.dmg)
set -euo pipefail

cd "$(dirname "$0")/.."

APP=build/SkillManager.app
OUT="${1:-build/SkillManager.dmg}"

if [ ! -d "$APP" ]; then
  echo "error: $APP not found — run scripts/build-app.sh first" >&2
  exit 1
fi

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$OUT"
hdiutil create -volname "Skill Manager" -srcfolder "$STAGING" \
  -ov -format UDZO -quiet "$OUT"

echo "Built $OUT"
