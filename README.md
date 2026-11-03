<div align="center">

<img src="App/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="128" height="128" alt="NTFS for Mac icon">

# NTFS for Mac

**Read and write Windows (NTFS) drives right in Finder — free and open source.**

[![Latest release](https://img.shields.io/github/v/release/dovancuongadhp/ntfs-for-mac?label=release)](https://github.com/dovancuongadhp/ntfs-for-mac/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/dovancuongadhp/ntfs-for-mac/total)](https://github.com/dovancuongadhp/ntfs-for-mac/releases)
[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-blue?logo=apple)](#requirements)
[![License: GPL v2+](https://img.shields.io/badge/license-GPL--2.0--or--later-green)](LICENSE)

[**⬇ Download NTFS-for-Mac.dmg**](https://github.com/dovancuongadhp/ntfs-for-mac/releases/latest/download/NTFS-for-Mac.dmg)
· [Release notes](https://github.com/dovancuongadhp/ntfs-for-mac/releases)
· [Changelog](CHANGELOG.md)
· [**Tiếng Việt**](README.vi.md)

</div>

---

macOS can read NTFS drives out of the box, but it can't write to them. NTFS for Mac fixes that: plug in a
USB stick, external disk or Boot Camp partition formatted by Windows, and you can copy, rename, delete and
organize files in Finder just like on any other drive.

It runs as an Apple **FSKit** file system extension built into the app. There is no kernel extension, no
macFUSE, no need to disable System Integrity Protection and no restart. To install, drag the app to
Applications; to uninstall, drag it to the Trash.

## Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Using NTFS for Mac](#using-ntfs-for-mac)
- [When a drive opens read-only](#when-a-drive-opens-read-only)
- [Limitations](#limitations)
- [Uninstalling](#uninstalling)
- [FAQ](#faq)
- [Reporting a bug](#reporting-a-bug)
- [How it works](#how-it-works)
- [Building from source](#building-from-source)
- [Contributing](#contributing)
- [Acknowledgements](#acknowledgements)
- [License](#license)

## Features

- **Write support in Finder** — NTFS drives are mounted read-write automatically and behave like any other
  drive: copy, move, rename, delete, create folders.
- **Menu bar app** — see every connected NTFS drive with its status and used space, mount, eject or reveal
  it in Finder, and turn writing off for any drive you want to keep read-only.
- **Protects your data** — if writing would be unsafe (Windows is hibernated, the drive wasn't ejected
  cleanly, Windows asked for a disk check, or a write error occurred), the drive is opened read-only and
  the app tells you why and how to fix it.
- **No `._` clutter** — macOS extended attributes (Finder tags, download origin, Finder info…) are stored
  natively as NTFS alternate data streams instead of littering the drive with `._` files.
- **Native and lightweight** — an FSKit extension in user space, built on the proven
  [ntfs-3g](https://github.com/tuxera/ntfs-3g) library.
- **English and Vietnamese** — follows your system language, or pick one in Settings.
- **Free and open source** — GPL-2.0-or-later, no trial, no subscription, no telemetry.

## Requirements

- **macOS 26 (Tahoe) or later.** Earlier versions of FSKit lack the APIs needed for fast, reliable writing.
- A Mac with Apple silicon or an Intel processor.

## Installation

1. **Download** [`NTFS-for-Mac.dmg`](https://github.com/dovancuongadhp/ntfs-for-mac/releases/latest/download/NTFS-for-Mac.dmg)
   and open it.
2. **Drag NTFS for Mac into the Applications folder.**
3. **Open the app.** The current build is **not notarized by Apple yet**, so macOS blocks the first launch:
   1. Click **Done** in the warning dialog.
   2. Open **System Settings → Privacy & Security**, scroll down and click **Open Anyway**.

   Alternatively, run this once in Terminal:

   ```sh
   xattr -dr com.apple.quarantine "/Applications/NTFS for Mac.app"
   ```
4. **Turn on the file system extension.** The welcome window has an **Open System Settings** button that takes
   you to **General → Login Items & Extensions → File System Extensions**. Switch on **NTFS for Mac**.
5. **Plug in your NTFS drive.** It appears in Finder, ready to write. If the drive was already connected,
   click **Mount** next to it in the menu bar.

> [!TIP]
> To update, download the new DMG and drag the app into Applications again, replacing the old copy.
> You won't need to turn the extension on again, as long as the new copy is signed the same way as the old one.

## Using NTFS for Mac

NTFS for Mac lives in the menu bar (there is no Dock icon). Click the icon — left or right click — to see
your NTFS drives. Each row shows:

| Item | Description |
| --- | --- |
| Status | **Read & write**, **Read-only — reason**, **Not mounted**, and so on |
| Usage bar | Space used on the drive, updated live while the menu is open |
| **Allow writing** | Turn off to keep this drive read-only. The choice is remembered per drive |
| Folder button | Show the drive in Finder |
| **Mount** | Mount a drive that is connected but not mounted |
| Eject button | Safely eject the drive |

From the menu you can also open **Settings…**, where you can:

- start NTFS for Mac automatically when you log in,
- choose the language (Same as system, English, Tiếng Việt),
- check whether the file system extension is turned on.

> [!IMPORTANT]
> Always **eject** a drive (in Finder or from the menu bar) before unplugging it, so every change is written
> to the disk.

## When a drive opens read-only

NTFS for Mac never forces a write onto a drive that may be in an inconsistent state. If a drive shows
**Read-only**, the reason is displayed next to it:

| Status | What it means | What to do |
| --- | --- | --- |
| Windows is hibernated | Windows hibernated or uses Fast Startup, so the drive still holds Windows' open session | Start Windows, hold **Shift** while clicking **Shut Down** (or turn off Fast Startup), then reconnect the drive |
| Not ejected safely | The drive was unplugged without ejecting, or Windows didn't shut down cleanly | Connect it to Windows and shut down normally, or click **Allow Writing Anyway…** (changes Windows hadn't finished saving may be lost) |
| Disk needs checking | Windows flagged the volume for a disk check | Run `chkdsk /f` on the drive in Windows, then reconnect it |
| Disk is write-protected | The drive or card has its lock switch on | Slide the lock switch off |
| Write error | Writing to the drive failed, so writing was stopped to protect your data | Eject the drive and check the cable or the drive itself |
| Writing turned off | You turned off **Allow writing** for this drive | Turn **Allow writing** back on |
| Read-only (macOS driver) | macOS mounted the drive with its built-in read-only driver | Turn on the extension in System Settings (see [Installation](#installation)) |

## Limitations

Version 1 does **not** support:

- formatting drives as NTFS,
- repairing volumes (use `chkdsk` on Windows),
- editing NTFS permissions (ACLs),
- BitLocker-encrypted drives and EFS-encrypted files.

## Uninstalling

Quit the app (menu → **Quit**) and drag **NTFS for Mac** from Applications to the Trash. That's it: the
extension is removed together with the app. Only a small preferences file is left in `~/Library/Preferences`.

## FAQ

<details>
<summary><b>Is it safe to write to my drive?</b></summary>

NTFS reading and writing is done by [ntfs-3g](https://github.com/tuxera/ntfs-3g), which has been used on
Linux for well over a decade. On top of that, NTFS for Mac refuses to write whenever the volume isn't in a
clean state (see [When a drive opens read-only](#when-a-drive-opens-read-only)). As with any disk tool,
keep backups of important data and always eject before unplugging.
</details>

<details>
<summary><b>Do I need macFUSE, a kernel extension or to disable SIP?</b></summary>

No. NTFS for Mac uses FSKit, Apple's user-space file system framework introduced for third-party file systems.
Nothing is installed outside the app bundle.
</details>

<details>
<summary><b>Why does macOS say the app can't be opened?</b></summary>

The current build isn't notarized by Apple yet. Follow step 3 of [Installation](#installation) once; after that
the app opens normally. You can also [build it from source](#building-from-source) yourself.
</details>

<details>
<summary><b>Does it work on macOS 15 Sequoia or earlier?</b></summary>

No. FSKit on earlier macOS versions lacks the APIs needed for fast, reliable read-write access, so macOS 26 is
the minimum.
</details>

<details>
<summary><b>My drive doesn't appear, or shows "Not supported".</b></summary>

Only NTFS drives are listed, so check the format in Disk Utility first. A drive shown as
**Not supported — encrypted (BitLocker) or damaged** is either BitLocker-encrypted (turn BitLocker off in
Windows) or damaged (run `chkdsk /f` on it in Windows).
</details>

<details>
<summary><b>Is it really free?</b></summary>

Yes. NTFS for Mac is free software under the GNU GPL v2 or later: no trial period, no ads, no data collection.
</details>

## Reporting a bug

Please [open an issue](https://github.com/dovancuongadhp/ntfs-for-mac/issues/new) and include:

- your macOS version and Mac model (Apple silicon or Intel),
- the NTFS for Mac version (**Settings… → About**),
- what you did, what you expected and what happened instead,
- logs from the last few minutes, collected right after the problem occurs:

```sh
log show --last 10m --predicate 'subsystem BEGINSWITH "com.docuong.ntfsformac"'
```

## How it works

```
NTFS for Mac.app
├── Contents/MacOS/NTFS for Mac                ← menu bar app (SwiftUI)
└── Contents/Extensions/NTFSExtension.appex    ← FSKit file system extension
        └── NTFSCore → libntfs-3g              ← NTFS engine
```

- The **menu bar app** watches for disks with DiskArbitration, recognizes NTFS volumes from their boot
  sector, decides whether a drive can be safely mounted read-write and asks FSKit to mount it with the extension.
- The **FSKit extension** (`ntfsrw`) runs in user space and translates Finder's file operations into calls to
  libntfs-3g, which reads and writes the NTFS structures directly on the block device.

## Building from source

Requirements: **Xcode 26** or later. [XcodeGen](https://github.com/yonaskolb/XcodeGen) is only needed after
editing `project.yml`.

ntfs-3g is a git submodule, so clone with it:

```sh
git clone --recursive https://github.com/dovancuongadhp/ntfs-for-mac.git
# or, in an existing clone: git submodule update --init
```

**Without an Apple Developer account**, run `scripts/build-local.sh`. It builds an ad hoc signed app and
`build/NTFS-for-Mac.dmg` that work on your own Mac. Xcode itself refuses to sign the extension without a team,
so use the script rather than building in Xcode.

**With an account**, for debugging in Xcode and for public releases:

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig   # set DEVELOPMENT_TEAM to your Team ID
xcodegen generate                                        # only needed after editing project.yml
open NTFSForMac.xcodeproj                                # build and run the NTFSForMac scheme
```

Copy the built app to `/Applications` before enabling the extension, because macOS only offers extensions from
installed apps. Replacing the app with a differently signed copy unregisters the extension until it is enabled again.

| Command | What it does |
| --- | --- |
| `swift test --package-path Core` | Unit tests for the NTFS core (libntfs-3g bridge), using generated disk images |
| `xcodebuild -scheme NTFSForMac CODE_SIGNING_ALLOWED=NO test` | App unit tests |
| `scripts/build-local.sh` | Release build and DMG for your own Mac: signed with your free "Apple Development" certificate if present, else ad hoc |
| `scripts/integration-test.sh` | Mounts a scratch NTFS image through the installed extension and checks data survives a remount |
| `scripts/make-dmg.sh [app] [dmg]` | Packages an app into a drag-to-install DMG (defaults to the unsigned Release build) |
| `scripts/release.sh` | Archive, Developer ID signing, notarization, stapling and the final DMG |
| `swift scripts/make-icon.swift` | Regenerates the app icon |

### Project layout

| Path | Contents |
| --- | --- |
| `App/` | Menu bar app: disk monitoring (DiskArbitration), mounting, per-drive settings, welcome and settings windows |
| `Extension/` | FSKit file system extension (`ntfsrw`) |
| `Core/` | Swift package: vendored ntfs-3g (`CNTFS`), a typed Swift API over it (`NTFSCore`), boot-sector probing (`NTFSProbe`) and identifiers shared by the app and extension (`NTFSShared`) |
| `AppTests/` | App unit tests |
| `scripts/` | Build, packaging, release and integration-test scripts |
| `docs/` | Design spec and implementation plan |

## Contributing

Contributions are welcome: bug reports, translations, documentation and code.

1. For anything bigger than a small fix, please open an issue first so we can agree on the approach.
2. Fork the repository and create a branch from `main`.
3. Run the unit tests (`swift test --package-path Core` and the app tests above) and, if you changed the
   extension, `scripts/integration-test.sh`.
4. Open a pull request describing what changed and how you tested it.

To add or improve a translation, edit `App/Localizable.xcstrings` in Xcode.

## Acknowledgements

- [ntfs-3g](https://github.com/tuxera/ntfs-3g) by Tuxera and its contributors, the NTFS engine behind this app.
- Apple's [FSKit](https://developer.apple.com/documentation/fskit), which makes user-space file systems on macOS possible.

## License

NTFS for Mac is free software released under the **GNU General Public License v2.0 or later**, the same license
as ntfs-3g. See [LICENSE](LICENSE).

NTFS, Windows and BitLocker are trademarks of Microsoft Corporation. macOS and Finder are trademarks of Apple Inc.
This project is not affiliated with or endorsed by Microsoft or Apple.
