#!/usr/bin/env bash
# Mac dev loop: wait for the CI build of the pushed HEAD, install it to /Applications, relaunch.
# Local `swift build` needs full Xcode (SwiftUI's @State macro plugin isn't in the Command Line Tools),
# so GitHub Actions is the compiler. Usage: git push && bash scripts/try_latest.sh
set -euo pipefail
cd "$(dirname "$0")/.."
REPO=shiccupagent/snip-for-mac
SHA="$(git rev-parse HEAD)"

echo "Waiting for the CI build of ${SHA::7}..."
for i in $(seq 1 60); do
  STATE="$(gh run list -R "$REPO" -w build.yml --commit "$SHA" -L 1 --json status,conclusion -q '.[0] | "\(.status) \(.conclusion)"' 2>/dev/null || true)"
  case "$STATE" in
    "completed success") break ;;
    completed*) echo "CI build failed: $STATE"; gh run list -R "$REPO" --commit "$SHA" -L 1; exit 1 ;;
  esac
  [ "$i" = 60 ] && { echo "Timed out waiting for CI (5 min)"; exit 1; }
  sleep 5
done

# The release is replaced after the build job's last step; confirm it was built from this commit.
for i in $(seq 1 24); do
  TARGET="$(gh release view latest -R "$REPO" --json targetCommitish -q .targetCommitish 2>/dev/null || true)"
  [ "$TARGET" = "$SHA" ] && break
  [ "$i" = 24 ] && { echo "Release 'latest' is at ${TARGET::7}, not ${SHA::7}"; exit 1; }
  sleep 5
done

DL="$(mktemp -d)"
gh release download latest -R "$REPO" -p Snip.zip -D "$DL"
ditto -x -k "$DL/Snip.zip" "$DL/x"
codesign --verify "$DL/x/Snip.app"

pkill -x Snip || true
for i in $(seq 1 20); do pgrep -x Snip >/dev/null || break; sleep 0.5; done
rm -rf /Applications/Snip.app
ditto "$DL/x/Snip.app" /Applications/Snip.app
rm -rf "$DL"
open /Applications/Snip.app
echo "Installed and launched Snip $(defaults read /Applications/Snip.app/Contents/Info.plist CFBundleShortVersionString) from ${SHA::7}"
