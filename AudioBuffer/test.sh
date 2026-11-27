#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/hdmivolume-audio-test.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
clang -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
  -fsanitize=address,undefined HDMIRing.c test.c -o "$test_dir/tests"
"$test_dir/tests"
