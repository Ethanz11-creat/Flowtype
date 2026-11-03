#!/bin/bash
set -euo pipefail
[ "$#" -eq 0 ] || exit 64
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
APP="$ROOT/build/FlowType.app"
MANIFEST="$ROOT/build/FlowType.manifest.json"
[ -d "$APP" ] && [ -f "$MANIFEST" ] || { echo 'Matching candidate and manifest required' >&2; exit 1; }
VERSION=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")
NUMBER=$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist")
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
[ "$VERSION" = "$(/usr/bin/plutil -extract buildInfo.version raw -o - "$MANIFEST")" ] || exit 1
[ "$NUMBER" = "$(/usr/bin/plutil -extract buildInfo.buildNumber raw -o - "$MANIFEST")" ] || exit 1
TEMP=$(mktemp -d)
trap 'rm -rf "$TEMP"' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
/usr/bin/swift "$ROOT/scripts/write-artifact-manifest.swift" --app "$APP" --output "$TEMP/verified.json"
/usr/bin/cmp -s "$MANIFEST" "$TEMP/verified.json" || { echo 'Candidate identity/hash mismatch' >&2; exit 1; }
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
mkdir "$TEMP/image"
cp -R "$APP" "$TEMP/image/"
ln -s /Applications "$TEMP/image/Applications"
/usr/bin/hdiutil create -volname FlowType -srcfolder "$TEMP/image" -ov -format UDZO "$ROOT/build/FlowType-$VERSION.dmg"
echo "FlowType-$VERSION.dmg created locally"
