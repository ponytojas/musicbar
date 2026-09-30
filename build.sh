#!/bin/zsh
# Builds MusicBar.app into ./build
set -e
cd "$(dirname "$0")"

# Bare CommandLineTools fails to compile SPM manifests on this machine;
# force a full Xcode toolchain.
if [[ -z "$DEVELOPER_DIR" && "$(xcode-select -p)" == *CommandLineTools* ]]; then
    export DEVELOPER_DIR="$(ls -d /Applications/Xcode*.app/Contents/Developer 2>/dev/null | sort -V | tail -1)"
fi

swift build -c release

APP=build/MusicBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/MusicBar "$APP/Contents/MacOS/MusicBar"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp -R Resources/ "$APP/Contents/Resources/"

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

echo "Built $APP"
echo "Run with: open $APP"
