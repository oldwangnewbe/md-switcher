#!/bin/bash
set -euo pipefail

project="$(cd "$(dirname "$0")" && pwd)"
temp="$(mktemp -d "${TMPDIR:-/tmp}/md-switcher-tests.XXXXXX")"
trap 'rm -rf "$temp"' EXIT

xcrun swiftc -swift-version 5 -module-cache-path "$temp/cache" \
    "$project"/Sources/{SteamFiles,CrossOver,InstallationPaths,Switcher,ResourceReuse,GameSettings,SkyStrikerMod,CardSearch,ArtworkCollection,SummonAnimation,RoyalFinish,SteamRoyalFinishMonitor}.swift \
    "$project/Tests/CoreChecks.swift" -o "$temp/check"
"$temp/check"
