#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

export DEVELOPER_DIR="/Applications/Xcode-26.6.0.app/Contents/Developer"

xcodegen generate --quiet
xcodebuild \
  -project OpenUsage.xcodeproj \
  -scheme OpenUsageCoreTests \
  -configuration Debug \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "$ROOT_DIR/build/DerivedData" \
  build-for-testing >&2

TEST_BUNDLE="$ROOT_DIR/build/DerivedData/Build/Products/Debug/OpenUsageCoreTests.xctest"
if [[ ! -d "$TEST_BUNDLE" ]]; then
  echo "error: expected test bundle at $TEST_BUNDLE" >&2
  exit 1
fi

"$DEVELOPER_DIR/usr/bin/xctest" "$TEST_BUNDLE"
