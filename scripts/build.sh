#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

export DEVELOPER_DIR="/Applications/Xcode-26.6.0.app/Contents/Developer"

xcodegen generate --quiet
xcodebuild \
  -project OpenUsage.xcodeproj \
  -scheme OpenUsage \
  -configuration Debug \
  -destination "platform=macOS" \
  -derivedDataPath "$ROOT_DIR/build/DerivedData" \
  CONFIGURATION_BUILD_DIR="$ROOT_DIR/build/Products/Debug" \
  build >&2

APP_PATH="$ROOT_DIR/build/Products/Debug/OpenUsage.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "error: expected built app at $APP_PATH" >&2
  exit 1
fi

echo "$APP_PATH"
