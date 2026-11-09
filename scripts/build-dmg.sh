#!/bin/sh
# Build "KVM Serial Native.app" and package it as a drag-to-install DMG in
# build/. Uses only built-in tools (hdiutil), no Homebrew create-dmg.
set -eu

cd "$(dirname "$0")/.."
APP_NAME="KVM Serial Native.app"
VERSION=$(cat VERSION)
ARCH=$(uname -m)
case "$ARCH" in
    arm64) ARCH_LABEL=AppleSilicon ;;
    *) ARCH_LABEL=Intel ;;
esac
DMG="build/KVM-Serial-Native-$VERSION-macOS-$ARCH_LABEL.dmg"

./scripts/build-app.sh

# Stage the app next to an Applications link so the volume shows the usual
# drag-to-install layout.
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
cp -R "build/$APP_NAME" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -volname "KVM Serial Native" -srcfolder "$STAGING" \
    -fs HFS+ -format UDZO -imagekey zlib-level=9 -quiet "$DMG"
hdiutil verify -quiet "$DMG"

echo "Built $DMG"
