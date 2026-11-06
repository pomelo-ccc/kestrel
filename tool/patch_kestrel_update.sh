#!/usr/bin/env bash
set -euo pipefail

ZIP_PATH="${1:?Usage: patch_kestrel_update.sh <zip_path> [version]}"
VERSION="${2:-}"
OUT_ZIP="${ZIP_PATH}.kestrel.zip"

if [[ -f "$OUT_ZIP" ]]; then
  exit 0
fi

REPO="/Users/pomelo/.gemini/antigravity/scratch/kestrel"
FLUTTER="/Users/pomelo/flutter/bin/flutter"

unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy

cd "$REPO"

# 1. Fetch & merge upstream changes while keeping Kestrel customizations (-X ours on conflicts)
git fetch upstream --tags 2>/dev/null || true
if git rev-parse --verify upstream/main >/dev/null 2>&1; then
  git merge --no-edit -X ours upstream/main || true
fi

# 2. Rebuild App.framework with merged upstream + Kestrel customizations
"$FLUTTER" assemble --no-version-check \
  --output=build/macos/Build/Products/Release/ \
  -dTargetPlatform=darwin \
  -dTargetFile=lib/main.dart \
  -dBuildMode=release \
  -dConfiguration=Release \
  -dDarwinArchs=arm64 \
  -dSdkRoot="$(xcrun --sdk macosx --show-sdk-path)" \
  -dSplitDebugInfo= \
  -dDartObfuscation=false \
  -dTreeShakeIcons=true \
  -dTrackWidgetCreation=true \
  -dSrcRoot="$REPO/macos" \
  -dXcodeBuildScript=prepare \
  release_macos_bundle_flutter_assets

# 3. Unpack downloaded upstream zip and transform BaoCode.app -> Kestrel.app
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

/usr/bin/ditto -x -k "$ZIP_PATH" "$WORK_DIR"

if [[ -d "$WORK_DIR/BaoCode.app" ]]; then
  mv "$WORK_DIR/BaoCode.app" "$WORK_DIR/Kestrel.app"
fi

APP="$WORK_DIR/Kestrel.app"
if [[ ! -d "$APP" ]]; then
  echo "Error: Kestrel.app not found in $WORK_DIR" >&2
  exit 1
fi

if [[ -f "$APP/Contents/MacOS/BaoCode" ]]; then
  mv "$APP/Contents/MacOS/BaoCode" "$APP/Contents/MacOS/Kestrel"
fi

# 4. Patch binary strings and menu bar tray icon (logoCells)
python3 - "$APP/Contents/MacOS/Kestrel" << 'EOF'
import struct, sys

path = sys.argv[1]
with open(path, "rb") as f:
    data = bytearray(f.read())

data = data.replace(b"BaoCode\x00", b"Kestrel\x00")
data = data.replace(b"7BaoCode", b"7Kestrel")

# Locate Attention.logoCells constant table: (14.0, 0.0, 28.0, 7.0)
target = struct.pack("<4d", 14.0, 0.0, 28.0, 7.0)
idx = data.find(target)
if idx != -1:
    pairs = [
        (24.5, 0.0),
        (7.0, 42.0),
        (0.0, 0.0),
        (14.0, 7.0),
        (7.0, 28.0),
        (35.0, 7.0),
        (3.5, 14.0),
        (7.0, 14.0),
        (45.5, 14.0),
        (0.0, 0.0),
    ]
    for i, (a, b) in enumerate(pairs):
        off = idx + i * 16
        data[off:off+16] = struct.pack("<2d", a, b)
    # Also replace fmov.2d v1, #7.0 (0x4e631001) near logoCells_WZ with movi.2d v1, #0 (0x6f00e401)
    fmov_pat = struct.pack("<I", 0x4e631001)
    fmov_idx = data.find(fmov_pat)
    if fmov_idx != -1 and data.count(fmov_pat) == 1:
        data[fmov_idx:fmov_idx+4] = struct.pack("<I", 0x6f00e401)

with open(path, "wb") as f:
    f.write(data)
EOF

# 5. Update Info.plist and FinderExtension Info.plist
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Kestrel" "$PLIST" || true
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Kestrel" "$PLIST" || true
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable Kestrel" "$PLIST" || true
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier dev.kestrel.desktop" "$PLIST" || true
/usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:0:CFBundleURLName dev.kestrel.desktop" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 kestrel" "$PLIST" 2>/dev/null || true

EXT_PLIST="$APP/Contents/PlugIns/FinderExtension.appex/Contents/Info.plist"
if [[ -f "$EXT_PLIST" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Kestrel" "$EXT_PLIST" || true
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier dev.kestrel.desktop.FinderExtension" "$EXT_PLIST" || true
fi

# 6. Inject Kestrel AppIcon.icns and newly compiled App.framework
cp "$REPO/build/macos/Build/Products/Release/Kestrel.app/Contents/Resources/AppIcon.icns" \
   "$APP/Contents/Resources/AppIcon.icns"

rm -rf "$APP/Contents/Frameworks/App.framework"
cp -R "$REPO/build/macos/Build/Products/Release/App.framework" "$APP/Contents/Frameworks/"
cp "$REPO/assets/branding/app_icon.png" \
   "$APP/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/branding/app_icon.png"

# 7. Sign Kestrel.app and package as .kestrel.zip
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT_ZIP"
