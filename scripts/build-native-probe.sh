#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

app="$PWD/dist/WPS Native Probe.app"
provider="$app/Contents/PlugIns/NativeProbe.appex"
entitlements="$PWD/.build/native-probe-provider.entitlements"
mkdir -p "$app/Contents/MacOS" "$provider/Contents/MacOS" "$PWD/.build"
if [ -f "$app/provider.entitlements" ]; then
    rm "$app/provider.entitlements"
fi
cp Resources/Info.plist "$app/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string io.github.zgdllt.WPSDrive.NativeProbe "$app/Contents/Info.plist"
plutil -replace CFBundleName -string 'WPS Native Probe' "$app/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string 'WPS Native Probe' "$app/Contents/Info.plist"
plutil -replace CFBundleExecutable -string NativeProbe "$app/Contents/Info.plist"
cp Resources/Provider-Info.plist "$provider/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string io.github.zgdllt.WPSDrive.NativeProbe.Provider "$provider/Contents/Info.plist"
plutil -replace CFBundleExecutable -string NativeProbeProvider "$provider/Contents/Info.plist"
plutil -replace NSExtension.NSExtensionPrincipalClass -string NativeProbeProvider.ProbeProvider "$provider/Contents/Info.plist"
plutil -remove NSExtension.NSExtensionFileProviderActions "$provider/Contents/Info.plist"
cp Resources/Provider.entitlements "$entitlements"
xcrun swiftc -swift-version 5 -target arm64-apple-macos13.0 -parse-as-library \
    -module-name NativeProbeProvider -Xlinker -e -Xlinker _NSExtensionMain \
    -framework FileProvider -framework UniformTypeIdentifiers \
    Tests/NativeProbe/Provider.swift -o "$provider/Contents/MacOS/NativeProbeProvider"
xcrun swiftc -swift-version 5 -target arm64-apple-macos13.0 -parse-as-library \
    -framework AppKit -framework FileProvider Tests/NativeProbe/Host.swift \
    -o "$app/Contents/MacOS/NativeProbe"
codesign --force --sign - --entitlements "$entitlements" "$provider"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
printf 'Built: %s\n' "$app"
