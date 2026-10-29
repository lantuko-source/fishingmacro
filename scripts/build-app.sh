#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist
# Stage outside synced Documents folders: File Provider can add FinderInfo to
# .app directories after signing. The ZIP contains only the signed file data.
stage="$(mktemp -d "${TMPDIR%/}/fishingmacro.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/Fishing Macro.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
if [[ "${1:-}" == "--debug" ]]; then
    swift build --build-system native --product FishingMacro
    cp .build/debug/FishingMacro "$app/Contents/MacOS/FishingMacro"
else
    for arch in arm64 x86_64; do
        swift build --build-system native --configuration release --product FishingMacro --triple "$arch-apple-macosx14.0"
    done
    xcrun lipo -create .build/arm64-apple-macosx/release/FishingMacro .build/x86_64-apple-macosx/release/FishingMacro -output "$app/Contents/MacOS/FishingMacro"
fi
cp Resources/Info.plist "$app/Contents/Info.plist"
swift scripts/icon.swift dist/AppIcon.iconset
iconutil -c icns dist/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"
# Finder/File Provider may attach FinderInfo to a newly created local bundle.
# Remove only signing-incompatible metadata; preserve quarantine/security flags.
xattr -dr com.apple.FinderInfo "$app" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$app" 2>/dev/null || true
codesign --force --sign - --identifier com.lantuko.fishingmacro "$app"
codesign --verify --deep --strict "$app"
ditto -c -k --norsrc --noextattr --keepParent "$app" "dist/FishingMacro.zip"
ditto --norsrc --noextattr "$app" "dist/Fishing Macro.app"
echo "Built dist/Fishing Macro.app and dist/FishingMacro.zip"
