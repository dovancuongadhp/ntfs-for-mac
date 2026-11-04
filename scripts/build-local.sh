#!/bin/bash
# Builds a Release app for this Mac and packages it into build/NTFS-for-Mac.dmg.
# Needs no paid Apple Developer account: it signs with an "Apple Development"
# certificate if one is in the keychain (a free Apple ID added in Xcode >
# Settings > Accounts creates one), else ad hoc. System Settings shows the
# certificate's name under the extension; ad hoc builds show nothing there.
# Gatekeeper blocks the first launch on other Macs, so use release.sh for
# public downloads.
# Usage: scripts/build-local.sh        (SIGN_IDENTITY overrides the identity)
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/DerivedData/Build/Products/Release/NTFS for Mac.app"
ENTITLEMENTS="build/NTFSExtension.local.entitlements"

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning \
        | awk -F'"' '/"Apple Development: / { print $2; exit }')"
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
echo "Signing with: $([[ "$SIGN_IDENTITY" == "-" ]] && echo "ad hoc" || echo "$SIGN_IDENTITY")"

xcodebuild -project NTFSForMac.xcodeproj -scheme NTFSForMac -configuration Release \
    -destination "generic/platform=macOS" -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build -quiet

# Without a provisioning profile, AMFI kills code that claims the FSKit
# entitlement; fskit_agent loads the module without it.
cp Extension/NTFSExtension.entitlements "$ENTITLEMENTS"
/usr/libexec/PlistBuddy -c "Delete :com.apple.developer.fskit.fsmodule" "$ENTITLEMENTS"

# Inside out: helpers and the extension first, then the app that seals them.
for tool in "$APP/Contents/Helpers/"*; do
    extra=()
    # An ad hoc signature has no Team ID, so ntfs-mkfs cannot load the library beside it.
    if [[ "$SIGN_IDENTITY" == "-" && "$(basename "$tool")" == "ntfs-mkfs" ]]; then
        extra=(--entitlements scripts/ntfs-mkfs-adhoc.entitlements)
    fi
    # Bash 3.2 with `set -u` rejects "${extra[@]}" when the array is empty.
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp=none ${extra+"${extra[@]}"} "$tool"
done
codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp=none \
    --entitlements "$ENTITLEMENTS" "$APP/Contents/Extensions/NTFSExtension.appex"
codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp=none \
    --entitlements App/NTFSForMac.entitlements "$APP"
codesign --verify --deep --strict "$APP"

scripts/make-dmg.sh "$APP"
scripts/unregister-build-copies.sh
