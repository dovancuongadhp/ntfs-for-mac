#!/bin/bash
# Builds a Developer ID signed, notarized and stapled DMG for public download.
#
# One-time setup:
#   1. Copy Config/Local.xcconfig.example to Config/Local.xcconfig and set DEVELOPMENT_TEAM.
#   2. Sign in to that team in Xcode (Settings > Accounts) and create a
#      "Developer ID Application" certificate.
#   3. Store notarization credentials in the keychain:
#        xcrun notarytool store-credentials NTFSForMac \
#          --apple-id you@example.com --team-id ABCDE12345 --password <app-specific password>
#
# Usage: scripts/release.sh            (NOTARY_PROFILE overrides the keychain profile name)
set -euo pipefail
cd "$(dirname "$0")/.."

NOTARY_PROFILE="${NOTARY_PROFILE:-NTFSForMac}"
TEAM_ID="$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' Config/Local.xcconfig 2>/dev/null | tr -d '[:space:]')"
VERSION="$(sed -n 's/^MARKETING_VERSION *= *//p' Config/Base.xcconfig | tr -d '[:space:]')"

if [[ -z "$TEAM_ID" || "$TEAM_ID" == "ABCDE12345" ]]; then
    echo "error: set DEVELOPMENT_TEAM in Config/Local.xcconfig (see Config/Local.xcconfig.example)." >&2
    exit 1
fi

IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' -v team="($TEAM_ID)" \
    'index($2, "Developer ID Application") && index($2, team) { print $2; exit }')"
if [[ -z "$IDENTITY" ]]; then
    echo "error: no \"Developer ID Application\" certificate for team $TEAM_ID in the keychain." >&2
    exit 1
fi

ARCHIVE="build/NTFSForMac.xcarchive"
EXPORT="build/export"
APP="$EXPORT/NTFS for Mac.app"
DMG="build/NTFS-for-Mac-$VERSION.dmg"
rm -rf "$ARCHIVE" "$EXPORT" "$DMG"
mkdir -p build

notarize() {
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
}

echo "==> Archiving $VERSION"
xcodebuild -project NTFSForMac.xcodeproj -scheme NTFSForMac -configuration Release \
    -archivePath "$ARCHIVE" -allowProvisioningUpdates archive -quiet

echo "==> Exporting with Developer ID"
cat > build/ExportOptions.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
    -exportOptionsPlist build/ExportOptions.plist -allowProvisioningUpdates -quiet

codesign --verify --deep --strict "$APP"
if ! codesign -d --entitlements - "$APP/Contents/Extensions/NTFSExtension.appex" 2>/dev/null \
        | grep -q "com.apple.developer.fskit.fsmodule"; then
    echo "error: the extension was signed without the FSKit entitlement." >&2
    exit 1
fi

# The app is stapled too, so Gatekeeper accepts it offline after it leaves the DMG.
echo "==> Notarizing the app"
ditto -c -k --keepParent "$APP" build/notarize-app.zip
notarize build/notarize-app.zip
xcrun stapler staple "$APP"
rm build/notarize-app.zip

echo "==> Building the DMG"
scripts/make-dmg.sh "$APP" "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"

echo "==> Notarizing the DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"

echo "==> Done: $DMG"
shasum -a 256 "$DMG"
