#!/bin/bash
set -euo pipefail

# Usage: ./scripts/create-dmg.sh <app-path> <version> <output-dir>
# Example: ./scripts/create-dmg.sh /path/to/CloudMount.app 2.0.0 ./dist

APP_PATH="${1:?Usage: create-dmg.sh <app-path> <version> <output-dir>}"
VERSION="${2:?Usage: create-dmg.sh <app-path> <version> <output-dir>}"
OUTPUT_DIR="${3:?Usage: create-dmg.sh <app-path> <version> <output-dir>}"

DMG_NAME="CloudMount-${VERSION}.dmg"
mkdir -p "$OUTPUT_DIR"

create-dmg \
  --volname "CloudMount" \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "CloudMount.app" 150 190 \
  --app-drop-link 450 190 \
  --hide-extension "CloudMount.app" \
  --no-internet-enable \
  "${OUTPUT_DIR}/${DMG_NAME}" \
  "$(dirname "$APP_PATH")"

echo "Created: ${OUTPUT_DIR}/${DMG_NAME}"
