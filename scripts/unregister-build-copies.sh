#!/bin/bash
# macOS registers every app it finds, so each Xcode build under build/ adds
# another "NTFS for Mac" to System Settings > Login Items & Extensions.
# This forgets those build copies; the installed app and files stay untouched.
# Usage: scripts/unregister-build-copies.sh   (also run by build-local.sh and release.sh)
set -euo pipefail
cd "$(dirname "$0")/.."

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

[[ -d build ]] || exit 0
find "$PWD/build" -name "NTFS for Mac.app" -type d -prune -print0 \
    | while IFS= read -r -d '' app; do
        "$LSREGISTER" -u "$app" 2>/dev/null || true
    done
