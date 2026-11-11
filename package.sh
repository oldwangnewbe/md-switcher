#!/bin/bash
set -euo pipefail

project="$(cd "$(dirname "$0")" && pwd)"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$project/Info.plist")"
work="$(mktemp -d "${TMPDIR:-/tmp}/md-switcher-dmg.XXXXXX")"
trap 'rm -rf "$work"' EXIT
staging="$work/payload"
output="$project/build/MD-Switcher-$version-arm64.dmg"
MD_INCLUDE_PRIVATE_PACK=0 "$project/build.sh" "$staging"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "MD Switcher $version" -srcfolder "$staging" -fs HFS+ -format UDZO "$work/release.dmg"
hdiutil verify "$work/release.dmg"
mv -f "$work/release.dmg" "$output"
printf '%s\n' "$output"
