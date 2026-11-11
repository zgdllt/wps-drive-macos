#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

source_icon=".build/AppIcon.png"
iconset=".build/AppIcon.iconset"
mkdir -p "$iconset"
xcrun swift scripts/RenderIcon.swift "$source_icon"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$source_icon" \
        --out "$iconset/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" "$source_icon" \
        --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o .build/AppIcon.icns
printf 'Built: .build/AppIcon.icns\n'
