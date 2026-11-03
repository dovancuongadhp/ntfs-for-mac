#!/bin/bash
# Packages the app into a drag-to-install disk image: the app, an Applications
# alias and a background with an arrow between them.
# Usage: scripts/make-dmg.sh [path/to/NTFS for Mac.app] [output.dmg]
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-build/DerivedData/Build/Products/Release/NTFS for Mac.app}"
DMG="${2:-build/NTFS-for-Mac.dmg}"
VOLUME_NAME="NTFS for Mac"
APP_NAME="$(basename "$APP")"

if [[ ! -d "$APP" ]]; then
    echo "error: $APP not found. Build it first, e.g.:" >&2
    echo "  xcodebuild -project NTFSForMac.xcodeproj -scheme NTFSForMac -configuration Release \\" >&2
    echo "    -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build" >&2
    exit 1
fi

if [[ -d "/Volumes/$VOLUME_NAME" ]]; then
    echo "error: a volume named \"$VOLUME_NAME\" is already mounted; eject it first." >&2
    exit 1
fi

mkdir -p build "$(dirname "$DMG")"
WORK="$(mktemp -d build/dmg.XXXXXX)"
DEVICE=""
cleanup() {
    if [[ -n "$DEVICE" ]]; then
        hdiutil detach "$DEVICE" -force -quiet || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/$APP_NAME"
ln -s /Applications "$STAGE/Applications"

swift scripts/dmg-background.swift "$WORK/background"
tiffutil -cathidpicheck "$WORK/background/background.png" "$WORK/background/background@2x.png" \
    -out "$STAGE/.background/background.tiff" >/dev/null 2>&1

hdiutil create -quiet -srcfolder "$STAGE" -volname "$VOLUME_NAME" -fs HFS+ \
    -format UDRW -size 200m -ov "$WORK/rw.dmg"

DEVICE="$(hdiutil attach "$WORK/rw.dmg" -readwrite -noverify -noautoopen | awk '/Apple_HFS/ { print $1 }')"
MOUNT_POINT="/Volumes/$VOLUME_NAME"

# Window layout is stored in the volume's .DS_Store, which only Finder writes.
# Without Automation permission the image still works, just without the layout.
if ! osascript <<EOF
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 120, 860, 520}
        set viewOptions to icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.tiff"
        set position of item "$APP_NAME" of container window to {165, 180}
        set position of item "Applications" of container window to {495, 180}
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF
then
    echo "warning: could not set the Finder window layout (allow Automation for Finder to fix)." >&2
fi

chmod -Rf go-w "$MOUNT_POINT" || true
rm -rf "$MOUNT_POINT/.fseventsd"
sync
hdiutil detach "$DEVICE" -quiet || { sleep 2; hdiutil detach "$DEVICE" -force -quiet; }
DEVICE=""

hdiutil convert -quiet "$WORK/rw.dmg" -format ULFO -ov -o "$DMG"
echo "Created $DMG"
