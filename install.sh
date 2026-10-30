#!/bin/zsh
# Sleepwalk / 梦游 — build from source and install to ~/Applications.
# Needs a Swift compiler: the Xcode Command Line Tools (xcode-select --install) are enough.
set -e
cd "$(dirname "$0")"
APP="build/Sleepwalk.app"
MIN=13.0

# Use the selected toolchain if it works. If not (for example Xcode is selected
# but its license was never accepted), fall back to the Command Line Tools.
if ! xcrun swiftc --version >/dev/null 2>&1; then
  if [ -x /Library/Developer/CommandLineTools/usr/bin/swiftc ]; then
    export DEVELOPER_DIR=/Library/Developer/CommandLineTools
  fi
fi
if ! xcrun swiftc --version >/dev/null 2>&1; then
  echo "Can't run the Swift compiler."
  echo "Install the Command Line Tools:  xcode-select --install"
  echo "If Xcode says its license isn't accepted:  sudo xcodebuild -license accept"
  exit 1
fi

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/"
cp -R Resources/ "$APP/Contents/Resources/"

# Universal binary: Apple silicon + Intel, macOS 13 or later
for arch in arm64 x86_64; do
  xcrun swiftc -O -swift-version 5 -target $arch-apple-macos$MIN main.swift -o build/Sleepwalk-$arch
done
xcrun lipo -create build/Sleepwalk-arm64 build/Sleepwalk-x86_64 -output "$APP/Contents/MacOS/Sleepwalk"

# Ad-hoc signature: enough for an app you built yourself on this Mac
codesign --force -s - "$APP"

# Replace a running copy. The new copy reads the current sleep setting when it opens.
pkill -x Sleepwalk || true
mkdir -p ~/Applications
rm -rf ~/Applications/Sleepwalk.app
ditto "$APP" ~/Applications/Sleepwalk.app
# Remove the build output so Spotlight doesn't find a second copy of the app
rm -rf build
open ~/Applications/Sleepwalk.app
echo "Installed: ~/Applications/Sleepwalk.app"
