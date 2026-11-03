#!/bin/bash
# Formats scratch disk images exactly as NTFS for Mac does — ntfs-format for
# NTFS (GPT and MBR, quick and full) and diskutil for the other formats — and
# checks every result. It touches only the disk images it creates, and checks
# each device name against them before any destructive command.
#
# Requires the app in /Applications with the extension enabled (NTFS results
# are checked by mounting them). Asks once for an administrator password
# through the macOS dialog.
# Usage: scripts/format-integration-test.sh
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $EUID -ne 0 ]]; then
    swift build --package-path Core -c release --product ntfs-mkfs -q
    swift build --package-path Core -c release --product ntfs-format -q
    BIN="$(swift build --package-path Core -c release --show-bin-path)"
    LOG="$(mktemp /tmp/ntfs-ftest-log.XXXXXX)"
    APP_WAS_RUNNING=false
    if pgrep -xq "NTFS for Mac"; then
        APP_WAS_RUNNING=true
        osascript -e 'quit app "NTFS for Mac"'
    fi
    status=0
    osascript -e "do shell script \"BIN='$BIN' '$PWD/scripts/format-integration-test.sh' > '$LOG' 2>&1\" with administrator privileges" \
        >/dev/null || status=$?
    cat "$LOG"
    rm -f "$LOG"
    if $APP_WAS_RUNNING; then
        open -g -a "NTFS for Mac" || true
    fi
    exit $status
fi

: "${BIN:?run this script without sudo}"
FORMAT="$BIN/ntfs-format"
WORK="$(cd "$(mktemp -d /tmp/ntfs-ftest.XXXXXX)" && pwd -P)"
MNT="$WORK/mnt"
IMAGES=()
DEV=""

cleanup() {
    if mount | grep -q " on $MNT "; then
        umount "$MNT" 2>/dev/null || true
    fi
    local stuck=false
    for dev in "${IMAGES[@]+"${IMAGES[@]}"}"; do
        local detached=false
        for _ in 1 2 3 4 5; do
            if hdiutil detach "$dev" -quiet; then
                detached=true
                break
            fi
            sleep 1
        done
        if ! $detached; then
            echo "WARNING: could not detach /dev/$dev; detach it with: hdiutil detach $dev" >&2
            stuck=true
        fi
    done
    # An attached image still uses its file, so keep it for a manual detach.
    if $stuck; then
        echo "WARNING: left $WORK in place" >&2
    else
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
step() { echo "--> $*"; }

# Creates and attaches an image; sets DEV to its whole-disk node, e.g. disk12.
new_image() { # name size layout fs
    local image="$WORK/$1.dmg"
    hdiutil create -quiet -size "$2" -layout "$3" -fs "$4" -volname "$1" "$image"
    DEV="$(hdiutil attach -nomount "$image" | awk 'NR == 1 { sub("/dev/", "", $1); print $1 }')"
    [[ "$DEV" =~ ^disk[0-9]+$ ]] || fail "could not attach $image"
    # Not added to IMAGES unless it is a disk image, so cleanup never detaches a real disk.
    local description
    description="$(diskutil info "$DEV")"
    grep -Eq '^ *(Protocol|Device / Media Name): +Disk Image *$' <<<"$description" \
        || fail "/dev/$DEV is not a disk image; detach $image by hand"
    IMAGES+=("$DEV")
}

# Refuses any device that isn't on one of this script's images.
ours() {
    local whole="${1%%s[0-9]*}"
    for dev in "${IMAGES[@]}"; do
        [[ "$dev" == "$whole" ]] && return 0
    done
    fail "refusing to touch $1: not a scratch image"
}

info() { diskutil info -plist "/dev/$1" | plutil -extract "$2" raw -o - -; }

# Runs ntfs-format on a partition with its real size and offset; prints the exit status.
run_format() { # device args...
    local dev="$1"
    shift
    ours "$dev"
    local status=0
    "$FORMAT" --device "$dev" --size "$(info "$dev" TotalSize)" --offset "$(info "$dev" PartitionMapPartitionOffset)" "$@" \
        >"$WORK/format.log" 2>&1 || status=$?
    echo "$status"
}

expect_format() { # expected-status device args...
    local expected="$1"
    shift
    local status
    status="$(run_format "$@")"
    [[ "$status" == "$expected" ]] || { cat "$WORK/format.log"; fail "ntfs-format $* exited $status, expected $expected"; }
}

check_ntfs() { # partition
    ours "$1"
    mkdir -p "$MNT"
    mount -F -t ntfsrw "/dev/$1" "$MNT" || fail "$1 did not mount as NTFS"
    mount | grep " on $MNT " | grep -q "(ntfsrw" || fail "$1 is not mounted by ntfsrw"
    head -c $((3 * 1024 * 1024 + 5)) /dev/urandom > "$WORK/data.bin"
    cp "$WORK/data.bin" "$MNT/data.bin"
    umount "$MNT"
    ours "$1"
    mount -F -t ntfsrw -o rdonly "/dev/$1" "$MNT" || fail "$1 did not remount"
    cmp -s "$WORK/data.bin" "$MNT/data.bin" || fail "data on $1 changed after remount"
    umount "$MNT"
}

mbr_type() { # whole disk -> type byte of entry 1
    ours "$1"
    dd if="/dev/r$1" bs=512 count=1 2>/dev/null | xxd -s 450 -l 1 -p
}

step "Refusals on a GPT image"
new_image GPTX 300m GPTSPUD ExFAT
GPT="$DEV"
P="${GPT}s1"
ours "$P"
diskutil mount "$P" >/dev/null
expect_format 70 "$P" --label X --quick
ours "$P"
diskutil unmount "$P" >/dev/null
size="$(info "$P" TotalSize)"
offset="$(info "$P" PartitionMapPartitionOffset)"
ours "$P"
status=0; "$FORMAT" --device "$P" --size $((size - 512)) --offset "$offset" --label X --quick >/dev/null 2>&1 || status=$?
[[ $status == 71 ]] || fail "accepted a wrong size (exit $status)"
ours "$GPT"
status=0; "$FORMAT" --device "$GPT" --size "$(info "$GPT" TotalSize)" --offset 0 --label X --quick >/dev/null 2>&1 || status=$?
[[ $status == 66 ]] || fail "accepted a whole disk (exit $status)"
expect_format 72 "$P" --label "" --quick
expect_format 73 "$P" --label X --cluster 3000 --quick

step "NTFS on GPT, quick"
expect_format 0 "$P" --label "Thử NTFS" --quick
check_ntfs "$P"

step "NTFS on MBR, full format, 8 KB clusters"
new_image MBRF 128m MBRSPUD MS-DOS
MBR="$DEV"
[[ "$(mbr_type "$MBR")" != "07" ]] || fail "the MBR image already has type 07"
expect_format 0 "${MBR}s1" --label MBRNTFS --cluster 8192
[[ "$(mbr_type "$MBR")" == "07" ]] || fail "MBR type was not set to NTFS"
check_ntfs "${MBR}s1"

step "diskutil partition formats: exFAT, FAT32, APFS, then APFS store back to exFAT"
for fs in "ExFAT:exfat" "MS-DOS FAT32:msdos" "APFS:apfs" "ExFAT:exfat"; do
    name="${fs%%:*}"
    kind="${fs##*:}"
    ours "$P"
    diskutil eraseVolume "$name" NFMTEST "$P" >/dev/null || fail "eraseVolume $name failed"
    if [[ "$kind" == "apfs" ]]; then
        [[ "$(info "$P" Content)" == "Apple_APFS" ]] || fail "$P is not an APFS store"
    else
        [[ "$(info "$P" FilesystemType)" == "$kind" ]] || fail "$P is not $kind"
    fi
    # By disk rather than /Volumes/NFMTEST, so ours() can check it; this also covers an APFS container on $P.
    ours "$GPT"
    diskutil unmountDisk "$GPT" >/dev/null
done

step "Whole-disk NTFS on MBR (eraseDisk, then ntfs-format)"
ours "$MBR"
diskutil eraseDisk ExFAT NTFS MBR "$MBR" >/dev/null || fail "eraseDisk failed"
ours "${MBR}s1"
diskutil unmount "/dev/${MBR}s1" >/dev/null
expect_format 0 "${MBR}s1" --label "Whole Disk" --quick
[[ "$(mbr_type "$MBR")" == "07" ]] || fail "MBR type is not NTFS after a whole-disk format"
check_ntfs "${MBR}s1"

step "Whole-disk exFAT on GPT"
ours "$GPT"
diskutil eraseDisk ExFAT NFMTEST GPT "$GPT" >/dev/null || fail "eraseDisk GPT failed"
ours "$GPT"
diskutil unmountDisk "$GPT" >/dev/null

echo "PASS"
