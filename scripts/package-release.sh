#!/usr/bin/env bash
set -euo pipefail

# Build a universal, ad-hoc-signed archive for a personal Homebrew cask.
# This does not publish a release or bypass macOS Gatekeeper.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: $0 <version, e.g. 0.1.0>" >&2
  exit 1
fi

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode-26.6.0.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer
fi

OUTPUT_DIR="$ROOT_DIR/build/release/$VERSION"
APP_PATH="$OUTPUT_DIR/OpenUsage.app"
ARCHIVE="OpenUsage-$VERSION-universal.zip"
mkdir -p "$OUTPUT_DIR"

xcodegen generate --quiet
xcodebuild \
  -project OpenUsage.xcodeproj \
  -scheme OpenUsage \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$ROOT_DIR/build/ReleaseDerivedData" \
  CONFIGURATION_BUILD_DIR="$OUTPUT_DIR" \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  build >&2

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP_PATH/Contents/Info.plist"
# Version metadata changes invalidate the outer bundle signature.
codesign --force --sign - "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
lipo "$APP_PATH/Contents/MacOS/OpenUsage" -verify_arch arm64 x86_64
lipo "$APP_PATH/Contents/Frameworks/OpenUsageCore.framework/OpenUsageCore" -verify_arch arm64 x86_64

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$OUTPUT_DIR/$ARCHIVE"
SHA256="$(shasum -a 256 "$OUTPUT_DIR/$ARCHIVE" | awk '{print $1}')"
printf '%s  %s\n' "$SHA256" "$ARCHIVE" > "$OUTPUT_DIR/SHA256SUMS"

cat > "$OUTPUT_DIR/openusage.rb" <<EOF
cask "openusage" do
  version "$VERSION"
  sha256 "$SHA256"

  url "https://github.com/jabreeflor/OpenUsage/releases/download/v#{version}/OpenUsage-#{version}-universal.zip"
  name "OpenUsage"
  desc "Menu bar usage statistics for AI subscriptions"
  homepage "https://github.com/jabreeflor/OpenUsage"

  depends_on macos: :sonoma

  app "OpenUsage.app"

  caveats <<~EOS
    This personal build is ad-hoc signed and is not notarized by Apple.
    macOS may require approval in System Settings > Privacy & Security on first launch.
  EOS
end
EOF

printf 'Release files: %s\n' "$OUTPUT_DIR"
