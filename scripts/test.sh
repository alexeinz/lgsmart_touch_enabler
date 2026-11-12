#!/bin/bash
# Runs the unit tests. With Command Line Tools only (no Xcode) Swift Testing needs extra search paths.
set -euo pipefail
cd "$(dirname "$0")/.."
CLT=/Library/Developer/CommandLineTools
F="$CLT/Library/Developer/Frameworks"
if [ -d "$F" ] && ! xcode-select -p | grep -q Xcode; then
  exec swift test \
    -Xswiftc -F -Xswiftc "$F" \
    -Xswiftc -plugin-path -Xswiftc "$CLT/usr/lib/swift/host/plugins/testing" \
    -Xlinker -F -Xlinker "$F" -Xlinker -rpath -Xlinker "$F" "$@"
fi
exec swift test "$@"
