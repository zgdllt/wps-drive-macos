#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -x .vendor/openlist ] || [ ! -f .vendor/OpenList-LICENSE ] ||
   [ ! -f .vendor/OpenList-v4.2.9-source.tar.gz ]; then
    printf 'Run bash scripts/fetch-engine.sh before building.\n' >&2
    exit 1
fi
bash scripts/build-icon.sh
app="$PWD/dist/WPS Drive.app"
provider="$app/Contents/PlugIns/WPSDriveProvider.appex"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" \
    "$provider/Contents/MacOS" "$provider/Contents/Resources"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/Provider-Info.plist "$provider/Contents/Info.plist"
cp .build/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp .build/AppIcon.icns "$provider/Contents/Resources/AppIcon.icns"
cp .build/AppIcon.png "$app/Contents/Resources/AppIcon.png"
cp .build/AppIcon.png "$provider/Contents/Resources/AppIcon.png"
cp LICENSE THIRD_PARTY_NOTICES.md "$app/Contents/Resources/"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 -parse-as-library \
    Sources/EngineHost/main.swift -o "$app/Contents/MacOS/WPSDriveEngineHost"
codesign --force --sign - "$app/Contents/MacOS/WPSDriveEngineHost"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 \
    -module-name WPSDriveProvider -parse-as-library \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -framework FileProvider -framework UniformTypeIdentifiers \
    Sources/DriveCore/*.swift Sources/Native/*.swift Sources/Provider/*.swift \
    -o "$provider/Contents/MacOS/WPSDriveProvider"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 \
    -parse-as-library \
    -framework AppKit -framework FileProvider -framework WebKit \
    Sources/DriveCore/*.swift Sources/Native/*.swift Sources/App/*.swift \
    -o "$app/Contents/MacOS/WPSDrive"
cp .vendor/openlist "$app/Contents/MacOS/openlist"
cp .vendor/OpenList-LICENSE "$app/Contents/Resources/OpenList-LICENSE"
cp .vendor/OpenList-v4.2.9-source.tar.gz "$app/Contents/Resources/"
codesign --force --sign - "$app/Contents/MacOS/openlist"
codesign --force --sign - --entitlements Resources/Provider.entitlements "$provider"
codesign --force --sign - --entitlements Resources/App.entitlements "$app"
codesign --verify --deep --strict "$app"
# Icon Services uses the bundle directory's modification time when updating icons.
touch "$provider" "$app"
printf 'Built: %s\n' "$app"
