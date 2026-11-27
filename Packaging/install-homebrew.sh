#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -e '/Applications/HDMI Volume.app' || -e '/Library/Audio/Plug-Ins/HAL/HDMIVolume.driver' ]]; then
    echo '已找到 HDMI 音量控制。請先執行原安裝資料夾內的「移除.command」。' >&2
    exit 1
fi

sdk="$(/usr/bin/xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)"
if [[ -z "$sdk" || "${sdk%%.*}" -lt 26 ]]; then
    echo '請安裝含 macOS 26 或更新 SDK 的 Xcode Command Line Tools，再重新執行 brew install。' >&2
    exit 1
fi

temp="$(mktemp -d "${TMPDIR:-/tmp}/hdmi-volume-homebrew.XXXXXX")"
trap 'rm -rf "$temp"' EXIT
HDMI_SWIFT_SCRATCH_PATH="$temp/swift" ./build.sh "$temp/dist"
"$temp/dist/安裝.command" --no-launch
