#!/bin/sh
# Build "KVM Serial Native.app" into build/ and ad-hoc sign it.
set -eu

cd "$(dirname "$0")/.."
APP="build/KVM Serial Native.app"
VERSION=$(cat VERSION)

swift build -c release
BIN=$(swift build -c release --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/KVMSerial" "$APP/Contents/MacOS/KVMSerial"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"

codesign --force --sign - --options runtime \
    --entitlements Resources/KVMSerial.entitlements "$APP"

echo "Built $APP ($VERSION)"
