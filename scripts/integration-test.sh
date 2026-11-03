#!/bin/bash
# End-to-end test of the installed FSKit extension on a scratch NTFS image:
# mount read-write, write files, remount read-only and compare checksums.
#
# Requires a signed build in /Applications with the extension enabled in
# System Settings > General > Login Items & Extensions > File System Extensions.
# Usage: scripts/integration-test.sh
set -euo pipefail
cd "$(dirname "$0")/.."

FS_TYPE="ntfsrw"
WORK="$(mktemp -d /tmp/ntfs-itest.XXXXXX)"
IMAGE="$WORK/volume.img"
MNT="$WORK/mnt"
DEVICE=""

cleanup() {
    if mount | grep -q " on $MNT "; then
        umount "$MNT" 2>/dev/null || diskutil unmount force "$MNT" >/dev/null 2>&1 || true
    fi
    if [[ -n "$DEVICE" ]]; then
        hdiutil detach "$DEVICE" -force -quiet || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
step() { echo "--> $*"; }

mount_volume() {
    mkdir -p "$MNT"
    mount -F -t "$FS_TYPE" "$@" "$DEVICE" "$MNT" || fail "mount -F -t $FS_TYPE $* failed (is the extension enabled?)"
    mount | grep " on $MNT " | grep -q "($FS_TYPE" || fail "$MNT is not mounted by $FS_TYPE"
}

unmount_volume() {
    umount "$MNT" || fail "unmount failed"
}

step "Building ntfs-mkfs"
swift build --package-path Core -c release --product ntfs-mkfs -q
MKFS="$(swift build --package-path Core -c release --show-bin-path)/ntfs-mkfs"

step "Formatting a 256 MB image"
mkfile -n 256m "$IMAGE"
"$MKFS" -F -f -q -L ITest "$IMAGE" >/dev/null 2>&1 || fail "ntfs-mkfs failed"
DEVICE="$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$IMAGE" | awk 'NR == 1 { print $1 }')"
[[ -n "$DEVICE" ]] || fail "could not attach the image"

step "Mounting read-write"
mount_volume

step "Writing files"
mkdir -p "$MNT/Thư mục/nested/deeper"
: > "$MNT/empty.txt"
head -c 1 /dev/urandom > "$MNT/one-byte.bin"
head -c 4095 /dev/urandom > "$MNT/Thư mục/unaligned.bin"
head -c $((1024 * 1024 + 7)) /dev/urandom > "$MNT/Thư mục/nested/medium.bin"
head -c $((24 * 1024 * 1024)) /dev/urandom > "$MNT/Thư mục/nested/deeper/large.bin"
printf 'Xin chào NTFS\n' > "$MNT/Tiếng Việt.txt"
cp "$MNT/Thư mục/nested/medium.bin" "$MNT/copy.bin"

head -c 3000 /dev/urandom > "$MNT/edit.bin"
head -c 100 /dev/urandom | dd of="$MNT/edit.bin" bs=1 seek=1000 conv=notrunc 2>/dev/null
head -c 500 /dev/urandom >> "$MNT/edit.bin"
truncate -s 2048 "$MNT/one-byte.bin"
[[ "$(stat -f %z "$MNT/one-byte.bin")" == 2048 ]] || fail "truncate did not grow the file"

step "Rename, delete, case-insensitive lookup"
printf 'case' > "$MNT/MixedCase.TXT"
[[ -f "$MNT/mixedcase.txt" ]] || fail "lookup is not case-insensitive"
mv "$MNT/copy.bin" "$MNT/Thư mục/renamed.bin"
[[ ! -e "$MNT/copy.bin" ]] || fail "rename left the old name behind"
printf 'temporary' > "$MNT/delete-me.txt"
rm "$MNT/delete-me.txt"
[[ ! -e "$MNT/delete-me.txt" ]] || fail "delete did not remove the file"
mkdir "$MNT/empty-dir" && rmdir "$MNT/empty-dir"

(cd "$MNT" && find . -type f ! -name '._*' -print0 | sort -z | xargs -0 shasum -a 256) > "$WORK/expected.sha"
EXPECTED_COUNT="$(wc -l < "$WORK/expected.sha" | tr -d ' ')"

step "Remounting read-only"
unmount_volume
mount_volume -o rdonly

(cd "$MNT" && shasum -a 256 -c --quiet "$WORK/expected.sha") || fail "checksums differ after remount"
if ( : > "$MNT/should-fail.txt" ) 2>/dev/null; then
    fail "a read-only mount accepted a write"
fi
unmount_volume

echo "PASS: $EXPECTED_COUNT files survived a remount intact."
