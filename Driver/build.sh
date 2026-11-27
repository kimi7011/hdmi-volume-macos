#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  printf 'Usage: %s <output directory>\n' "$0" >&2
  exit 2
fi

source_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
mkdir -p -- "$1"
output_dir="$(cd -- "$1" && pwd -P)"
build_dir="$(mktemp -d "$output_dir/.hdmi-volume-driver.XXXXXXXX")"
trap 'rm -rf -- "$build_dir"' EXIT

scratch_dir="${HDMI_SWIFT_SCRATCH_PATH:-$source_dir/.build}"
swift_build=(swift build --package-path "$source_dir" --scratch-path "$scratch_dir" --configuration release)
"${swift_build[@]}" --product HDMIVolume
bin_dir="$("${swift_build[@]}" --show-bin-path)"

bundle="$build_dir/HDMIVolume.driver"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$source_dir/Info.plist" "$bundle/Contents/Info.plist"
cp "$source_dir/LICENSE.md" "$source_dir/NOTICE.md" "$bundle/Contents/Resources/"
cp "$source_dir/../LICENSE" "$bundle/Contents/Resources/Apache-2.0.txt"
cp "$scratch_dir/checkouts/swift-atomics/LICENSE.txt" "$bundle/Contents/Resources/SwiftAtomics-LICENSE.txt"
cp "$bin_dir/libHDMIVolume.dylib" "$bundle/Contents/MacOS/HDMIVolume"
/usr/bin/codesign --force --sign "${HDMI_VOLUME_SIGN_IDENTITY:--}" "$bundle"
/usr/bin/codesign --verify --strict "$bundle"
rm -rf -- "$output_dir/HDMIVolume.driver"
mv -- "$bundle" "$output_dir/HDMIVolume.driver"
printf '%s\n' "$output_dir/HDMIVolume.driver"
