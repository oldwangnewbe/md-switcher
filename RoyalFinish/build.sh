#!/bin/bash
set -euo pipefail

source_dir="$(cd "$(dirname "$0")" && pwd)"
output="$1"
cache="${MD_ROYAL_BUILD_CACHE:-$HOME/Library/Caches/MD Switcher Build/RoyalFinish}"
mkdir -p "$cache" "$output"
work="$(mktemp -d "${TMPDIR:-/tmp}/md-royal-build.XXXXXX")"
trap 'rm -rf "$work"' EXIT
toolchain=llvm-mingw-20260616-ucrt-macos-universal
minhook=minhook-1.3.4
compiler="$cache/$toolchain/bin/x86_64-w64-mingw32-clang"

download() {
    curl --retry 2 -fsSL "$1" -o "$work/archive"
    printf '%s  %s\n' "$2" "$work/archive" | shasum -a 256 -c
    tar -xf "$work/archive" -C "$work"
    mv "$work/$3" "$cache/"
}

if [[ ! -x "$compiler" ]]; then
    download "https://github.com/mstorsjo/llvm-mingw/releases/download/20260616/$toolchain.tar.xz" \
        2cab02a2e964bd4aae981150a45985d07c657cfa8d244959eb9e2dcc5eedd7b1 "$toolchain"
fi
if [[ ! -f "$cache/$minhook/include/MinHook.h" ]]; then
    download "https://codeload.github.com/TsudaKageyu/minhook/tar.gz/refs/tags/v1.3.4" \
        1aebeae4ca898330c507860acc2fca2eb335fe446a3a2b8444c3bf8b2660a14e "$minhook"
fi

mh="$cache/$minhook"
"$compiler" -std=c17 -O2 -Wall -Wextra -Werror -shared -I"$mh/include" "$source_dir/renderer.c" \
    "$mh/src/hook.c" "$mh/src/buffer.c" "$mh/src/trampoline.c" "$mh/src/hde/hde64.c" -o "$output/MDRoyalFinish.dll"
"$compiler" -std=c17 -O2 -Wall -Wextra -Werror -municode "$source_dir/loader.c" -o "$output/MDRoyalLoader.exe"
cp "$mh/LICENSE.txt" "$output/MinHook-LICENSE.txt"
