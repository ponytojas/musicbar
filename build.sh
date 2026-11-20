#!/bin/zsh
# Builds MusicBar.app into ./build
#
#   ./build.sh                 release build for this Mac
#   ./build.sh --universal     release build for Apple silicon and Intel
#   ./build.sh --debug         debug build (faster to compile, debuggable)
#   ./build.sh --run           build, then relaunch the app
#
# Options combine, e.g. ./build.sh --debug --run
set -e
cd "$(dirname "$0")"

CONFIG=release
UNIVERSAL=0
RUN=0
for arg in "$@"; do
    case "$arg" in
        --debug) CONFIG=debug ;;
        --universal) UNIVERSAL=1 ;;
        --run) RUN=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

# Bare CommandLineTools fails to compile SPM manifests on this machine;
# force a full Xcode toolchain.
if [[ -z "$DEVELOPER_DIR" && "$(xcode-select -p)" == *CommandLineTools* ]]; then
    export DEVELOPER_DIR="$(ls -d /Applications/Xcode*.app/Contents/Developer 2>/dev/null | sort -V | tail -1)"
fi

BUILD_ARGS=(-c "$CONFIG")
if (( UNIVERSAL )); then
    BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi
swift build "${BUILD_ARGS[@]}"
BINARY="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/MusicBar"

APP=build/MusicBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/MusicBar"
cp Info.plist "$APP/Contents/Info.plist"
# Only what the app loads at run time; the icon's sources stay out.
cp -R Resources/*.lproj Resources/AppIcon.icns "$APP/Contents/Resources/"

# The layered icon (Liquid Glass on macOS 26) needs Xcode 26's actool.
# Without it the app keeps the flat AppIcon.icns copied above.
ICON_TMP="$(mktemp -d)"
if xcrun actool Resources/AppIcon.icon --compile "$ICON_TMP" --app-icon AppIcon \
    --platform macosx --minimum-deployment-target 14.2 \
    --output-partial-info-plist "$ICON_TMP/partial.plist" >/dev/null 2>&1 \
    && [[ -f "$ICON_TMP/Assets.car" ]]; then
    cp "$ICON_TMP/Assets.car" "$APP/Contents/Resources/Assets.car"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "$APP/Contents/Info.plist"
else
    echo "Note: actool couldn't compile AppIcon.icon; using AppIcon.icns only."
fi
rm -rf "$ICON_TMP"

# Version from the latest vX.Y tag, build number from the commit count.
VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleShortVersionString ${VERSION:-1.0}" \
    -c "Set :CFBundleVersion $BUILD" \
    "$APP/Contents/Info.plist"

# Ad-hoc signing (the default) changes the code hash on every build, so
# macOS may ask for Automation/audio permissions again. Set SIGN_ID to a
# stable identity (e.g. an "Apple Development" or self-signed certificate)
# to keep those grants across rebuilds.
codesign --force --sign "${SIGN_ID:--}" "$APP"

echo "Built $APP ($CONFIG, $(lipo -archs "$APP/Contents/MacOS/MusicBar"))"

if (( RUN )); then
    # Quit a running copy first, or `open` would only bring it forward.
    pkill -x MusicBar 2>/dev/null && sleep 0.5 || true
    open "$APP"
else
    echo "Run with: open $APP"
fi
