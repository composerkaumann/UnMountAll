#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/uma-build.XXXXXX")"
APP_DIR="$ROOT_DIR/dist/UMA.app"
LEGACY_APP_DIR="$ROOT_DIR/dist/Unmount All.app"
CONTENTS_DIR="$APP_DIR/Contents"
ASSET_CATALOG="$ROOT_DIR/Assets/Assets.xcassets"
VERSION_FILE="$ROOT_DIR/VERSION"
BUILD_NUMBER_FILE="$ROOT_DIR/BUILD_NUMBER"
XCODE_VERSION_CONFIG="$ROOT_DIR/Config/Version.xcconfig"
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
SWIFT_BIN_DIR="$(
    CLANG_MODULE_CACHE_PATH="$BUILD_DIR/ModuleCache" \
    SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_DIR/ModuleCache" \
    /usr/bin/xcrun swift build \
        --configuration release \
        --arch arm64 \
        --scratch-path "$BUILD_DIR" \
        --show-bin-path
)"
CLANG_MODULE_CACHE_PATH="$BUILD_DIR/ModuleCache" \
SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_DIR/ModuleCache" \
/usr/bin/xcrun swift build \
    --configuration release \
    --arch arm64 \
    --scratch-path "$BUILD_DIR"

/bin/rm -rf "$APP_DIR"
/bin/mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
/usr/bin/ditto "$SWIFT_BIN_DIR/UnmountAll" "$CONTENTS_DIR/MacOS/UMA"
/usr/bin/ditto "$ROOT_DIR/uma.sh" "$CONTENTS_DIR/Resources/uma.sh"
/usr/bin/xcrun actool "$ASSET_CATALOG" \
    --compile "$CONTENTS_DIR/Resources" \
    --output-format human-readable-text \
    --warnings \
    --notices \
    --app-icon AppIcon \
    --enable-on-demand-resources NO \
    --development-region en \
    --target-device mac \
    --minimum-deployment-target 26.0 \
    --platform macosx \
    --bundle-identifier ee.music.UMA \
    --output-partial-info-plist "$BUILD_DIR/asset-info.plist"
/bin/chmod 755 "$CONTENTS_DIR/MacOS/UMA" "$CONTENTS_DIR/Resources/uma.sh"

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
/bin/mkdir -p "${XCODE_VERSION_CONFIG%/*}"
/usr/bin/printf 'MARKETING_VERSION = %s\nCURRENT_PROJECT_VERSION = %s\n' \
    "$APP_VERSION" "$APP_BUILD" >"$XCODE_VERSION_CONFIG"

if [ -d "$LEGACY_APP_DIR" ]; then
    /bin/rm -rf "$LEGACY_APP_DIR"
fi

/usr/bin/printf 'Built: %s (version %s, build %s)\n' "$APP_DIR" "$APP_VERSION" "$APP_BUILD"
