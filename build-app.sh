#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
output="${1:-$PWD/dist}"
mkdir -p "$output"
output="$(cd "$output" && pwd -P)"
temp="$(mktemp -d "${TMPDIR:-/tmp}/hdmi-volume-build.XXXXXX")"
trap 'rm -rf "$temp"' EXIT
name='HDMI Volume'
if [[ "${2:-}" == '--mixer-prototype' ]]; then
    name='HDMI Volume Mixer Prototype'
fi
app="$temp/$name.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
xcrun clang -arch arm64 -mmacosx-version-min=14.2 -std=c11 -O2 -Wall -Wextra -Werror \
    -c AudioBuffer/HDMIRing.c -o "$temp/HDMIRing.o"
xcrun swiftc -target arm64-apple-macos14.2 -O \
    -import-objc-header AudioBuffer/HDMIRing.h Sources/*.swift "$temp/HDMIRing.o" \
    -framework AppKit -framework AudioToolbox -framework CoreAudio \
    -o "$app/Contents/MacOS/HDMIVolume"
cp Sources/Info.plist "$app/Contents/Info.plist"
if [[ "$name" == 'HDMI Volume Mixer Prototype' ]]; then
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.hdmivolume.mixerprototype' \
        -c 'Set :CFBundleName HDMI Volume Mixer Prototype' \
        -c 'Set :CFBundleDisplayName HDMI Volume Mixer Prototype' \
        -c 'Set :CFBundleShortVersionString 0.3.0' -c 'Set :CFBundleVersion 6' \
        -c 'Add :HDMIVolumeMixerPrototype bool true' "$app/Contents/Info.plist"
fi
xcrun swift Assets/RenderAppIcon.swift "$temp/AppIcon.iconset"
iconutil -c icns "$temp/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
install -m 755 Packaging/activate-at-login.sh "$app/Contents/Resources/activate-at-login.sh"
codesign --force --sign "${HDMI_SIGNING_IDENTITY:--}" "$app"
codesign --verify --strict "$app"
ditto "$app" "$output/$name.app"
