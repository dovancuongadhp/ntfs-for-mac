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
    osascript - "$BIN" "$PWD/scripts/format-integration-test.sh" "$LOG" "$(id -u)" >/dev/null <<'APPLESCRIPT' || status=$?
on run argv
    set command to "BIN=" & quoted form of item 1 of argv & " USER_UID=" & quoted form of item 4 of argv & " " & quoted form of item 2 of argv
    do shell script command & " > " & quoted form of item 3 of argv & " 2>&1" with administrator privileges
end run
APPLESCRIPT
    cat "$LOG"
    rm -f "$LOG"
    if $APP_WAS_RUNNING; then
        open -g -a "NTFS for Mac" || true
    fi
    exit $status
fi

: "${BIN:?run this script without sudo}"
: "${USER_UID:?run this script without sudo}"
FORMAT="$BIN/ntfs-format"
WORK="$(mktemp -d /tmp/ntfs-ftest.XXXXXX)"
WORK="$(cd "$WORK" && pwd -P)"
[[ "$WORK" == /private/tmp/ntfs-ftest.* ]] || { echo "bad work dir: $WORK" >&2; exit 1; }
MNT="$WORK/mnt"
IMAGES=()
DEV=""
uuid_before=none
# Set when an image may still be attached, so cleanup keeps the files behind it.
KEEP_WORK=false

mounted_at() { grep -q " on $1 " <<<"$(mount)"; }

# FSKit runs the extension for the logged-in user, not for root.
as_user() { launchctl asuser "$USER_UID" sudo -u "#$USER_UID" "$@"; }

cleanup() {
    local dev
    if mounted_at "$MNT"; then
        as_user umount "$MNT" 2>/dev/null || umount "$MNT" 2>/dev/null || true
    fi
    for dev in "${IMAGES[@]+"${IMAGES[@]}"}"; do
        # The name may now belong to another disk if the image went away.
        if ! attached_from_work "$dev"; then
            echo "WARNING: /dev/$dev is no longer attached from $WORK; not detaching it" >&2
            KEEP_WORK=true
            continue
        fi
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
            KEEP_WORK=true
        fi
    done
    if $KEEP_WORK; then
        echo "WARNING: left $WORK in place" >&2
    elif [[ "$WORK" == /private/tmp/ntfs-ftest.* ]]; then
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
step() { echo "--> $*"; }

# Succeeds if hdiutil reports /dev/<whole disk> as attached from an image in $WORK.
attached_from_work() { # whole disk
    local plist image entry i j
    plist="$(hdiutil info -plist)" || return 1
    for ((i = 0; ; i++)); do
        image="$(plutil -extract "images.$i.image-path" raw -o - - <<<"$plist" 2>/dev/null)" || return 1
        [[ "$image" == "$WORK"/*.dmg ]] || continue
        for ((j = 0; ; j++)); do
            entry="$(plutil -extract "images.$i.system-entities.$j.dev-entry" raw -o - - <<<"$plist" 2>/dev/null)" || break
            [[ "$entry" == "/dev/$1" ]] && return 0
        done
    done
}

# Creates and attaches an image; sets DEV to its whole-disk node, e.g. disk12.
new_image() { # name size layout fs
    local image="$WORK/$1.dmg"
    hdiutil create -quiet -size "$2" -layout "$3" -fs "$4" -volname "$1" "$image"
    local attached
    attached="$(hdiutil attach -nomount "$image")" || {
        KEEP_WORK=true
        fail "could not attach $image; check hdiutil info and detach it by hand if it is listed"
    }
    # Attached but not yet in IMAGES: any failure until then leaves the files in place.
    KEEP_WORK=true
    DEV="$(awk 'NR == 1 { sub("/dev/", "", $1); print $1 }' <<<"$attached")"
    if [[ ! "$DEV" =~ ^disk[0-9]+$ ]]; then
        fail "could not find the device for $image; check hdiutil info and detach it by hand"
    fi
    # Not added to IMAGES unless it is a disk image, so cleanup never detaches a real disk.
    local description
    description="$(diskutil info "$DEV")" || fail "could not inspect /dev/$DEV; check hdiutil info and detach $image by hand"
    if ! grep -Eq '^ *(Protocol|Device / Media Name): +Disk Image *$' <<<"$description" \
        || ! attached_from_work "$DEV"; then
        fail "/dev/$DEV does not look like $image; check hdiutil info and detach $image by hand"
    fi
    IMAGES+=("$DEV")
    KEEP_WORK=false
}

# Refuses any device that isn't on one of this script's images.
ours() {
    [[ "$1" =~ ^disk[0-9]+(s[0-9]+)?$ ]] || fail "refusing to touch $1: not a disk name"
    local whole="${1%%s[0-9]*}"
    local known=false image
    for image in "${IMAGES[@]+"${IMAGES[@]}"}"; do
        [[ "$image" == "$whole" ]] && known=true
    done
    $known || fail "refusing to touch $1: not a scratch image"
    attached_from_work "$whole" || fail "refusing to touch $1: /dev/$whole is no longer attached from $WORK"
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
    # DiskArbitration may still be probing the new file system and mount it.
    sleep 2
    if grep -q "^/dev/$1 on " <<<"$(mount)"; then
        ours "$1"
        diskutil unmount "/dev/$1" >/dev/null || fail "could not unmount the auto-mounted $1"
    fi
    ours "$1"
    # The user mounts it, so give them this scratch partition and the mount point.
    chown "$USER_UID" "/dev/$1" "/dev/r$1"
    # Traversable but not listable by others; the user reads data.bin (644) by its path.
    chmod 711 "$WORK"
    mkdir -p "$MNT"
    chown "$USER_UID" "$MNT"
    chmod 755 "$MNT"
    as_user mount -F -t ntfsrw "/dev/$1" "$MNT" || fail "$1 did not mount as NTFS"
    grep " on $MNT " <<<"$(mount)" | grep -q "(ntfsrw" || fail "$1 is not mounted by ntfsrw"
    head -c $((3 * 1024 * 1024 + 5)) /dev/urandom > "$WORK/data.bin"
    chmod 644 "$WORK/data.bin"
    as_user cp "$WORK/data.bin" "$MNT/data.bin" || fail "could not write to $1"
    as_user umount "$MNT" || fail "could not unmount $1"
    ours "$1"
    as_user mount -F -t ntfsrw -o rdonly "/dev/$1" "$MNT" || fail "$1 did not remount"
    as_user cmp -s "$WORK/data.bin" "$MNT/data.bin" || fail "data on $1 changed after remount"
    as_user umount "$MNT" || fail "could not unmount $1"
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
mbr="$(mbr_type "$MBR")"
[[ "$mbr" != "07" ]] || fail "the MBR image already has type 07"
expect_format 0 "${MBR}s1" --label MBRNTFS --cluster 8192
mbr="$(mbr_type "$MBR")"
[[ "$mbr" == "07" ]] || fail "MBR type was not set to NTFS (type $mbr)"
check_ntfs "${MBR}s1"

step "diskutil partition formats: exFAT, FAT32, APFS, then APFS store back to exFAT"
for fs in "ExFAT:exfat" "MS-DOS FAT32:msdos" "APFS:apfs" "ExFAT:exfat"; do
    name="${fs%%:*}"
    kind="${fs##*:}"
    ours "$P"
    if [[ "$(info "$P" Content)" == "Apple_APFS" ]]; then
        # As the app does: diskutil won't erase an APFS physical store.
        diskutil apfs deleteContainer "$P" NFMTEMP >/dev/null || fail "deleteContainer failed"
        ours "$P"
    fi
    diskutil eraseVolume "$name" NFMTEST "$P" >/dev/null || fail "eraseVolume $name failed"
    if [[ "$kind" == "apfs" ]]; then
        [[ "$(info "$P" Content)" == "Apple_APFS" ]] || fail "$P is not an APFS store"
    else
        [[ "$(info "$P" FilesystemType)" == "$kind" ]] || fail "$P is not $kind"
    fi
    # By disk rather than /Volumes/NFMTEST, so ours() can check it; this also covers an APFS container on $P.
    ours "$GPT"
    diskutil unmountDisk "$GPT" >/dev/null
    if [[ "$kind" == "apfs" ]]; then
        # Windows doesn't mount NTFS from an APFS-typed partition.
        expect_format 74 "$P" --label X --quick
        # The GPT partition GUID the app fingerprints when its format sheet opens.
        uuid_before="$(info "$P" DiskUUID 2>/dev/null || echo none)"
    fi
done

step "NTFS on the partition diskutil re-typed from APFS (as the app does)"
uuid_after="$(info "$P" DiskUUID 2>/dev/null || echo none)"
echo "    partition GUID while APFS: $uuid_before"
echo "    partition GUID re-typed:   $uuid_after"
if [[ "$uuid_before" != "$uuid_after" ]]; then
    echo "    (erasing gave the partition a new GUID; after erasing, the app checks the drive, partition name, offset and size instead)"
fi
expect_format 0 "$P" --label "Từ APFS" --quick
check_ntfs "$P"

step "Whole-disk NTFS on MBR (eraseDisk, then ntfs-format)"
ours "$MBR"
diskutil eraseDisk ExFAT NTFS MBR "$MBR" >/dev/null || fail "eraseDisk failed"
ours "${MBR}s1"
diskutil unmount "/dev/${MBR}s1" >/dev/null
expect_format 0 "${MBR}s1" --label "Whole Disk" --quick
mbr="$(mbr_type "$MBR")"
[[ "$mbr" == "07" ]] || fail "MBR type is not NTFS after a whole-disk format (type $mbr)"
check_ntfs "${MBR}s1"

step "Whole-disk exFAT on GPT"
ours "$GPT"
diskutil eraseDisk ExFAT NFMTEST GPT "$GPT" >/dev/null || fail "eraseDisk GPT failed"
# A small disk may or may not get an EFI partition first.
data=""
for part in "${GPT}s1" "${GPT}s2"; do
    [[ -e "/dev/$part" ]] || continue
    if [[ "$(info "$part" FilesystemType 2>/dev/null || true)" == "exfat" ]]; then
        data="$part"
    fi
done
[[ -n "$data" ]] || fail "eraseDisk GPT left no exFAT partition on $GPT"
ours "$GPT"
diskutil unmountDisk "$GPT" >/dev/null

echo "PASS"
