#!/bin/bash
set -euo pipefail

if [[ "$#" -lt 1 || "$#" -gt 2 || ( "$#" == 2 && "$2" != --mte ) ]]; then
  printf 'Usage: %s <path to HDMIVolume.driver> [--mte]\n' "$0" >&2
  exit 2
fi

source_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
driver="$(cd -- "$1" && pwd -P)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/hdmi-volume-test.XXXXXXXX")"
trap 'rm -rf -- "$test_dir"' EXIT
sources=("$source_dir/Tests/DriverTests.c")
if [[ "${2:-}" == --mte ]]; then
  sources+=("$source_dir/Tests/MemoryTaggingCheck.c")
fi

xcrun clang -Wall -Wextra -Werror "${sources[@]}" \
  -framework CoreAudio -framework CoreFoundation -o "$test_dir/DriverTests"
if [[ "${2:-}" == --mte ]]; then
  codesign --force --sign - --entitlements "$source_dir/Tests/MemoryTagging.entitlements" "$test_dir/DriverTests"
fi
"$test_dir/DriverTests" "$driver"
