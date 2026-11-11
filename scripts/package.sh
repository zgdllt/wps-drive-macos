#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

app="$PWD/dist/WPS Drive.app"
release="$PWD/dist/release"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
source_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
if [ "$version" != "$source_version" ]; then
    printf 'Rebuild the app before packaging this source version.\n' >&2
    exit 1
fi
codesign --verify --deep --strict "$app"
test -f "$app/Contents/Resources/OpenList-v4.2.9-source.tar.gz"
mkdir -p "$release" .build
staging=$(mktemp -d "$PWD/.build/release-XXXXXX")
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/WPS Drive.app"
ln -s /Applications "$staging/Applications"
cp docs/INSTALL.md "$staging/安装说明.md"
name="WPS-Drive-v${version}-macos-arm64"
ditto -c -k --sequesterRsrc --keepParent "$app" "$release/$name.zip"
hdiutil create -ov -volname "WPS Drive" -srcfolder "$staging" \
    -format UDZO "$release/$name.dmg"
hdiutil verify "$release/$name.dmg"
(
    cd "$release"
    shasum -a 256 "$name.dmg" "$name.zip" > SHA256SUMS
    shasum -a 256 -c SHA256SUMS
)
printf 'Release files: %s\n' "$release"
