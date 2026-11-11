#!/bin/bash
set -euo pipefail

project="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/md-win-release.XXXXXX")"
trap 'rm -rf "$work"' EXIT
dotnet="${DOTNET_EXE:-dotnet}"
python="${PYTHON_EXE:-python3}"
version=3.13.17
engine="$work/package/CardEngine"
mkdir -p "$engine" "$project/build"

curl --retry 2 -fsSL "https://www.python.org/ftp/python/$version/python-$version-embed-amd64.zip" -o "$work/python.zip"
printf '%s  %s\n' '9e35319bffedab8b36ad44d8f377cb4f1733bcec257a0b6d04d94f01486ddb38' "$work/python.zip" | shasum -a 256 -c
unzip -q "$work/python.zip" -d "$engine"
printf 'python313.zip\n.\nsite\nimport site\n' > "$engine/python313._pth"
"$python" -m pip --disable-pip-version-check install --platform win_amd64 --python-version 3.13 \
    --implementation cp --abi cp313 --only-binary=:all: --no-compile --target "$engine/site" \
    -r "$project/Windows/card-engine-requirements.txt"
cp "$project"/Scripts/{card_search,generate_sky_striker}.py "$engine/"

"$dotnet" publish "$project/Windows/MDSwitcher.Windows.csproj" -c Release -r win-x64 --self-contained true \
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true \
    --artifacts-path "$work/artifacts" -o "$work/app"
cp "$work/app/MD Switcher.exe" "$work/package/"
cp "$project/Windows/README.md" "$work/package/"
name=MD-Switcher-Windows-x64-0.2.zip
(cd "$work/package" && zip -q -r -X "$work/$name" 'MD Switcher.exe' README.md CardEngine -x '*/._*')
unzip -tq "$work/$name"
mv "$work/$name" "$project/build/$name"
printf '%s\n' "$project/build/$name"
