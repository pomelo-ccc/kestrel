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

# 1. Auto-save any uncommitted tracked changes, then fetch & merge upstream changes (-X ours on conflicts)
if [[ -n "$(git status --porcelain -uno)" ]]; then
  git commit -am "chore(local): save working tree changes before upstream update" >/dev/null 2>&1 || true
fi
git fetch upstream --tags >/dev/null 2>&1 || true
if git rev-parse --verify upstream/main >/dev/null 2>&1; then
  git merge --no-edit -X ours upstream/main >/dev/null 2>&1 || {
    git merge --abort >/dev/null 2>&1 || true
  }
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

# 3. Unpack downloaded upstream zip and transform BaoCode.app -> Byte.app
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

/usr/bin/ditto -x -k "$ZIP_PATH" "$WORK_DIR"

if [[ -d "$WORK_DIR/BaoCode.app" ]]; then
  mv "$WORK_DIR/BaoCode.app" "$WORK_DIR/Byte.app"
elif [[ -d "$WORK_DIR/Kestrel.app" ]]; then
  mv "$WORK_DIR/Kestrel.app" "$WORK_DIR/Byte.app"
fi

APP="$WORK_DIR/Byte.app"
if [[ ! -d "$APP" ]]; then
  echo "Error: Byte.app not found in $WORK_DIR" >&2
  exit 1
fi

if [[ -f "$APP/Contents/MacOS/BaoCode" ]]; then
  mv "$APP/Contents/MacOS/BaoCode" "$APP/Contents/MacOS/Kestrel"
fi

# 4. Patch binary strings, MainMenu.nib class names, and menu bar tray icon (logoCells)
python3 - "$APP/Contents/MacOS/Kestrel" "$APP/Contents/Resources/Base.lproj/MainMenu.nib" << 'EOF'
import struct, sys, os

path = sys.argv[1]
nib_path = sys.argv[2]

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

if os.path.isfile(nib_path):
    with open(nib_path, "rb") as f:
        nib_data = f.read()
    nib_data = nib_data.replace(b"7BaoCode", b"7Kestrel").replace(b"BaoCode", b"Kestrel")
    with open(nib_path, "wb") as f:
        f.write(nib_data)
EOF

# 5. Update Info.plist and FinderExtension Info.plist
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Byte" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Byte" "$PLIST" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Byte" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable Kestrel" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier dev.kestrel.desktop" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :NSHumanReadableCopyright 'Copyright © 2026 Byte. All rights reserved.'" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:0:CFBundleURLName dev.kestrel.desktop" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 kestrel" "$PLIST" 2>/dev/null || true

EXT_PLIST="$APP/Contents/PlugIns/FinderExtension.appex/Contents/Info.plist"
if [[ -f "$EXT_PLIST" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Byte" "$EXT_PLIST" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Byte" "$EXT_PLIST" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier dev.kestrel.desktop.FinderExtension" "$EXT_PLIST" 2>/dev/null || true
fi

# 6. Build and inject Byte AppIcon.icns (remove upstream Assets.car so macOS uses AppIcon.icns) and newly compiled App.framework
rm -f "$APP/Contents/Resources/Assets.car"
ICONSET_DIR="$WORK_DIR/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"
APPICON_SRC="$REPO/macos/Runner/Assets.xcassets/AppIcon.appiconset"
if [[ -d "$APPICON_SRC" ]]; then
  cp "$APPICON_SRC/app_icon_16.png"   "$ICONSET_DIR/icon_16x16.png"
  cp "$APPICON_SRC/app_icon_32.png"   "$ICONSET_DIR/icon_16x16@2x.png"
  cp "$APPICON_SRC/app_icon_32.png"   "$ICONSET_DIR/icon_32x32.png"
  cp "$APPICON_SRC/app_icon_64.png"   "$ICONSET_DIR/icon_32x32@2x.png"
  cp "$APPICON_SRC/app_icon_128.png"  "$ICONSET_DIR/icon_128x128.png"
  cp "$APPICON_SRC/app_icon_256.png"  "$ICONSET_DIR/icon_128x128@2x.png"
  cp "$APPICON_SRC/app_icon_256.png"  "$ICONSET_DIR/icon_256x256.png"
  cp "$APPICON_SRC/app_icon_512.png"  "$ICONSET_DIR/icon_256x256@2x.png"
  cp "$APPICON_SRC/app_icon_512.png"  "$ICONSET_DIR/icon_512x512.png"
  cp "$APPICON_SRC/app_icon_1024.png" "$ICONSET_DIR/icon_512x512@2x.png"
  iconutil -c icns "$ICONSET_DIR" -o "$APP/Contents/Resources/AppIcon.icns"
elif [[ -f "/Applications/Byte.app/Contents/Resources/AppIcon.icns" ]]; then
  cp "/Applications/Byte.app/Contents/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

rm -rf "$APP/Contents/Frameworks/App.framework"
cp -R "$REPO/build/macos/Build/Products/Release/App.framework" "$APP/Contents/Frameworks/"
cp -f "$REPO/assets/branding/app_icon.png" \
   "$APP/Contents/Frameworks/App.framework/Resources/flutter_assets/assets/branding/app_icon.png" 2>/dev/null || true

if [[ -f "$REPO/macos/Runner/KestrelNotch.m" ]]; then
  /Library/Developer/CommandLineTools/usr/bin/clang \
    -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
    -dynamiclib -fobjc-arc -framework Cocoa -framework Carbon \
    -x objective-c "$REPO/macos/Runner/KestrelNotch.m" \
    -o "$APP/Contents/Frameworks/libKestrelNotch.dylib"
fi

# 7. Sign Kestrel.app and package as .kestrel.zip
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT_ZIP"
