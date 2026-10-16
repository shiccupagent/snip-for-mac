#!/bin/bash
# Tests the speedrun timer's rules and the LiveSplit .lss reader/writer. Foundation only, so it
# runs with just the Command Line Tools (unlike the full app build).
set -euo pipefail
cd "$(dirname "$0")/.."
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O Sources/Snip/Speedrun/Splits.swift Sources/Snip/Speedrun/SpeedrunTimer.swift Sources/Snip/Speedrun/RunLog.swift Sources/Snip/Recording/TimelineEdit.swift Tests/speedrun/main.swift -o "$out/test"
"$out/test" Tests/speedrun/sample.lss
