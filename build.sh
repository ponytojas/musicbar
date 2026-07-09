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

# Ad-hoc signature keeps the Automation (Apple Events) permission stable.
codesign --force --sign - "$APP"

echo "Built $APP"
echo "Run with: open $APP"
