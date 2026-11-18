#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
FLUTTER="${FLUTTER:-$(command -v flutter || echo "$HOME/flutter/bin/flutter")}"
SDK_ROOT="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="${CLANG:-/Library/Developer/CommandLineTools/usr/bin/clang}"
BASE_APP="${BASE_APP:-/Applications/Byte.app}"

if [[ ! -d "$BASE_APP" ]]; then
  echo "Error: base macOS .app bundle not found at /Applications/Byte.app" >&2
  exit 1
fi

STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT
ditto "$BASE_APP" "$STAGE_DIR/Template.app"

cd "$REPO"
"$FLUTTER" assemble --no-version-check \
  --output=build/macos/Build/Products/Release/ \
  -dTargetPlatform=darwin \
  -dTargetFile=lib/main.dart \
  -dBuildMode=release \
  -dConfiguration=Release \
  -dDarwinArchs=arm64 \
  -dSdkRoot="$SDK_ROOT" \
  -dSplitDebugInfo= \
  -dDartObfuscation=false \
  -dTreeShakeIcons=true \
  -dTrackWidgetCreation=true \
  -dSrcRoot="$REPO/macos" \
  -dXcodeBuildScript=prepare \
  release_macos_bundle_flutter_assets

ditto "$STAGE_DIR/Template.app" "$STAGE_DIR/Byte.app"
rm -rf "$STAGE_DIR/Byte.app/Contents/Frameworks/App.framework"
cp -R "$REPO/build/macos/Build/Products/Release/App.framework" "$STAGE_DIR/Byte.app/Contents/Frameworks/"
"$CLANG" -isysroot "$SDK_ROOT" -dynamiclib -fobjc-arc -framework Cocoa -framework Carbon \
  -x objective-c "$REPO/macos/Runner/KestrelNotch.m" \
  -o "$STAGE_DIR/Byte.app/Contents/Frameworks/libKestrelNotch.dylib"

xattr -cr "$STAGE_DIR/Byte.app"
codesign --force --deep --sign - "$STAGE_DIR/Byte.app"
codesign --verify --deep --strict "$STAGE_DIR/Byte.app"
rm -rf "/Applications/Byte.app"
mv "$STAGE_DIR/Byte.app" "/Applications/Byte.app"
echo "✓ Built and installed /Applications/Byte.app"
