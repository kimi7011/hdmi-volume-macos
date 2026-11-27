#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
output="${1:-$PWD/dist}"
mkdir -p "$output"
output="$(cd "$output" && pwd -P)"
./build-app.sh "$output"
./Driver/build.sh "$output"
install -m 755 Packaging/安裝.command Packaging/移除.command "$output"
