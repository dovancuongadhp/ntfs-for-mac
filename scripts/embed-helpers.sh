#!/bin/bash
# Xcode build phase: builds the ntfs-format and ntfs-mkfs helpers from the Core
# package and copies them into Contents/Helpers, signed like the app.
set -euo pipefail

HELPERS="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
SCRATCH="$DERIVED_FILE_DIR/helpers"
ARCH_FLAGS=()
for arch in $ARCHS; do
    ARCH_FLAGS+=(--arch "$arch")
done

# Xcode's build environment (SDKROOT, toolchain variables…) confuses SwiftPM.
swiftpm() {
    /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" DEVELOPER_DIR="$DEVELOPER_DIR" \
        /usr/bin/xcrun swift build --package-path "$SRCROOT/Core" --scratch-path "$SCRATCH" \
        -c release "${ARCH_FLAGS[@]}" "$@"
}

swiftpm --product ntfs-mkfs
swiftpm --product ntfs-format
BIN="$(swiftpm --show-bin-path)"

mkdir -p "$HELPERS"
for tool in ntfs-format ntfs-mkfs; do
    # A new file, not one rewritten in place: the kernel caches the signature of a signed binary.
    rm -f "$HELPERS/$tool"
    cp "$BIN/$tool" "$HELPERS/$tool"
    if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
        codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime --timestamp=none "$HELPERS/$tool"
    fi
done
