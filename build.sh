#!/bin/bash
set -euo pipefail

project="$(cd "$(dirname "$0")" && pwd)"
output="${1:-$project/build}"
work="$(mktemp -d "${TMPDIR:-/tmp}/md-switcher-build.XXXXXX")"
incoming=""
trap 'rm -rf "$work"; if [[ -n "$incoming" ]]; then rm -rf "$incoming"; fi' EXIT
staged="$work/MD Switcher.app"
app="$output/MD Switcher.app"

mkdir -p "$staged/Contents/MacOS" "$output"
cp "$project/Info.plist" "$staged/Contents/Info.plist"
iconset="$work/AppIcon.iconset"
mkdir -p "$iconset" "$staged/Contents/Resources"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$project/assets/AppIcon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -z "$((size * 2))" "$((size * 2))" "$project/assets/AppIcon.png" \
        --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil --convert icns --output "$staged/Contents/Resources/AppIcon.icns" "$iconset"
pack="$project/build/sky-striker"
if [[ "${MD_INCLUDE_PRIVATE_PACK:-1}" == 1 && -f "$pack/manifest.json" ]]; then
    resources="$staged/Contents/Resources/SkyStriker"
    mkdir -p "$resources"
    for file in "$pack"/manifest.json "$pack"/*.jpg "$pack"/*.bundle; do
        ditto --norsrc --noextattr --noacl "$file" "$resources/${file##*/}"
    done
fi
python="/usr/bin/python3"
abi="$("$python" -c 'import sys; print(sys.implementation.cache_tag)')"
python_packages="$project/build/card-search-python-$abi.zip"
if [[ ! -f "$python_packages" ]]; then
    "$python" -m pip --disable-pip-version-check install --only-binary=:all: --no-compile \
        --target "$work/card-search-site" "UnityPy==1.23.0"
    "$python" -m zipfile -c "$work/site.zip" "$work/card-search-site"
    cp "$work/site.zip" "$python_packages"
fi
search_resources="$staged/Contents/Resources/CardSearch"
mkdir -p "$search_resources"
cp "$python_packages" "$search_resources/site.zip"
cp "$project"/Scripts/{card_search,generate_sky_striker,summon_animation,over_frame}.py "$search_resources"
"$project/RoyalFinish/build.sh" "$staged/Contents/Resources/RoyalFinish"
xcrun swiftc -swift-version 5 -target arm64-apple-macos13.0 \
    -module-cache-path "$work/cache" -O "$project"/Sources/*.swift \
    -o "$staged/Contents/MacOS/MD Switcher"
codesign --force --sign - "$staged"
# Sign on the system volume, then copy without AppleDouble metadata on external drives.
incoming="$(mktemp -d "$output/.md-switcher-install.XXXXXX")"
ditto --norsrc --noextattr --noacl "$staged" "$incoming/MD Switcher.app"
codesign --verify --strict "$incoming/MD Switcher.app"
if [[ -e "$app" ]]; then mv "$app" "$incoming/previous.app"; fi
if ! mv "$incoming/MD Switcher.app" "$app"; then
    if [[ -e "$incoming/previous.app" ]] && ! mv "$incoming/previous.app" "$app"; then
        printf 'Previous build retained at %s\n' "$incoming/previous.app" >&2
        incoming=""
    fi
    exit 1
fi
printf '%s\n' "$app"
