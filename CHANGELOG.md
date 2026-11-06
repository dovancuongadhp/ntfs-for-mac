# Changelog

All notable changes to NTFS for Mac are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Like macOS, every major version is named, here after a flower: 2.x is **Lotus**. Minor and patch updates keep the
name of their major version, and a name is never reused. Versions 1.0.x have no name. Releases are titled
"NTFS for Mac 2.0.0 Lotus", tagged `v2.0.0` and built from branch `release-2.0.0-lotus`.

## [Unreleased]

## [2.2.1] Lotus - 2026-11-06

### Added

- **Favorite folders.** A star beside the place name pins the folder you are in. Pinned folders are listed under Favorites in that menu, and a pinned folder shows a star next to its name.
- **Drop into a folder.** Dragging onto a folder in the same pane moves the items into it. Dragging onto a folder in the other pane copies them. The folder blinks while the drag is over it.
- **Move Item Here.** After copying, the context menu can move those items into the folder you clicked. The originals stay until every one of them has arrived.
- **Undo.** ⌘Z takes back the last move or copy while a file list is focused. ⌘⇧Z redoes a move.

### Changed

- File Transfer is no longer marked Beta. The badge and the first-run notice are gone.
- A click selects the row immediately. A second click opens the folder or file.
- The context menu is grouped with separators, as in Finder.

## [2.2.0] Lotus - 2026-11-04

### Added

- **File Transfer (Beta).** A new page in the main window with two file browsers side by side, each showing any drive or folder of the Mac. Drag files from one side to the other, right-click and choose **Copy to the Other Side**, or copy and paste with ⌘C and ⌘V (also within one side, and with Finder). A panel underneath shows the progress, the read and write speed, the time left, every file and its state, and the files that failed with the reason. This is a Beta, and it only copies: there is no Move yet, so the originals always stay where they are.
- Copying can be paused, resumed, skipped file by file, cancelled, and retried for the files that failed. Errors can be exported as a list. A notification says when the copy is done or needs you.
- Name conflicts offer Replace, Keep Both, Skip or Replace If Newer, with an option to apply the choice to every file.
- **Verify after copy** compares a checksum of each file with its original. **Ask what to do on errors** turns a failed file into a Skip, Retry or Stop prompt.
- Files are written under a temporary name and renamed when complete, so a half-written file never appears under its real name. A drive that runs out of space or is removed pauses the copy until you resume it.
- Copying to a read-only drive is refused before anything starts, with a clear message pointing to the drive page.
- Pressing Copy or ⌘V when both panes show the same folder produces a "Photos 2" duplicate beside the original (Finder-style), instead of merging into it.
- Before copying, names that the destination cannot hold (such as `a:b.txt` on exFAT) and files too large for FAT32 are listed, and you can copy the rest.
- New Folder, Rename, Delete (to the Trash) and Quick Look in either pane. Drives, system folders and your home folder are protected from Rename and Delete. The copy keeps the Mac awake, shows its progress on the Dock icon and in the menu bar menu, and asks before quitting while it runs.
- The File Transfer row in the sidebar shows an orange dot when the copy needs an answer, even from another page.
- Each pane starts with a **..** row to go up, and shows Finder's icons for files, folders and drives, in the list and in the places menu.
- Click a pane's path, or press ⌘L, to type a folder. Matching folders are listed as you type: Tab completes the highlighted one, ↑ ↓ pick another, Return opens it.
- Copying a folder where one of the same name exists asks: **Keep Both** (adds a number, the default), Merge, Skip or Cancel, with an option to apply the choice to every folder.
- ⌘⌫ moves items to the Trash, as in Finder; Shift+⌫ and ⌥⌘⌫ delete them immediately after you confirm.
- The progress list groups files by copy, newest first. Each copy is a row you can open, with its start time, **From**, **To**, size and result. The log is kept, even after quitting, until you press **Clear**.
- The progress panel folds down to one status line with the percentage and any errors, and stays as you left it.
- A **Welcome** page heads the sidebar: whether the NTFS driver is on, the drives plugged in, and shortcuts to File Transfer and Settings.
- The page, panel and prompts are available in Vietnamese.

### Changed

- The main window opens on the Welcome page, the first time too, instead of the first drive or Settings.

## [2.1.0] Lotus - 2026-11-04

### Added

- Each drive shows its type: SSD, hard drive (HDD), SD card or USB flash drive. The type appears in the sidebar icon, the page subtitle and a new **Type** row.
- Drive names read as macOS names them, with the maker and model, such as “Lexar E6” instead of “E6”.
- External SSDs and drives that hold an APFS volume can be ejected. NTFS for Mac unmounts the APFS volumes on the drive first, and retries for a moment if the drive is still busy.
- Mounting an encrypted (FileVault) APFS volume asks for its password and unlocks it, instead of failing with code 49.229.

### Changed

- The main window follows the Disk Utility layout: a floating sidebar, and a toolbar with Mount, Unmount, Eject, Finder and Format that keeps the same height on every page.
- Drive pages and Settings share one layout. The content fills the window, the details switch between two columns and one column as the window resizes, and the sidebar hides itself when the window gets narrow.
- The capacity bar has less rounded corners.

### Fixed

- The drive header was drawn under the toolbar.
- With the file system extension turned off, the warning banner pushed the page out of the window.
- Ejecting a drive could fail with code 49.168 while macOS was still releasing it.

## [2.0.3] Lotus - 2026-11-04

### Fixed

- Plugging in a drive showed “mount: Unable to invoke task”. The app started its own mount while macOS was already mounting, and it ran that command as an administrator. The file system extension only starts for the logged-in user, so the mount failed every time. NTFS for Mac now waits for the mount that is already underway, then mounts as the logged-in user.
- An exFAT partition on the same disk was treated as NTFS before macOS had identified it, and it hit the same error. A partition that is already mounted as exFAT stays exFAT.
- The main window was blank in Light Mode. The drive list was drawn in white on white because the window was created while the app was still only a menu-bar item. The list is visible now.

## [2.0.2] Lotus - 2026-11-04

### Added

- Files whose names NTFS would reject can be copied. That includes `: * ? " < > \ |`, a trailing space or dot, and DOS names such as `CON` or `COM1`. The name is stored in a form Windows accepts and shown again with the original characters on the Mac. After installing, eject the drive and connect it again so the new file system extension is the one serving it.
- Settings can check GitHub for a newer release. When one exists, **Update to …** downloads the disk image and replaces this app. The menu bar menu shows the same update when a newer version is available.

### Changed

- The toolbar actions are separate round buttons with a short name under each icon. Mount is a drive with a plus, Unmount a drive with a minus, and Eject keeps the eject symbol.

## [2.0.1] Lotus - 2026-11-04

### Fixed

- Formatting a removable drive as NTFS failed with “Creating the NTFS file system failed. The partition may not be usable; format it again.” macOS refuses a direct open of a removable disk, even for an administrator, so the NTFS formatter never started and the partition was left as an empty exFAT volume. NTFS for Mac now opens the drive through macOS’s own permission prompt and formats it with that access.
- If macOS still blocks the drive, the error says where to allow it: System Settings → Privacy & Security → Files & Folders, then allow NTFS for Mac to access removable volumes.
- A drive that also holds an APFS volume was listed twice, both rows using the drive's hardware name. macOS presents that volume as a separate virtual disk, and the app could not see which partition held it when the drive's name contained a space. The virtual disk is now a partition of the real drive.
- NTFS formatting stopped after diskutil created the exFAT placeholder, with “the drive changed.” diskutil reports the new file system a little smaller than the partition. That is the same partition, so formatting now continues and uses the size just reported.
- A volume that had just been formatted as NTFS could still be shown as exFAT. macOS kept the old label when it could not re-read the whole disk because other partitions were in use. The new volume is mounted, and the app shows NTFS from that mount.

### Changed

- The NTFS options that were only labeled “Advanced” now say what they are: cluster size and quick format, with a short explanation of each. The defaults are unchanged (Automatic cluster size, quick format on).

## [2.0.0] Lotus - 2026-11-04

### Added

- Main window in the style of Disk Utility, opened from **Open NTFS for Mac…** in the menu: every connected drive
  with its partitions, details, a capacity bar and a partition map.
- Mount, unmount, eject and Show in Finder for any drive, not only NTFS.
- Format a partition as NTFS, exFAT, FAT32 or APFS, or erase a whole external drive with a new GPT or MBR partition
  table. A summary shows exactly what will be erased and what won't, and the drive's name must be typed to confirm.
  Formatting re-checks the drive right before every step and stops if anything changed.
- Advanced NTFS options: cluster size and full (zero-filling) format.
- Formatting a Mac partition (APFS or Mac OS Extended) as NTFS also changes its partition type, so Windows
  recognizes it.

### Changed

- The menu bar panel is more compact and opens the main window.
- One window instead of three: the welcome guide and the settings window are now a single **Settings** page in the
  main window, and a banner in the window says when the file system extension is turned off.

### Security

- Internal drives, the drive macOS runs from and the drive the app runs from are protected: they are shown, but
  can't be unmounted, ejected or formatted. Disk images can't be formatted either.
- NTFS formatting runs a small helper with administrator rights, which you grant in the standard macOS password
  dialog. Erasing a whole drive as NTFS first creates an exFAT partition, then asks for the password to turn it
  into NTFS; if you cancel the dialog, the drive stays exFAT.

## [1.0.1] - 2026-11-03

### Changed

- Right-clicking the menu bar icon now opens the menu too, not just left-clicking.
- Drive usage in the menu is up to date as soon as the menu opens and keeps updating while it stays open.

## [1.0.0] - 2026-11-03

First public release.

### Added

- Read and write NTFS drives in Finder through an Apple FSKit file system extension — no kernel extension,
  no macFUSE, no SIP changes.
- Drives are mounted read-write automatically when plugged in.
- Menu bar app listing NTFS drives with their status and used space, with mount, eject, Show in Finder and a
  per-drive **Allow writing** switch.
- Automatic read-only fallback, with the reason and a fix, when writing would be unsafe: Windows hibernated or
  Fast Startup, unclean journal, volume flagged for checking, write-protected media or a write error.
- **Allow Writing Anyway…** for drives that weren't ejected safely, after a confirmation.
- macOS extended attributes stored natively as NTFS alternate data streams, so no `._` files are created.
- Welcome window that guides you through turning on the file system extension.
- Settings: open at login, language (system, English, Vietnamese) and extension status.
- English and Vietnamese user interface.
- Drag-to-install DMG, and `scripts/build-local.sh` to build an ad hoc signed copy without an Apple Developer account.

[Unreleased]: https://github.com/dovancuongadhp/ntfs-for-mac/compare/v2.2.1...HEAD
[2.2.1]: https://github.com/dovancuongadhp/ntfs-for-mac/compare/v2.2.0...v2.2.1
[2.2.0]: https://github.com/dovancuongadhp/ntfs-for-mac/compare/v2.1.0...v2.2.0
[2.1.0]: https://github.com/dovancuongadhp/ntfs-for-mac/compare/v2.0.3...v2.1.0
[2.0.3]: https://github.com/dovancuongadhp/ntfs-for-mac/compare/v2.0.2...v2.0.3
[2.0.2]: https://github.com/dovancuongadhp/ntfs-for-mac/compare/v2.0.1...v2.0.2
[2.0.1]: https://github.com/dovancuongadhp/ntfs-for-mac/compare/v2.0.0...v2.0.1
[2.0.0]: https://github.com/dovancuongadhp/ntfs-for-mac/compare/v1.0.1...v2.0.0
[1.0.1]: https://github.com/dovancuongadhp/ntfs-for-mac/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/dovancuongadhp/ntfs-for-mac/releases/tag/v1.0.0
