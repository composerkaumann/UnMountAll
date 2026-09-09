#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/unmount-all-build.XXXXXX")"
APP_DIR="$ROOT_DIR/dist/UMA.app"
LEGACY_APP_DIR="$ROOT_DIR/dist/Unmount All.app"
CONTENTS_DIR="$APP_DIR/Contents"
ICON_SOURCE="$ROOT_DIR/Assets/AppIconSource.png"
VERSION_FILE="$ROOT_DIR/VERSION"
BUILD_NUMBER_FILE="$ROOT_DIR/BUILD_NUMBER"
trap '/bin/rm -rf "$BUILD_DIR"' EXIT HUP INT TERM

PREVIOUS_VERSION="1.0.0"
PREVIOUS_BUILD="1"
if [ -f "$VERSION_FILE" ] && [ -f "$BUILD_NUMBER_FILE" ]; then
    PREVIOUS_VERSION="$(/usr/bin/sed -n '1p' "$VERSION_FILE")"
    PREVIOUS_BUILD="$(/usr/bin/sed -n '1p' "$BUILD_NUMBER_FILE")"
else
    VERSION_PLIST="$CONTENTS_DIR/Info.plist"
    if [ ! -f "$VERSION_PLIST" ] && [ -f "$LEGACY_APP_DIR/Contents/Info.plist" ]; then
        VERSION_PLIST="$LEGACY_APP_DIR/Contents/Info.plist"
    fi
fi
if [ -n "${VERSION_PLIST:-}" ] && [ -f "$VERSION_PLIST" ]; then
    PREVIOUS_VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$VERSION_PLIST" 2>/dev/null || /usr/bin/printf '1.0.0')"
    PREVIOUS_BUILD="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$VERSION_PLIST" 2>/dev/null || /usr/bin/printf '1')"
fi

VERSION_MAJOR="${PREVIOUS_VERSION%%.*}"
VERSION_REMAINDER="${PREVIOUS_VERSION#*.}"
VERSION_MINOR="${VERSION_REMAINDER%%.*}"
VERSION_PATCH="${VERSION_REMAINDER##*.}"
case "$VERSION_MAJOR:$VERSION_MINOR:$VERSION_PATCH:$PREVIOUS_BUILD" in
    *[!0-9:]*|::*|*::*)
        /usr/bin/printf 'Invalid existing version: %s (%s)\n' "$PREVIOUS_VERSION" "$PREVIOUS_BUILD" >&2
        exit 1
        ;;
esac
APP_VERSION="$VERSION_MAJOR.$VERSION_MINOR.$((VERSION_PATCH + 1))"
APP_BUILD="$((PREVIOUS_BUILD + 1))"

cd "$ROOT_DIR"
/usr/bin/xcrun swift build \
    --configuration release \
    --arch arm64 \
    --scratch-path "$BUILD_DIR"

ICONSET_DIR="$BUILD_DIR/AppIcon.iconset"
/bin/mkdir -p "$ICONSET_DIR"
/usr/bin/sips -z 16 16 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
/usr/bin/sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
/usr/bin/sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
/usr/bin/sips -z 64 64 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
/usr/bin/sips -z 128 128 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
/usr/bin/sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
/usr/bin/sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
/usr/bin/sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
/usr/bin/sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
/usr/bin/sips -z 1024 1024 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null
/usr/bin/iconutil -c icns "$ICONSET_DIR" -o "$BUILD_DIR/AppIcon.icns"

/bin/rm -rf "$APP_DIR"
/bin/mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
/usr/bin/ditto "$BUILD_DIR/arm64-apple-macosx/release/UnmountAll" "$CONTENTS_DIR/MacOS/UMA"
/usr/bin/ditto "$ROOT_DIR/unmount-all.sh" "$CONTENTS_DIR/Resources/unmount-all.sh"
/usr/bin/ditto "$BUILD_DIR/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"
/bin/chmod 755 "$CONTENTS_DIR/MacOS/UMA" "$CONTENTS_DIR/Resources/unmount-all.sh"

/usr/bin/plutil -create xml1 "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert CFBundleDevelopmentRegion -string en "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert CFBundleDisplayName -string UMA "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert CFBundleExecutable -string UMA "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert CFBundleIdentifier -string ee.music.UMA "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert CFBundleIconFile -string AppIcon "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert CFBundleName -string UMA "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert CFBundlePackageType -string APPL "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert CFBundleShortVersionString -string "$APP_VERSION" "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert CFBundleVersion -string "$APP_BUILD" "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert LSMinimumSystemVersion -string 26.0 "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert NSHighResolutionCapable -bool true "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert NSSupportsAutomaticGraphicsSwitching -bool true "$CONTENTS_DIR/Info.plist"

/usr/bin/codesign --force --deep --sign - "$APP_DIR"
/usr/bin/codesign --verify --deep --strict "$APP_DIR"

/usr/bin/printf '%s\n' "$APP_VERSION" >"$VERSION_FILE"
/usr/bin/printf '%s\n' "$APP_BUILD" >"$BUILD_NUMBER_FILE"

if [ -d "$LEGACY_APP_DIR" ]; then
    /bin/rm -rf "$LEGACY_APP_DIR"
fi

/usr/bin/printf 'Built: %s (version %s, build %s)\n' "$APP_DIR" "$APP_VERSION" "$APP_BUILD"
