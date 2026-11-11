#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .vendor
archive=".vendor/openlist-darwin-arm64-lite.tar.gz"
expected="a4241527f1f74e786ec33accb3cebc7008ea1ba5717a462b0af23a1ac6565e88"
if [ ! -f "$archive" ]; then
    curl -fL --retry 2 --connect-timeout 15 --max-time 240 \
        "https://github.com/OpenListTeam/OpenList/releases/download/v4.2.9/openlist-darwin-arm64-lite.tar.gz" \
        -o "$archive.part"
    mv "$archive.part" "$archive"
fi
actual="$(shasum -a 256 "$archive" | cut -d ' ' -f 1)"
if [ "$actual" != "$expected" ]; then
    printf 'OpenList download checksum mismatch.\n' >&2
    exit 1
fi
tar -xzf "$archive" -C .vendor openlist
chmod 755 .vendor/openlist
source_archive=".vendor/OpenList-v4.2.9-source.tar.gz"
source_expected="a762ff50b71b384f03af2996cac2aba471b0d5ec44aad0255e646a41c8af7f49"
if [ ! -f "$source_archive" ]; then
    curl -fL --retry 2 --connect-timeout 15 --max-time 120 \
        "https://codeload.github.com/OpenListTeam/OpenList/tar.gz/refs/tags/v4.2.9" \
        -o "$source_archive.part"
    mv "$source_archive.part" "$source_archive"
fi
source_actual="$(shasum -a 256 "$source_archive" | cut -d ' ' -f 1)"
if [ "$source_actual" != "$source_expected" ]; then
    printf 'OpenList source checksum mismatch.\n' >&2
    exit 1
fi
tar -xOf "$source_archive" OpenList-4.2.9/LICENSE > .vendor/OpenList-LICENSE
printf 'OpenList v4.2.9 binary and corresponding source verified (SHA-256).\n'
