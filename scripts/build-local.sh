#!/bin/bash
# Builds a Release app signed ad hoc and packages it into build/NTFS-for-Mac.dmg.
# Needs no Apple Developer account. Gatekeeper blocks the first launch on other
# Macs (right-click > Open), so use release.sh for public downloads.
# Usage: scripts/build-local.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/DerivedData/Build/Products/Release/NTFS for Mac.app"
ENTITLEMENTS="build/NTFSExtension.adhoc.entitlements"

xcodebuild -project NTFSForMac.xcodeproj -scheme NTFSForMac -configuration Release \
    -destination "generic/platform=macOS" -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build -quiet

# AMFI kills ad hoc signed code that claims the FSKit entitlement, which only a
# provisioning profile can grant; fskit_agent loads the module without it.
cp Extension/NTFSExtension.entitlements "$ENTITLEMENTS"
/usr/libexec/PlistBuddy -c "Delete :com.apple.developer.fskit.fsmodule" "$ENTITLEMENTS"

# Inside out: the extension first, then the app that seals it.
codesign --force --sign - --options runtime --timestamp=none \
    --entitlements "$ENTITLEMENTS" "$APP/Contents/Extensions/NTFSExtension.appex"
codesign --force --sign - --options runtime --timestamp=none \
    --entitlements App/NTFSForMac.entitlements "$APP"
codesign --verify --deep --strict "$APP"

scripts/make-dmg.sh "$APP"
